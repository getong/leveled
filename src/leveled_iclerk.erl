%% -------- Inker's Clerk ---------
%%
%% The Inker's clerk runs compaction jobs on behalf of the Inker, informing the
%% Inker of any manifest changes when complete.
%%
%% -------- Value Compaction ---------
%%
%% Compaction requires the Inker to have four different types of keys
%% * stnd - A standard key of the form {SQN, stnd, LedgerKey} which maps to a
%% value of {Object, KeyDeltas}
%% * tomb - A tombstone for a LedgerKey {SQN, tomb, LedgerKey}
%% * keyd - An object containing key deltas only of the form
%% {SQN, keyd, LedgerKey} which maps to a value of {KeyDeltas}
%%
%% Each LedgerKey has a Tag, and for each Tag there should be a compaction
%% strategy, which will be set to one of the following:
%% * retain - KeyDeltas must be retained permanently, only values can be
%% compacted (if replaced or not_present in the ledger)
%% * recalc - The full object can be removed through comapction (if replaced or
%% not_present in the ledger), as each object with that tag can have the Key
%% Deltas recreated by passing into an assigned recalc function {LedgerKey,
%% SQN, Object, KeyDeltas, PencillerSnapshot}
%% * recovr - At compaction time this is equivalent to recalc, only KeyDeltas
%% are lost when reloading the Ledger from the Journal, and it is assumed that
%% those deltas will be resolved through external anti-entropy (e.g. read
%% repair or AAE) - or alternatively the risk of loss of persisted data from
%% the ledger is accepted for this data type
%% 
%% During the compaction process for the Journal, the file chosen for
%% compaction is scanned in SQN order, and a FilterFun is passed (which will
%% normally perform a check against a snapshot of the persisted part of the
%% Ledger).  If the given key is of type stnd, and this object is no longer the
%% active object under the LedgerKey, then the object can be compacted out of
%% the journal.  This will lead to either its removal (if the strategy for the
%% Tag is recovr or recalc), or its replacement with a KeyDelta object.
%%
%% Tombstones cannot be reaped through this compaction process.
%%
%% Currently, KeyDeltas are also reaped if the LedgerKey has been updated and
%% the Tag has a recovr strategy.  This may be the case when KeyDeltas are used
%% as a way of directly representing a change, and where anti-entropy can
%% recover from a loss.
%%
%% -------- Tombstone Reaping ---------
%%
%% Value compaction does not remove tombstones from the database, and so a
%% separate compaction job is required for this.
%%
%% Tombstones can only be reaped for Tags set to recovr or recalc.
%%
%% The tombstone reaping process should select a file to compact, and then
%% take that file and discover the LedgerKeys of all reapable tombstones.
%% The lesger should then be scanned from SQN 0 looking for unreaped objects
%% before the tombstone.  If no ushc objects exist for that tombstone, it can
%% now be reaped as part of the compaction job.
%%
%% Other tombstones cannot be reaped, as otherwis eon laoding a ledger an old
%% version of the object may re-emerge.

-module(leveled_iclerk).

-behaviour(gen_server).

-include("include/leveled.hrl").

-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        clerk_new/1,
        clerk_compact/6,
        clerk_hashtablecalc/3,
        clerk_stop/1,
        code_change/3]).      

-include_lib("eunit/include/eunit.hrl").

-define(JOURNAL_FILEX, "cdb").
-define(PENDING_FILEX, "pnd").
-define(SAMPLE_SIZE, 200).
-define(BATCH_SIZE, 32).
-define(BATCHES_TO_CHECK, 8).
%% How many consecutive files to compact in one run
-define(MAX_COMPACTION_RUN, 4).
%% Sliding scale to allow preference of longer runs up to maximum
-define(SINGLEFILE_COMPACTION_TARGET, 60.0).
-define(MAXRUN_COMPACTION_TARGET, 80.0).
-define(CRC_SIZE, 4).
-define(DEFAULT_RELOAD_STRATEGY, leveled_codec:inker_reload_strategy([])).

-record(state, {inker :: pid(),
                    max_run_length :: integer(),
                    cdb_options,
                    reload_strategy = ?DEFAULT_RELOAD_STRATEGY :: list()}).

-record(candidate, {low_sqn :: integer(),
                    filename :: string(),
                    journal :: pid(),
                    compaction_perc :: float()}).


%%%============================================================================
%%% API
%%%============================================================================

clerk_new(InkerClerkOpts) ->
    gen_server:start(?MODULE, [InkerClerkOpts], []).
    
clerk_compact(Pid, Checker, InitiateFun, FilterFun, Inker, Timeout) ->
    gen_server:cast(Pid,
                    {compact,
                    Checker,
                    InitiateFun,
                    FilterFun,
                    Inker,
                    Timeout}).

clerk_hashtablecalc(HashTree, StartPos, CDBpid) ->
    {ok, Clerk} = gen_server:start(?MODULE, [#iclerk_options{}], []),
    gen_server:cast(Clerk, {hashtable_calc, HashTree, StartPos, CDBpid}).

clerk_stop(Pid) ->
    gen_server:cast(Pid, stop).

%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init([IClerkOpts]) ->
    ReloadStrategy = IClerkOpts#iclerk_options.reload_strategy,
    case IClerkOpts#iclerk_options.max_run_length of
        undefined ->
            {ok, #state{max_run_length = ?MAX_COMPACTION_RUN,
                        inker = IClerkOpts#iclerk_options.inker,
                        cdb_options = IClerkOpts#iclerk_options.cdb_options,
                        reload_strategy = ReloadStrategy}};
        MRL ->
            {ok, #state{max_run_length = MRL,
                        inker = IClerkOpts#iclerk_options.inker,
                        cdb_options = IClerkOpts#iclerk_options.cdb_options,
                        reload_strategy = ReloadStrategy}}
    end.

handle_call(_Msg, _From, State) ->
    {reply, not_supported, State}.

handle_cast({compact, Checker, InitiateFun, FilterFun, Inker, _Timeout},
                State) ->
    % Need to fetch manifest at start rather than have it be passed in
    % Don't want to process a queued call waiting on an old manifest
    Manifest = case leveled_inker:ink_getmanifest(Inker) of
                    [] ->
                        [];
                    [_Active|Tail] ->
                        Tail
                end,
    MaxRunLength = State#state.max_run_length,
    {FilterServer, MaxSQN} = InitiateFun(Checker),
    CDBopts = State#state.cdb_options,
    FP = CDBopts#cdb_options.file_path,
    ok = filelib:ensure_dir(FP),
    
    Candidates = scan_all_files(Manifest, FilterFun, FilterServer, MaxSQN),
    BestRun0 = assess_candidates(Candidates, MaxRunLength),
    case score_run(BestRun0, MaxRunLength) of
        Score when Score > 0 ->
            BestRun1 = sort_run(BestRun0),
            print_compaction_run(BestRun1, MaxRunLength),
            {ManifestSlice,
                PromptDelete} = compact_files(BestRun1,
                                                CDBopts,
                                                FilterFun,
                                                FilterServer,
                                                MaxSQN,
                                                State#state.reload_strategy),
            FilesToDelete = lists:map(fun(C) ->
                                            {C#candidate.low_sqn,
                                                C#candidate.filename,
                                                C#candidate.journal}
                                            end,
                                        BestRun1),
            io:format("Clerk updating Inker as compaction complete of " ++
                        "~w files~n", [length(FilesToDelete)]),
            {ok, ManSQN} = leveled_inker:ink_updatemanifest(Inker,
                                                            ManifestSlice,
                                                            FilesToDelete),
            ok = leveled_inker:ink_compactioncomplete(Inker),
            io:format("Clerk has completed compaction process~n"),
            case PromptDelete of
                true ->
                    lists:foreach(fun({_SQN, _FN, J2D}) ->
                                        leveled_cdb:cdb_deletepending(J2D,
                                                                        ManSQN,
                                                                        Inker)
                                        end,
                                    FilesToDelete),
                    {noreply, State};
                false ->
                    {noreply, State}
            end;
        Score ->
            io:format("No compaction run as highest score=~w~n", [Score]),
            ok = leveled_inker:ink_compactioncomplete(Inker),
            {noreply, State}
    end;
handle_cast({hashtable_calc, HashTree, StartPos, CDBpid}, State) ->
    {IndexList, HashTreeBin} = leveled_cdb:hashtable_calc(HashTree, StartPos),
    ok = leveled_cdb:cdb_returnhashtable(CDBpid, IndexList, HashTreeBin),
    {stop, normal, State};
handle_cast(stop, State) ->
    {stop, normal, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%============================================================================
%%% Internal functions
%%%============================================================================


check_single_file(CDB, FilterFun, FilterServer, MaxSQN, SampleSize, BatchSize) ->
    FN = leveled_cdb:cdb_filename(CDB),
    PositionList = leveled_cdb:cdb_getpositions(CDB, SampleSize),
    KeySizeList = fetch_inbatches(PositionList, BatchSize, CDB, []),
    R0 = lists:foldl(fun(KS, {ActSize, RplSize}) ->
                            {{SQN, _Type, PK}, Size} = KS,
                            Check = FilterFun(FilterServer, PK, SQN),
                            case {Check, SQN > MaxSQN} of
                                {true, _} ->
                                    {ActSize + Size - ?CRC_SIZE, RplSize};
                                {false, true} ->
                                    {ActSize + Size - ?CRC_SIZE, RplSize};
                                _ ->
                                    {ActSize, RplSize + Size - ?CRC_SIZE}
                            end end,
                        {0, 0},
                        KeySizeList),
    {ActiveSize, ReplacedSize} = R0,
    Score = case ActiveSize + ReplacedSize of
                0 ->
                    100.0;
                _ ->
                    100 * ActiveSize / (ActiveSize + ReplacedSize)
            end,
    io:format("Score for filename ~s is ~w~n", [FN, Score]),
    Score.

scan_all_files(Manifest, FilterFun, FilterServer, MaxSQN) ->
    scan_all_files(Manifest, FilterFun, FilterServer, MaxSQN, []).

scan_all_files([], _FilterFun, _FilterServer, _MaxSQN, CandidateList) ->
    CandidateList;
scan_all_files([Entry|Tail], FilterFun, FilterServer, MaxSQN, CandidateList) ->
    {LowSQN, FN, JournalP} = Entry,
    CpctPerc = check_single_file(JournalP,
                                    FilterFun,
                                    FilterServer,
                                    MaxSQN,
                                    ?SAMPLE_SIZE,
                                    ?BATCH_SIZE),
    scan_all_files(Tail,
                    FilterFun,
                    FilterServer,
                    MaxSQN,
                    CandidateList ++
                        [#candidate{low_sqn = LowSQN,
                                    filename = FN,
                                    journal = JournalP,
                                    compaction_perc = CpctPerc}]).

fetch_inbatches([], _BatchSize, _CDB, CheckedList) ->
    CheckedList;
fetch_inbatches(PositionList, BatchSize, CDB, CheckedList) ->
    {Batch, Tail} = if
                        length(PositionList) >= BatchSize ->
                            lists:split(BatchSize, PositionList);
                        true ->
                            {PositionList, []}
                    end,
    KL_List = leveled_cdb:cdb_directfetch(CDB, Batch, key_size),
    fetch_inbatches(Tail, BatchSize, CDB, CheckedList ++ KL_List).

assess_candidates(AllCandidates, MaxRunLength) ->
    NaiveBestRun = assess_candidates(AllCandidates, MaxRunLength, [], []),
    case length(AllCandidates) of
        L when L > MaxRunLength, MaxRunLength > 1 ->
            %% Assess with different offsets from the start
            SqL = lists:seq(1, MaxRunLength - 1),
            lists:foldl(fun(Counter, BestRun) ->
                                SubList = lists:nthtail(Counter,
                                                            AllCandidates),
                                assess_candidates(SubList,
                                                    MaxRunLength,
                                                    [],
                                                    BestRun)
                                end,
                            NaiveBestRun,
                            SqL);
        _ ->
            NaiveBestRun
    end.

assess_candidates([], _MaxRunLength, _CurrentRun0, BestAssessment) ->
    BestAssessment;
assess_candidates([HeadC|Tail], MaxRunLength, CurrentRun0, BestAssessment) ->
    CurrentRun1 = choose_best_assessment(CurrentRun0 ++ [HeadC],
                                            [HeadC],
                                            MaxRunLength),
    assess_candidates(Tail,
                        MaxRunLength,
                        CurrentRun1,
                        choose_best_assessment(CurrentRun1,
                                                BestAssessment,
                                                MaxRunLength)).


choose_best_assessment(RunToAssess, BestRun, MaxRunLength) ->
    case length(RunToAssess) of
        LR1 when LR1 > MaxRunLength ->
            BestRun;
        _ ->
            AssessScore = score_run(RunToAssess, MaxRunLength),
            BestScore = score_run(BestRun, MaxRunLength),
            if
                AssessScore > BestScore ->
                    RunToAssess;
                true ->
                    BestRun
            end
    end.    
        
score_run([], _MaxRunLength) ->
    0.0;
score_run(Run, MaxRunLength) ->
    TargetIncr = case MaxRunLength of
                        1 ->
                            0.0;
                        MaxRunSize ->
                            (?MAXRUN_COMPACTION_TARGET
                                - ?SINGLEFILE_COMPACTION_TARGET)
                                    / (MaxRunSize - 1)
                    end,
    Target = ?SINGLEFILE_COMPACTION_TARGET +  TargetIncr * (length(Run) - 1),
    RunTotal = lists:foldl(fun(Cand, Acc) ->
                                Acc + Cand#candidate.compaction_perc end,
                            0.0,
                            Run),
    Target - RunTotal / length(Run).


print_compaction_run(BestRun, MaxRunLength) ->
    io:format("Compaction to be performed on ~w files with score of ~w~n",
                    [length(BestRun), score_run(BestRun, MaxRunLength)]),
    lists:foreach(fun(File) ->
                        io:format("Filename ~s is part of compaction run~n",
                                    [File#candidate.filename])
                                        
                        end,
                    BestRun).

sort_run(RunOfFiles) ->
    CompareFun = fun(Cand1, Cand2) ->
                    Cand1#candidate.low_sqn =< Cand2#candidate.low_sqn end,
    lists:sort(CompareFun, RunOfFiles).


compact_files([], _CDBopts, _FilterFun, _FilterServer, _MaxSQN, _RStrategy) ->
    {[], 0};
compact_files(BestRun, CDBopts, FilterFun, FilterServer, MaxSQN, RStrategy) ->
    BatchesOfPositions = get_all_positions(BestRun, []),
    compact_files(BatchesOfPositions,
                                CDBopts,
                                null,
                                FilterFun,
                                FilterServer,
                                MaxSQN,
                                RStrategy,
                                [],
                                true).


compact_files([], _CDBopts, null, _FilterFun, _FilterServer, _MaxSQN,
                            _RStrategy, ManSlice0, PromptDelete0) ->
    {ManSlice0, PromptDelete0};
compact_files([], _CDBopts, ActiveJournal0, _FilterFun, _FilterServer, _MaxSQN,
                            _RStrategy, ManSlice0, PromptDelete0) ->
    ManSlice1 = ManSlice0 ++ generate_manifest_entry(ActiveJournal0),
    {ManSlice1, PromptDelete0};
compact_files([Batch|T], CDBopts, ActiveJournal0,
                            FilterFun, FilterServer, MaxSQN, 
                            RStrategy, ManSlice0, PromptDelete0) ->
    {SrcJournal, PositionList} = Batch,
    KVCs0 = leveled_cdb:cdb_directfetch(SrcJournal,
                                        PositionList,
                                        key_value_check),
    R0 = filter_output(KVCs0,
                        FilterFun,
                        FilterServer,
                        MaxSQN,
                        RStrategy),
    {KVCs1, PromptDelete1} = R0,
    PromptDelete2 = case {PromptDelete0, PromptDelete1} of
                        {true, true} ->
                            true;
                        _ ->
                            false
                    end,
    {ActiveJournal1, ManSlice1} = write_values(KVCs1,
                                                CDBopts, 
                                                ActiveJournal0,
                                                ManSlice0),
    compact_files(T, CDBopts, ActiveJournal1, FilterFun, FilterServer, MaxSQN,
                                RStrategy, ManSlice1, PromptDelete2).

get_all_positions([], PositionBatches) ->
    PositionBatches;
get_all_positions([HeadRef|RestOfBest], PositionBatches) ->
    SrcJournal = HeadRef#candidate.journal,
    Positions = leveled_cdb:cdb_getpositions(SrcJournal, all),
    io:format("Compaction source ~s has yielded ~w positions~n",
                [HeadRef#candidate.filename, length(Positions)]),
    Batches = split_positions_into_batches(lists:sort(Positions),
                                            SrcJournal,
                                            []),
    get_all_positions(RestOfBest, PositionBatches ++ Batches).

split_positions_into_batches([], _Journal, Batches) ->
    Batches;
split_positions_into_batches(Positions, Journal, Batches) ->
    {ThisBatch, Tail} = if
                            length(Positions) > ?BATCH_SIZE ->
                                lists:split(?BATCH_SIZE, Positions);
                            true ->
                                {Positions, []}
                        end,
    split_positions_into_batches(Tail,
                                    Journal,
                                    Batches ++ [{Journal, ThisBatch}]).


filter_output(KVCs, FilterFun, FilterServer, MaxSQN, ReloadStrategy) ->
    lists:foldl(fun(KVC0, {Acc, PromptDelete}) ->
                    R = leveled_codec:compact_inkerkvc(KVC0, ReloadStrategy),
                    case R of
                        skip ->
                            {Acc, PromptDelete};
                        {TStrat, KVC1} ->
                            {K, _V, CrcCheck} = KVC0,
                            {SQN, LedgerKey} = leveled_codec:from_journalkey(K),
                            KeyValid = FilterFun(FilterServer, LedgerKey, SQN),
                            case {KeyValid, CrcCheck, SQN > MaxSQN, TStrat} of
                                {true, true, _, _} ->
                                    {Acc ++ [KVC0], PromptDelete};
                                {false, true, true, _} ->
                                    {Acc ++ [KVC0], PromptDelete};
                                {false, true, false, retain} ->
                                    {Acc ++ [KVC1], PromptDelete};
                                {false, true, false, _} ->
                                    {Acc, PromptDelete};
                                {_, false, _, _} ->
                                    io:format("Corrupted value found for "
                                                ++ "Journal Key ~w~n", [K]),
                                    {Acc, false}
                            end
                    end
                    end,
                {[], true},
                KVCs).
    

write_values([], _CDBopts, Journal0, ManSlice0) ->
    {Journal0, ManSlice0};
write_values(KVCList, CDBopts, Journal0, ManSlice0) ->
    KVList = lists:map(fun({K, V, _C}) ->
                            {K, leveled_codec:create_value_for_journal(V)}
                            end,
                        KVCList),
    {ok, Journal1} = case Journal0 of
                            null ->
                                {TK, _TV} = lists:nth(1, KVList),
                                {SQN, _LK} = leveled_codec:from_journalkey(TK),
                                FP = CDBopts#cdb_options.file_path,
                                FN = leveled_inker:filepath(FP,
                                                            SQN,
                                                            compact_journal),
                                io:format("Generate journal for compaction"
                                                ++ " with filename ~s~n",
                                            [FN]),
                                leveled_cdb:cdb_open_writer(FN,
                                                            CDBopts);
                            _ ->
                                {ok, Journal0}
                        end,
    R = leveled_cdb:cdb_mput(Journal1, KVList),
    case R of
        ok ->
            {Journal1, ManSlice0};
        roll ->
            ManSlice1 = ManSlice0 ++ generate_manifest_entry(Journal1),
            write_values(KVCList, CDBopts, null, ManSlice1)
    end.
    

generate_manifest_entry(ActiveJournal) ->
    {ok, NewFN} = leveled_cdb:cdb_complete(ActiveJournal),
    {ok, PidR} = leveled_cdb:cdb_open_reader(NewFN),
    {StartSQN, _Type, _PK} = leveled_cdb:cdb_firstkey(PidR),
    [{StartSQN, NewFN, PidR}].
                        
                    
    

    
    

%%%============================================================================
%%% Test
%%%============================================================================


-ifdef(TEST).

simple_score_test() ->
    Run1 = [#candidate{compaction_perc = 75.0},
            #candidate{compaction_perc = 75.0},
            #candidate{compaction_perc = 76.0},
            #candidate{compaction_perc = 70.0}],
    ?assertMatch(6.0, score_run(Run1, 4)),
    Run2 = [#candidate{compaction_perc = 75.0}],
    ?assertMatch(-15.0, score_run(Run2, 4)),
    ?assertMatch(0.0, score_run([], 4)),
    Run3 = [#candidate{compaction_perc = 100.0}],
    ?assertMatch(-40.0, score_run(Run3, 4)).

score_compare_test() ->
    Run1 = [#candidate{compaction_perc = 75.0},
            #candidate{compaction_perc = 75.0},
            #candidate{compaction_perc = 76.0},
            #candidate{compaction_perc = 70.0}],
    ?assertMatch(6.0, score_run(Run1, 4)),
    Run2 = [#candidate{compaction_perc = 75.0}],
    ?assertMatch(Run1, choose_best_assessment(Run1, Run2, 4)),
    ?assertMatch(Run2, choose_best_assessment(Run1 ++ Run2, Run2, 4)).

find_bestrun_test() ->
%% Tests dependent on these defaults
%% -define(MAX_COMPACTION_RUN, 4).
%% -define(SINGLEFILE_COMPACTION_TARGET, 60.0).
%% -define(MAXRUN_COMPACTION_TARGET, 80.0).
%% Tested first with blocks significant as no back-tracking
    Block1 = [#candidate{compaction_perc = 75.0},
                #candidate{compaction_perc = 85.0},
                #candidate{compaction_perc = 62.0},
                #candidate{compaction_perc = 70.0}],
    Block2 = [#candidate{compaction_perc = 58.0},
                #candidate{compaction_perc = 95.0},
                #candidate{compaction_perc = 95.0},
                #candidate{compaction_perc = 65.0}],
    Block3 = [#candidate{compaction_perc = 90.0},
                #candidate{compaction_perc = 100.0},
                #candidate{compaction_perc = 100.0},
                #candidate{compaction_perc = 100.0}],
    Block4 = [#candidate{compaction_perc = 75.0},
                #candidate{compaction_perc = 76.0},
                #candidate{compaction_perc = 76.0},
                #candidate{compaction_perc = 60.0}],
    Block5 = [#candidate{compaction_perc = 80.0},
                #candidate{compaction_perc = 80.0}],
    CList0 = Block1 ++ Block2 ++ Block3 ++ Block4 ++ Block5,
    ?assertMatch(Block4, assess_candidates(CList0, 4, [], [])),
    CList1 = CList0 ++ [#candidate{compaction_perc = 20.0}],
    ?assertMatch([#candidate{compaction_perc = 20.0}],
                    assess_candidates(CList1, 4, [], [])),
    CList2 = Block4 ++ Block3 ++ Block2 ++ Block1 ++ Block5,
    ?assertMatch(Block4, assess_candidates(CList2, 4, [], [])),
    CList3 = Block5 ++ Block1 ++ Block2 ++ Block3 ++ Block4,
    ?assertMatch([#candidate{compaction_perc = 62.0},
                        #candidate{compaction_perc = 70.0},
                        #candidate{compaction_perc = 58.0}],
                    assess_candidates(CList3, 4, [], [])),
    %% Now do some back-tracking to get a genuinely optimal solution without
    %% needing to re-order
    ?assertMatch([#candidate{compaction_perc = 62.0},
                        #candidate{compaction_perc = 70.0},
                        #candidate{compaction_perc = 58.0}],
                    assess_candidates(CList0, 4)),
    ?assertMatch([#candidate{compaction_perc = 62.0},
                        #candidate{compaction_perc = 70.0},
                        #candidate{compaction_perc = 58.0}],
                    assess_candidates(CList0, 5)),
    ?assertMatch([#candidate{compaction_perc = 62.0},
                        #candidate{compaction_perc = 70.0},
                        #candidate{compaction_perc = 58.0},
                        #candidate{compaction_perc = 95.0},
                        #candidate{compaction_perc = 95.0},
                        #candidate{compaction_perc = 65.0}], 
                    assess_candidates(CList0, 6)).

test_ledgerkey(Key) ->
    {o, "Bucket", Key, null}.

test_inkerkv(SQN, Key, V, IdxSpecs) ->
    {{SQN, ?INKT_STND, test_ledgerkey(Key)}, term_to_binary({V, IdxSpecs})}.

fetch_testcdb(RP) ->
    FN1 = leveled_inker:filepath(RP, 1, new_journal),
    {ok, CDB1} = leveled_cdb:cdb_open_writer(FN1, #cdb_options{}),
    {K1, V1} = test_inkerkv(1, "Key1", "Value1", []),
    {K2, V2} = test_inkerkv(2, "Key2", "Value2", []),
    {K3, V3} = test_inkerkv(3, "Key3", "Value3", []),
    {K4, V4} = test_inkerkv(4, "Key1", "Value4", []),
    {K5, V5} = test_inkerkv(5, "Key1", "Value5", []),
    {K6, V6} = test_inkerkv(6, "Key1", "Value6", []),
    {K7, V7} = test_inkerkv(7, "Key1", "Value7", []),
    {K8, V8} = test_inkerkv(8, "Key1", "Value8", []),
    ok = leveled_cdb:cdb_put(CDB1, K1, V1),
    ok = leveled_cdb:cdb_put(CDB1, K2, V2),
    ok = leveled_cdb:cdb_put(CDB1, K3, V3),
    ok = leveled_cdb:cdb_put(CDB1, K4, V4),
    ok = leveled_cdb:cdb_put(CDB1, K5, V5),
    ok = leveled_cdb:cdb_put(CDB1, K6, V6),
    ok = leveled_cdb:cdb_put(CDB1, K7, V7),
    ok = leveled_cdb:cdb_put(CDB1, K8, V8),
    {ok, FN2} = leveled_cdb:cdb_complete(CDB1),
    leveled_cdb:cdb_open_reader(FN2).

check_single_file_test() ->
    RP = "../test/journal",
    {ok, CDB} = fetch_testcdb(RP),
    LedgerSrv1 = [{8, {o, "Bucket", "Key1", null}},
                    {2, {o, "Bucket", "Key2", null}},
                    {3, {o, "Bucket", "Key3", null}}],
    LedgerFun1 = fun(Srv, Key, ObjSQN) ->
                    case lists:keyfind(ObjSQN, 1, Srv) of
                        {ObjSQN, Key} ->
                            true;
                        _ ->
                            false
                    end end,
    Score1 = check_single_file(CDB, LedgerFun1, LedgerSrv1, 9, 8, 4),
    ?assertMatch(37.5, Score1),
    LedgerFun2 = fun(_Srv, _Key, _ObjSQN) -> true end,
    Score2 = check_single_file(CDB, LedgerFun2, LedgerSrv1, 9, 8, 4),
    ?assertMatch(100.0, Score2),
    Score3 = check_single_file(CDB, LedgerFun1, LedgerSrv1, 9, 8, 3),
    ?assertMatch(37.5, Score3),
    Score4 = check_single_file(CDB, LedgerFun1, LedgerSrv1, 4, 8, 4),
    ?assertMatch(75.0, Score4),
    ok = leveled_cdb:cdb_deletepending(CDB),
    ok = leveled_cdb:cdb_destroy(CDB).


compact_single_file_setup() ->
    RP = "../test/journal",
    {ok, CDB} = fetch_testcdb(RP),
    Candidate = #candidate{journal = CDB,
                            low_sqn = 1,
                            filename = "test",
                            compaction_perc = 37.5},
    LedgerSrv1 = [{8, {o, "Bucket", "Key1", null}},
                    {2, {o, "Bucket", "Key2", null}},
                    {3, {o, "Bucket", "Key3", null}}],
    LedgerFun1 = fun(Srv, Key, ObjSQN) ->
                    case lists:keyfind(ObjSQN, 1, Srv) of
                        {ObjSQN, Key} ->
                            true;
                        _ ->
                            false
                    end end,
    CompactFP = leveled_inker:filepath(RP, journal_compact_dir),
    ok = filelib:ensure_dir(CompactFP),
    {Candidate, LedgerSrv1, LedgerFun1, CompactFP, CDB}.

compact_single_file_recovr_test() ->
    {Candidate,
        LedgerSrv1,
        LedgerFun1,
        CompactFP,
        CDB} = compact_single_file_setup(),
    R1 = compact_files([Candidate],
                        #cdb_options{file_path=CompactFP},
                        LedgerFun1,
                        LedgerSrv1,
                        9,
                        [{?STD_TAG, recovr}]),
    {ManSlice1, PromptDelete1} = R1,
    ?assertMatch(true, PromptDelete1),
    [{LowSQN, FN, PidR}] = ManSlice1,
    io:format("FN of ~s~n", [FN]),
    ?assertMatch(2, LowSQN),
    ?assertMatch(probably,
                    leveled_cdb:cdb_keycheck(PidR,
                                                {8,
                                                    stnd,
                                                    test_ledgerkey("Key1")})),
    ?assertMatch(missing, leveled_cdb:cdb_get(PidR,
                                                {7,
                                                    stnd,
                                                    test_ledgerkey("Key1")})),
    ?assertMatch(missing, leveled_cdb:cdb_get(PidR,
                                                {1,
                                                    stnd,
                                                    test_ledgerkey("Key1")})),
    {_RK1, RV1} = leveled_cdb:cdb_get(PidR,
                                        {2,
                                            stnd,
                                            test_ledgerkey("Key2")}),
    ?assertMatch({"Value2", []}, binary_to_term(RV1)),
    ok = leveled_cdb:cdb_deletepending(CDB),
    ok = leveled_cdb:cdb_destroy(CDB).


compact_single_file_retain_test() ->
    {Candidate,
        LedgerSrv1,
        LedgerFun1,
        CompactFP,
        CDB} = compact_single_file_setup(),
    R1 = compact_files([Candidate],
                        #cdb_options{file_path=CompactFP},
                        LedgerFun1,
                        LedgerSrv1,
                        9,
                        [{?STD_TAG, retain}]),
    {ManSlice1, PromptDelete1} = R1,
    ?assertMatch(true, PromptDelete1),
    [{LowSQN, FN, PidR}] = ManSlice1,
    io:format("FN of ~s~n", [FN]),
    ?assertMatch(1, LowSQN),
    ?assertMatch(probably,
                    leveled_cdb:cdb_keycheck(PidR,
                                                {8,
                                                    stnd,
                                                    test_ledgerkey("Key1")})),
    ?assertMatch(missing, leveled_cdb:cdb_get(PidR,
                                                {7,
                                                    stnd,
                                                    test_ledgerkey("Key1")})),
    ?assertMatch(missing, leveled_cdb:cdb_get(PidR,
                                                {1,
                                                    stnd,
                                                    test_ledgerkey("Key1")})),
    {_RK1, RV1} = leveled_cdb:cdb_get(PidR,
                                        {2,
                                            stnd,
                                            test_ledgerkey("Key2")}),
    ?assertMatch({"Value2", []}, binary_to_term(RV1)),
    ok = leveled_cdb:cdb_deletepending(CDB),
    ok = leveled_cdb:cdb_destroy(CDB).

compact_empty_file_test() ->
    RP = "../test/journal",
    FN1 = leveled_inker:filepath(RP, 1, new_journal),
    CDBopts = #cdb_options{binary_mode=true},
    {ok, CDB1} = leveled_cdb:cdb_open_writer(FN1, CDBopts),
    ok = leveled_cdb:cdb_put(CDB1, {1, stnd, test_ledgerkey("Key1")}, <<>>),
    {ok, FN2} = leveled_cdb:cdb_complete(CDB1),
    {ok, CDB2} = leveled_cdb:cdb_open_reader(FN2),
    LedgerSrv1 = [{8, {o, "Bucket", "Key1", null}},
                    {2, {o, "Bucket", "Key2", null}},
                    {3, {o, "Bucket", "Key3", null}}],
    LedgerFun1 = fun(Srv, Key, ObjSQN) ->
                    case lists:keyfind(ObjSQN, 1, Srv) of
                        {ObjSQN, Key} ->
                            true;
                        _ ->
                            false
                    end end,
    Score1 = check_single_file(CDB2, LedgerFun1, LedgerSrv1, 9, 8, 4),
    ?assertMatch(100.0, Score1).

compare_candidate_test() ->
    Candidate1 = #candidate{low_sqn=1},
    Candidate2 = #candidate{low_sqn=2},
    Candidate3 = #candidate{low_sqn=3},
    Candidate4 = #candidate{low_sqn=4},
    ?assertMatch([Candidate1, Candidate2, Candidate3, Candidate4],
                sort_run([Candidate3, Candidate2, Candidate4, Candidate1])).       

-endif.
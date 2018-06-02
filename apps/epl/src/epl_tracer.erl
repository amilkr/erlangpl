%%
%% %CopyrightBegin%
%%
%% Copyright Michal Slaski 2013. All Rights Reserved.
%%
%% %CopyrightEnd%
%%
-module(epl_tracer).
-behaviour(gen_server).

-include_lib("epl/include/epl.hrl").

%% API
-export([start_link/1,
         subscribe/2,
         unsubscribe/2,
         command/3,
         trace_pid/1,
         track_timeline/1,
         enable_ets_call_tracing/1,
         enable_ets_table_call_tracing/2,
         disable_ets_table_call_tracing/1,
         disable_ets_call_tracing/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% Types
-export_type([tab/0]).

-type tab() :: atom() | integer() | reference().

-record(state, {subscribers = [],
                ref,
                remote_pid,
                timeout = 0}).

-define(POLL, 5000).

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc Starts epl_tracer gen_server process.
-spec start_link(Node :: node()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Node) ->
    gen_server:start_link({local, Node}, ?MODULE, Node, []).


%% @doc Adds provided `Pid' to `Node' tracer's subscribers list.
-spec subscribe(Node :: node(), Pid :: pid()) -> ok.
subscribe(Node, Pid) ->
    gen_server:call(Node, {subscribe, Pid}).

%% @doc Removes provided `Pid' from `Node' tracer's subscribers list.
-spec unsubscribe(Node :: node(), Pid :: pid()) -> ok.
unsubscribe(Node, Pid) ->
    gen_server:call(Node, {unsubscribe, Pid}).

%% @doc Runs provided `Fun' with `Args' on `Node'.
-spec command(Node :: node(), Fun :: fun(), Args :: list()) -> tuple().
command(Node, Fun, Args) ->
    gen_server:call(Node, {command, Fun, Args}, 10000).

%% @doc Traces provied `Pid'.
-spec trace_pid(Pid :: pid()) -> ok.
trace_pid(Pid) ->
    Node = erlang:node(Pid),
    gen_server:call(Node, {trace_pid, Pid}).

%% @doc Enables tracing for ets insert/lookup functions calls on the `Node'.
-spec enable_ets_call_tracing(Node :: node()) -> ok.
enable_ets_call_tracing(Node) ->
    gen_server:call(Node, enable_ets_call_tracing).

%% @doc Disables tracing for ets insert/lookup functions calls on the `Node'.
-spec disable_ets_call_tracing(Node :: node()) -> ok.
disable_ets_call_tracing(Node) ->
    gen_server:call(Node, disable_ets_call_tracing).

%% @doc Enables tracing for ets insert/lookup functions calls to a particular
%% ETS `Table' on the `Node'.
-spec enable_ets_table_call_tracing(Node :: node(), Table :: tab()) -> ok.
enable_ets_table_call_tracing(Node, Table) ->
    gen_server:call(Node, {enable_ets_tab_call_tracing, Table}).

%% @doc Disables tracing for ets insert/lookup functions calls to all the ETS
%% tables on the `Node'.
-spec disable_ets_table_call_tracing(Node :: node()) -> ok.
disable_ets_table_call_tracing(Node) ->
    disable_ets_call_tracing(Node).

track_timeline(Pid) ->
    Node = erlang:node(Pid),
    gen_server:cast(Node, {track_timeline, Pid}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init(Node) ->
    RemoteFunStr =
        "fun (F, Ref, init) ->
                 %% create neccessary tables
                 EtsOptions = [named_table, ordered_set, private],
                 %% timeline needs two tables, one for caching messages, second for storing tracked pids
                 epl_timeline_cache  = ets:new(epl_timeline_cache, [named_table, set, private]),
                 epl_timeline_pids  = ets:new(epl_timeline_pids, [named_table, set, private]),
                 epl_receive   = ets:new(epl_receive,   EtsOptions),
                 epl_send      = ets:new(epl_send,      EtsOptions),
                 epl_send_self = ets:new(epl_send_self, EtsOptions),
                 epl_spawn     = ets:new(epl_spawn,     EtsOptions),
                 epl_exit      = ets:new(epl_exit,      EtsOptions),
                 epl_trace     = ets:new(epl_trace, [named_table,bag,private]),
                 epl_ets_func  = ets:new(epl_ets_func,
                                         [named_table, duplicate_bag, private]),
                 epl_ets_traffic = ets:new(epl_ets_traffic, EtsOptions),
                 %% Table for storing some additional information for the tracer
                 %% process
                 epl_additional = ets:new(epl_additional, EtsOptions),

                 %% turn on tracer for all processes
                 TraceFlags = [send, 'receive', procs, timestamp],
                 erlang:trace(all, true, TraceFlags),
                 F(F, Ref, undefined);
            (F, Ref, Trace) ->
                 Name = fun(Pid) ->
                            try
                                case erlang:process_info(Pid, registered_name) of
                                    undefined -> Pid;
                                    {registered_name, RName} -> RName
                                end
                            catch _:_ -> Pid
                            end
                         end,
                 receive
                     {trace_ts, Pid, 'receive', Msg, _TS} when Pid /= self() ->
                         %% we count received messages and their sizes
                         Size = erts_debug:flat_size(Msg),
                         case ets:lookup(epl_timeline_pids, Pid) of
                             [] -> ok;
                             _ ->
                                 TimelineOld = case ets:lookup(epl_timeline_cache, Pid) of
                                                   [] -> [];
                                                   [{Pid, Timeline}]  -> Timeline

                                               end,
                                 case Msg of
                                     {system, _,_} -> ok;
                                     _ ->
                                         NewValue = {Msg, sys:get_state(Pid)},
                                         ets:delete(epl_timeline_cache, Pid),
                                         ets:insert(epl_timeline_cache, {Pid, [NewValue | TimelineOld]})
                                 end
                         end,
                         case ets:lookup(epl_receive, Pid) of
                             [] -> ets:insert(epl_receive, {Pid, 1, Size});
                             _  -> ets:update_counter(epl_receive,
                                                      Pid, [{2, 1}, {3, Size}])
                         end,
                         F(F, Ref, Trace);
                     {trace_ts, Pid1, send, _Msg, Pid2, _TS}
                       when Pid1 < Pid2, Pid1 /= self(), Pid2 /= self() ->
                         %% we have one key for each Pid pair
                         %% the smaller Pid is first element of the key
                         Name1 = Name(Pid1),
                         Name2 = Name(Pid2),
                         Insert = fun() ->
                            case ets:lookup(epl_send, {Name1, Name2}) of
                             [] -> ets:insert(epl_send, {{Name1, Name2}, 1, 0});
                             _  -> ets:update_counter(epl_send,
                                                      {Name1, Name2}, {2, 1})
                            end
                         end,
                         %% we have one key for each Pid pair
                         %% the smaller Pid is first element of the key
                         try

                            case {Name1, Name2} of
                                {Pid1, Pid2} -> ok;
                                _ -> Insert()
                            end

                         catch
                            _:_ -> Insert()
                         end,

                         F(F, Ref, Trace);
                     {trace_ts, Pid1, send, _Msg, Pid2, _TS}
                       when Pid1 > Pid2, Pid1 /= self(), Pid2 /= self() ->
                         Name1 = Name(Pid1),
                         Name2 = Name(Pid2),
                         Insert = fun() ->
                            case ets:lookup(epl_send, {Name2, Name1}) of
                                [] -> ets:insert(epl_send, {{Name2, Name1}, 0, 1});
                                _  -> ets:update_counter(epl_send, {Name2, Name1}, {3, 1})
                            end
                         end,
                         %% we have one key for each Pid pair
                         %% the smaller Pid is first element of the key
                         try

                            case {Name1, Name2} of
                                {Pid1, Pid2} -> ok;
                                _ -> Insert()
                            end

                         catch
                            _:_ -> Insert()
                         end,
                         F(F, Ref, Trace);
                     {trace_ts, Pid, send, _Msg, Pid, _TS} ->
                         %% sending to yourself? It is a special case...
                         case ets:lookup(epl_send_self, Pid) of
                             [] -> ets:insert(epl_send_self, {Pid, 1});
                             _  -> ets:update_counter(epl_send_self, Pid, 1)
                         end,
                         F(F, Ref, Trace);
                     {trace_ts, _, spawn, Pid, MFA, TS} ->
                         ets:insert(epl_spawn, {Pid, MFA, TS}),
                         F(F, Ref, Trace);
                     {trace_ts, Pid, exit, Reason, TS} ->
                         ets:insert(epl_exit, {Pid, Reason, TS}),
                         F(F, Ref, Trace);
                     {trace_ts, Pid, call, {ets, Func, [Tab | _]}, TS} ->
                         case ets:lookup(epl_additional, trace_tab) of
                             [{trace_tab, true}] ->
                                 case ets:lookup(epl_ets_traffic,
                                                 {Pid, Tab, Func}) of
                                     [] ->
                                         ets:insert(epl_ets_traffic,
                                                    {{Pid, Tab, Func}, 0}),
                                         ets:update_counter(epl_ets_traffic,
                                                            {Pid, Tab, Func},
                                                            {2, 1});
                                     _ ->
                                         ets:update_counter(epl_ets_traffic,
                                                            {Pid, Tab, Func},
                                                            {2, 1})
                                 end;
                             _Else ->
                                 ets:insert(epl_ets_func, {Pid, Tab, Func, TS})
                         end,
                         F(F, Ref, Trace);
                     {trace_ts, Pid, return_to, _, TS} ->
                         ets:insert(epl_ets_func, {Pid, null, return_to, TS}),
                         F(F, Ref, Trace);
                     %% ignore trace messages that we don't use
                     {trace_ts, Trace, send_to_non_existing_process,_,_,_}
                       = T ->
                         ets:insert(epl_trace, T),
                         F(F, Ref, Trace);
                     {trace_ts, Trace, register, _, _} = T ->
                         ets:insert(epl_trace, T),
                         F(F, Ref, Trace);
                     {trace_ts, Trace, unregister, _, _} = T ->
                         ets:insert(epl_trace, T),
                         F(F, Ref, Trace);
                     {trace_ts, Trace, link, _, _} = T ->
                         ets:insert(epl_trace, T),
                         F(F, Ref, Trace);
                     {trace_ts, Trace, unlink, _, _} = T ->
                         ets:insert(epl_trace, T),
                         F(F, Ref, Trace);
                     {trace_ts, Trace, getting_linked, _, _} = T ->
                         ets:insert(epl_trace, T),
                         F(F, Ref, Trace);
                     {trace_ts, Trace, getting_unlinked, _, _} = T ->
                         ets:insert(epl_trace, T),
                         F(F, Ref, Trace);
                     {trace_ts, _, _, _, _} ->
                         F(F, Ref, Trace);
                     {trace_ts, _, _, _, _, _} ->
                         F(F, Ref, Trace);
                     {Ref, Pid, {process_info, P}} when is_pid(P) ->
                         PInfo = process_info(P),
                         Pid ! {Ref, PInfo},
                         F(F, Ref, Trace);
                     {Ref, Pid, {trace_pid, NewTrace}} when is_pid(NewTrace) ->
                         F(F, Ref, NewTrace);
                     {Ref, _Pid, {enable_ets_call_tracing, TraceFlags,
                                  MatchSpec, Additional}} ->
                         [ets:insert(epl_additional, A) || A <- Additional],
                         erlang:trace(all, true, TraceFlags),
                         erlang:trace_pattern({ets, insert, 2}, MatchSpec,
                                              [local]),
                         erlang:trace_pattern({ets, lookup, 2}, MatchSpec,
                                              [local]),
                         F(F, Ref, Trace);
                     {Ref, _Pid, disable_ets_call_tracing} ->
                         erlang:trace_pattern({ets, insert, 2}, false, [local]),
                         erlang:trace_pattern({ets, lookup, 2}, false, [local]),
                         erlang:trace(all, false, [call, return_to]),
                         ets:insert(epl_additional, {trace_tab, false}),
                         F(F, Ref, Trace);
                     {Ref, Pid, List} when is_list(List) ->
                         %% received list of commands to execute
                         Proplist = [{Key, catch apply(Fun, Args)}
                                 || {Key, Fun, Args} <- List],
                         Pid ! {Ref, Proplist},
                         F(F, Ref, Trace);
                     {Ref, Pid, {track_timeline, Tracked}} ->
                         ets:insert(epl_timeline_pids, {Tracked, []}),
                         F(F, Ref, Trace);
                     M ->
                         %% if we receive an unknown message
                         %% we stop tracing and exit
                         erlang:trace(all, false, []),
                         exit(unknown_msg, M)
                 end
         end.",

    {ok, RemoteFun} = epl:make_fun_for_remote(Node, RemoteFunStr),
    Ref = make_ref(),
    RemotePid = spawn_link(Node, erlang, apply, [RemoteFun,
                                                 [RemoteFun, Ref, init]]),

    {ok, #state{ref = Ref, remote_pid = RemotePid}, ?POLL}.

handle_cast({track_timeline, Pid}, State = #state{remote_pid = RPid, ref = Ref}) ->
    RPid ! {Ref, self(), {track_timeline, Pid}},
    {noreply, State, ?POLL};
handle_cast(Request, _State) ->
    exit({not_implemented, Request}).

handle_call({subscribe, Pid}, _From, State = #state{subscribers = Subs}) ->
    {reply, ok, State#state{subscribers = [Pid|Subs]}, ?POLL};
handle_call({unsubscribe, Pid}, _From, State = #state{subscribers = Subs}) ->
    {reply, ok, State#state{subscribers = lists:delete(Pid, Subs)}, ?POLL};
handle_call({trace_pid, Pid}, _, State = #state{ref=Ref, remote_pid=RPid}) ->
    RPid ! {Ref, self(), {trace_pid, Pid}},
    {reply, ok, State, ?POLL};
handle_call({command, Fun, Args}, _, State = #state{ref=Ref, remote_pid=RPid}) ->
    RPid ! {Ref, self(), [{command, Fun, Args}]},
    receive
        {Ref, [{command, ReturnVal}]} ->
            {reply, {ok, ReturnVal}, State, ?POLL}
    after 5000 ->
            ?ERROR("timed out while collecting data from node~n", []),
            NewState = State#state{timeout = State#state.timeout + 1},
            {reply, {error, timeout}, NewState, ?POLL}
    end;
handle_call(enable_ets_call_tracing, _, State = #state{ref=Ref,
                                                       remote_pid=RPid}) ->
    TraceFlag = [call, return_to, timestamp],
    MatchSpec = true,
    Additional = [],
    RPid ! {Ref, self(), {enable_ets_call_tracing, TraceFlag, MatchSpec,
                          Additional}},
    {reply, ok, State, ?POLL};
handle_call({enable_ets_tab_call_tracing, Tab}, _, State = #state{ref=Ref,
                                                       remote_pid=RPid}) ->
    TraceFlag = [call, timestamp],
    MatchSpec = [{[Tab, '_'], [], []}],
    Additional = [{trace_tab, true}],
    RPid ! {Ref, self(), {enable_ets_call_tracing, TraceFlag, MatchSpec,
                          Additional}},
    {reply, ok, State, ?POLL};
handle_call(disable_ets_call_tracing, _, State = #state{ref=Ref,
                                                       remote_pid=RPid}) ->
    RPid ! {Ref, self(), disable_ets_call_tracing},
    {reply, ok, State, ?POLL};
handle_call(Request, _From, _State) ->
    exit({not_implemented, Request}).


handle_info(timeout, #state{remote_pid = Pid, timeout = T}) when T > 10 ->
    {stop, {max_timeout, node(Pid)}};
handle_info(timeout,
            State = #state{ref = Ref, remote_pid = RPid, subscribers = Subs}) ->
    GetCountersList =
        [{process_count, fun erlang:system_info/1, [process_count]},
         {memory_total,  fun erlang:memory/1, [total]},
         {spawn,         fun ets:tab2list/1, [epl_spawn]},
         {spawn_,        fun ets:delete_all_objects/1, [epl_spawn]},
         {timeline,      fun ets:tab2list/1, [epl_timeline_cache]},
         {timeline_,     fun ets:delete_all_objects/1, [epl_timeline_cache]},
         {exit,          fun ets:tab2list/1, [epl_exit]},
         {exit_,         fun ets:delete_all_objects/1, [epl_exit]},
         {send,          fun ets:tab2list/1, [epl_send]},
         {send_,         fun ets:delete_all_objects/1, [epl_send]},
         {send_self,     fun ets:tab2list/1, [epl_send_self]},
         {send_self_,    fun ets:delete_all_objects/1, [epl_send_self]},
         {'receive',     fun ets:tab2list/1, [epl_receive]},
         {receive_,      fun ets:delete_all_objects/1, [epl_receive]},
         {trace,         fun ets:tab2list/1, [epl_trace]},
         {trace_,        fun ets:delete_all_objects/1, [epl_trace]},
         {ets_func,      fun ets:tab2list/1, [epl_ets_func]},
         {ets_func_,     fun ets:delete_all_objects/1, [epl_ets_func]},
         {ets_traffic,   fun ets:tab2list/1, [epl_ets_traffic]},
         {ets_traffic_,  fun ets:delete_all_objects/1, [epl_ets_traffic]}
        ],

    RPid ! {Ref, self(), GetCountersList},

    receive
        {Ref, Proplist} when is_list(Proplist) ->
            %% assert all ets tables were cleared
            EtsTables = [spawn_, exit_, send_, send_self_, receive_, trace_,
                         timeline_, ets_func_, ets_traffic_],
            [{Key, true} = lists:keyfind(Key, 1, Proplist)
             || Key <- EtsTables],

            %% remove unwanted properties
            Proplist1 = lists:foldl(fun(Key, L) ->
                                            lists:keydelete(Key, 1, L)
                                    end,
                                    Proplist,
                                    EtsTables),

            {value, {timeline, Timelines}, PropsListWithoutFaultyTimelines } = lists:keytake(timeline, 1, Proplist1),
            PidsAsLists = lists:map(fun({Key, Value}) -> {pid_to_list(Key), Value} end, Timelines),
            Proplist2 = [{timeline, PidsAsLists} | PropsListWithoutFaultyTimelines],


            %% [{process_count,34},
            %%  {memory_total,5969496},
            %%  {spawned,
            %%   [{<5984.597.0>, {erlang,apply,[#Fun<erl_eval.20.82930912>,[]]}},
            %%    {<5984.598.0>, {erlang,apply,[#Fun<shell.3.20862592>,[]]}},
            %%    {<5984.599.0>, {erlang,apply,[#Fun<erl_eval.20.82930912>,[]]}}
            %%   ]},
            %%  {exited,
            %%   [{<5984.607.0>, {ok, [{call,1, {atom,1,spawn}, [{'fun',1,
            %%            {clauses, [{clause,1,[],[],[{atom,1,ok}]}]}}]}], 2}},
            %%    {<5984.614.0>,normal},
            %%    {<5984.646.0>,{badarith,[{erlang,'/',[1,0],[]}]}}
            %%   ]},
            %%  {sent,[{{#Port<5984.431>,<5984.28.0>},0,8},
            %%         {{<5984.28.0>,<5984.30.0>},2,6}]},
            %%  {sent_self,[]},
            %%  {received,[{<5984.28.0>,8,314},
            %%             {<5984.30.0>,2,24}]}]

            Key = {node(RPid), os:timestamp()},
            [Pid ! {data, Key, Proplist2} || Pid <- Subs],

            {noreply, State, ?POLL}
    after 5000 ->
            ?ERROR("timed out while collecting data from node~n", []),
            {noreply, State#state{timeout = State#state.timeout + 1}, ?POLL}
    end;
handle_info(Info, _State) ->
    exit({not_implemented, Info}).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

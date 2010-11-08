%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is VMware, Inc.
%%   Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.
-module(rabbit_mgmt_db).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(gen_server).

-export([start_link/0]).

-export([get_queues/1, get_queue/1, get_exchanges/1, get_exchange/1,
         get_connections/0, get_connection/1,
         get_overview/0, get_channels/0, get_channel/1]).

%% TODO can these not be exported any more?
-export([pget/2, add/2, rates/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {tables}).
-define(FINE_STATS_TYPES, [channel_queue_stats, channel_exchange_stats,
                           channel_queue_exchange_stats]).
-define(TABLES, [queue_stats, connection_stats, channel_stats] ++
            ?FINE_STATS_TYPES).

-define(DELIVER_GET, [deliver, deliver_no_ack, get, get_no_ack]).
-define(FINE_STATS, [publish, ack, deliver_get] ++ ?DELIVER_GET).

-define(
   FINE_STATS_CHANNEL_LIST,
   [{channel_queue_stats,   [channel], message_stats, channel},
    {channel_exchange_stats,[channel], message_stats, channel}]).

-define(
   FINE_STATS_CHANNEL_DETAIL,
   [{channel_queue_stats,    [channel],           message_stats, channel},
    {channel_exchange_stats, [channel],           message_stats, channel},
    {channel_exchange_stats, [channel, exchange], publishes,     channel},
    {channel_queue_stats,    [channel, queue],    deliveries,    channel}]).

-define(
   FINE_STATS_QUEUE_LIST,
   [{channel_queue_stats,          [queue], message_stats, queue},
    {channel_queue_exchange_stats, [queue], message_stats, queue}]).

-define(
   FINE_STATS_QUEUE_DETAIL,
   [{channel_queue_stats,          [queue],           message_stats, queue},
    {channel_queue_exchange_stats, [queue],           message_stats, queue},
    {channel_queue_stats,          [queue, channel],  deliveries, queue},
    {channel_queue_exchange_stats, [queue, exchange], incoming, queue}]).

-define(
   FINE_STATS_EXCHANGE_LIST,
   [{channel_exchange_stats,       [exchange], message_stats_in,  exchange},
    {channel_queue_exchange_stats, [exchange], message_stats_out, exchange}]).

-define(
   FINE_STATS_EXCHANGE_DETAIL,
   [{channel_exchange_stats,       [exchange], message_stats_in,   exchange},
    {channel_queue_exchange_stats, [exchange], message_stats_out,  exchange},
    {channel_exchange_stats,       [exchange, channel],  incoming, exchange},
    {channel_queue_exchange_stats, [exchange, queue],    outgoing, exchange}]).

-define(FINE_STATS_NONE, []).

%%----------------------------------------------------------------------------

start_link() ->
    case gen_server:start_link({global, ?MODULE}, ?MODULE, [], []) of
        {error, {already_started, Pid}} ->
            rabbit_log:info(
              "Statistics database already registered at ~p.~n", [Pid]),
            ignore;
        Else ->
            rabbit_log:info(
              "Statistics database started.~n", []),
            Else
    end.

get_queues(Qs) ->
    safe_call({get_queues, Qs, list}, Qs).

get_queue(Q) ->
    safe_call({get_queues, [Q], detail}, [Q]).

get_exchanges(Xs) ->
    safe_call({get_exchanges, Xs, list}, Xs).

get_exchange(X) ->
    safe_call({get_exchanges, [X], detail}, [X]).

get_connections() ->
    safe_call(get_connections).

get_connection(Name) ->
    safe_call({get_connection, Name}).

get_channels() ->
    safe_call(get_channels).

get_channel(Name) ->
    safe_call({get_channel, Name}).

get_overview() ->
    safe_call(get_overview).

safe_call(Term) ->
    safe_call(Term, []).

safe_call(Term, Item) ->
    try
        gen_server:call({global, ?MODULE}, Term, infinity)
    catch exit:{noproc, _} ->
            Item
    end.

%%----------------------------------------------------------------------------

pget(Key, List) ->
    pget(Key, List, unknown).

pget(Key, List, Default) ->
    proplists:get_value(Key, List, Default).

pset(Key, Value, List) ->
    [{Key, Value} | proplists:delete(Key, List)].

id(Pid) when is_pid(Pid) -> rabbit_mgmt_format:pid(Pid);
id(List) -> rabbit_mgmt_format:pid(pget(pid, List)).

add(unknown, _) -> unknown;
add(_, unknown) -> unknown;
add(A, B)       -> A + B.

lookup_element(Table, Key) ->
    lookup_element(Table, Key, 2).

lookup_element(Table, Key, Pos) ->
    try ets:lookup_element(Table, Key, Pos)
    catch error:badarg -> []
    end.

result_or_error([]) -> error;
result_or_error(S)  -> S.

rates(Stats, Timestamp, OldStats, OldTimestamp, Keys) ->
    Stats ++ [R || Key <- Keys,
                   R   <- [rate(Stats, Timestamp, OldStats, OldTimestamp, Key)],
                   R =/= unknown].

rate(Stats, Timestamp, OldStats, OldTimestamp, Key) ->
    case OldTimestamp == [] orelse not proplists:is_defined(Key, OldStats) of
        true  -> unknown;
        false -> Diff = pget(Key, Stats) - pget(Key, OldStats),
                 Name = details_key(Key),
                 Rate = Diff / (timer:now_diff(Timestamp, OldTimestamp) /
                                    1000000),
                 {Name, [{rate, Rate},
                         {last_event, rabbit_mgmt_format:timestamp(Timestamp)}]}
    end.

%% List = [{ [{channel, Pid}, ...], [{deliver, 123}, ...] } ...]
group_sum([], List) ->
    lists:foldl(fun ({_, Item1}, Item0) ->
                        gs_update(Item0, Item1)
                end, [], List);

group_sum([Group | Groups], List) ->
    D = lists:foldl(
          fun (Next = {Ids, _}, Dict) ->
                  Id = {Group, pget(Group, Ids)},
                  dict:update(Id, fun(Cur) -> [Next | Cur] end, [Next], Dict)
          end, dict:new(), List),
    dict:map(fun(_, SubList) ->
                     group_sum(Groups, SubList)
             end, D).

gs_update(Item0, Item1) ->
    Keys = lists:usort([K || {K, _} <- Item0 ++ Item1]),
    [{Key, gs_update_add(Key, pget(Key, Item0), pget(Key, Item1))} ||
        Key <- Keys].

gs_update_add(Key, Item0, Item1) ->
    case is_details(Key) of
        true  ->
            I0 = if_unknown(Item0, []),
            I1 = if_unknown(Item1, []),
            [{rate,       pget(rate, I0, 0) + pget(rate, I1, 0)},
             {last_event, erlang:max(pget(last_event, I0, 0),
                                     pget(last_event, I1, 0))}];
        false ->
            I0 = if_unknown(Item0, 0),
            I1 = if_unknown(Item1, 0),
            I0 + I1
    end.

if_unknown(unknown, Def) -> Def;
if_unknown(Val,    _Def) -> Val.

%%----------------------------------------------------------------------------

augment(Items, Funs, Tables) ->
    Augmented = [augment(K, Items, Fun, Tables) || {K, Fun} <- Funs] ++ Items,
    [{K, V} || {K, V} <- Augmented, V =/= unknown].

augment(K, Items, Fun, Tables) ->
    Key = details_key(K),
    case pget(K, Items) of
        none    -> {Key, unknown};
        unknown -> {Key, unknown};
        Id      -> {Key, Fun(Id, Tables)}
    end.

augment_channel_pid(Pid, Tables) ->
    Ch = lookup_element(
           orddict:fetch(channel_stats, Tables),
           {Pid, create}),
    Conn = lookup_element(
             orddict:fetch(connection_stats, Tables),
             {pget(connection, Ch), create}),
    [{number,          pget(number, Ch)},
     {name,            pget(name, Ch)},
     {connection_name, pget(name, Conn)},
     {peer_address,    pget(peer_address, Conn)},
     {peer_port,       pget(peer_port, Conn)}].

augment_connection_pid(Pid, Tables) ->
    Conn = lookup_element(orddict:fetch(connection_stats, Tables),
                          {Pid, create}),
    [{peer_address, pget(peer_address, Conn)},
     {peer_port,    pget(peer_port,    Conn)},
     {name,         pget(name,         Conn)}].

augment_queue_pid(Pid, _Tables) ->
    %% TODO This should be in rabbit_amqqueue?
    [Q] = mnesia:dirty_match_object(
            rabbit_queue,
            #amqqueue{pid = rabbit_misc:string_to_pid(Pid), _ = '_'}),
    Name = Q#amqqueue.name,
    [{name,  Name#resource.name},
     {vhost, Name#resource.virtual_host}].

augment_msg_stats(Stats, Tables) ->
    [augment_msg_stats_items(Props, Tables) || Props <- Stats].

augment_msg_stats_items(Props, Tables) ->
    augment(Props, [{connection, fun augment_connection_pid/2},
                    {channel,    fun augment_channel_pid/2},
                    {queue,      fun augment_queue_pid/2}], Tables).

%%----------------------------------------------------------------------------

init([]) ->
    {ok, #state{tables = orddict:from_list(
                           [{Key, ets:new(anon, [private])} ||
                               Key <- ?TABLES])}}.

handle_call({get_queues, Qs0, Mode}, _From, State = #state{tables = Tables}) ->
    FineStats = case Mode of
                    list   -> ?FINE_STATS_QUEUE_LIST;
                    detail -> ?FINE_STATS_QUEUE_DETAIL
                end,
    Qs1 = merge_stats(Qs0, FineStats, queue_stats, Tables),
    Qs2 = [[{messages, add(pget(messages_ready, Q),
                           pget(messages_unacknowledged, Q))} | Q] || Q <- Qs1],
    Qs3 = [augment(Q, [{owner_pid, fun augment_connection_pid/2}], Tables) ||
              Q <- Qs2],
    {reply, Qs3, State};

handle_call({get_exchanges, Xs, Mode}, _From,
            State = #state{tables = Tables}) ->
    FineStats = case Mode of
                    list   -> ?FINE_STATS_EXCHANGE_LIST;
                    detail -> ?FINE_STATS_EXCHANGE_DETAIL
                end,
    {reply, merge_stats(Xs, FineStats, none, Tables),
     State};

handle_call(get_connections, _From, State = #state{tables = Tables}) ->
    Conns = created_events(connection_stats, Tables),
    {reply, merge_stats(Conns, ?FINE_STATS_NONE, connection_stats, Tables),
     State};

handle_call({get_connection, Name}, _From, State = #state{tables = Tables}) ->
    Conns = created_event(Name, connection_stats, Tables),
    [Res] = merge_stats(Conns, ?FINE_STATS_NONE, connection_stats, Tables),
    {reply, result_or_error(Res), State};

handle_call(get_channels, _From, State = #state{tables = Tables}) ->
    Chs = created_events(channel_stats, Tables),
    Res = merge_stats(Chs, ?FINE_STATS_CHANNEL_LIST, channel_stats, Tables),
    {reply, Res, State};

handle_call({get_channel, Name}, _From, State = #state{tables = Tables}) ->
    Chs = created_event(Name, channel_stats, Tables),
    [Res] = merge_stats(Chs, ?FINE_STATS_CHANNEL_DETAIL, channel_stats, Tables),
    {reply, result_or_error(Res), State};

handle_call(get_overview, _From, State = #state{tables = Tables}) ->
    FineQ = get_fine_stats(channel_queue_stats, [], Tables),
    FineX = get_fine_stats(channel_exchange_stats, [], Tables),
    {reply, [{message_stats, FineX ++ FineQ}], State};

handle_call(_Request, _From, State) ->
    {reply, not_understood, State}.

handle_cast({event, Event}, State) ->
    handle_event(Event, State),
    {noreply, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

handle_event(#event{type = queue_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(queue_stats, Stats, Timestamp,
                 [{fun rabbit_mgmt_format:properties/1,[backing_queue_status]}],
                 [], State);

handle_event(Event = #event{type = queue_deleted}, State) ->
    handle_deleted(queue_stats, Event, State);

handle_event(#event{type = connection_created, props = Stats}, State) ->
    Name = rabbit_mgmt_format:print(
             "~s:~w",
             [rabbit_mgmt_format:ip(pget(peer_address, Stats)),
              pget(peer_port, Stats)]),
    handle_created(
      connection_stats, [{name, Name} | Stats],
      [{fun rabbit_mgmt_format:ip/1,           [address, peer_address]},
       {fun rabbit_mgmt_format:node_and_pid/1, [pid]},
       {fun rabbit_mgmt_format:protocol/1,     [protocol]},
       {fun rabbit_mgmt_format:amqp_table/1,   [client_properties]}], State);

handle_event(#event{type = connection_stats, props = Stats,
                    timestamp = Timestamp},
             State) ->
    handle_stats(connection_stats, Stats, Timestamp, [], [recv_oct, send_oct],
                 State);

handle_event(Event = #event{type = connection_closed}, State) ->
    handle_deleted(connection_stats, Event, State);

handle_event(#event{type = channel_created, props = Stats},
             State = #state{tables = Tables}) ->
    ConnTable = orddict:fetch(connection_stats, Tables),
    Conn = lookup_element(ConnTable, {id(pget(connection, Stats)), create}),
    Name = rabbit_mgmt_format:print("~s:~w:~w",
                                    [pget(peer_address, Conn),
                                     pget(peer_port,    Conn),
                                     pget(number,       Stats)]),
    handle_created(channel_stats, [{name, Name}|Stats],
                   [{fun rabbit_mgmt_format:node_and_pid/1, [pid]},
                    {fun rabbit_mgmt_format:pid/1,          [connection]}],
                   State);

handle_event(#event{type = channel_stats, props = Stats, timestamp = Timestamp},
             State) ->
    handle_stats(channel_stats, Stats, Timestamp, [], [], State),
    [handle_fine_stats(Type, Stats, Timestamp, State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(Event = #event{type = channel_closed,
                            props = [{pid, Pid}]}, State) ->
    handle_deleted(channel_stats, Event, State),
    [delete_fine_stats(Type, id(Pid), State) ||
        Type <- ?FINE_STATS_TYPES],
    {ok, State};

handle_event(_Event, State) ->
    {ok, State}.

%%----------------------------------------------------------------------------

handle_created(TName, Stats, Funs, State = #state{tables = Tables}) ->
    Formatted = rabbit_mgmt_format:format(Stats, Funs),
    ets:insert(orddict:fetch(TName, Tables), {{id(Stats), create},
                                              Formatted,
                                              pget(name, Stats)}),
    {ok, State}.

handle_stats(TName, Stats0, Timestamp, Funs,
             RatesKeys, State = #state{tables = Tables}) ->
    Stats = lists:foldl(
              fun (K, StatsAcc) -> proplists:delete(K, StatsAcc) end,
              Stats0, ?FINE_STATS_TYPES),
    Table = orddict:fetch(TName, Tables),
    Id = {id(Stats), stats},
    OldStats = lookup_element(Table, Id),
    OldTimestamp = lookup_element(Table, Id, 3),
    Stats1 = rates(Stats, Timestamp, OldStats, OldTimestamp, RatesKeys),
    Stats2 = proplists:delete(pid, rabbit_mgmt_format:format(Stats1, Funs)),
    ets:insert(Table, {Id, Stats2, Timestamp}),
    {ok, State}.

handle_deleted(TName, #event{props = [{pid, Pid}]},
               State = #state{tables = Tables}) ->
    Table = orddict:fetch(TName, Tables),
    ets:delete(Table, {id(Pid), create}),
    ets:delete(Table, {id(Pid), stats}),
    {ok, State}.

handle_fine_stats(Type, Props, Timestamp, State = #state{tables = Tables}) ->
    case pget(Type, Props) of
        unknown ->
            ok;
        AllFineStats ->
            ChPid = id(Props),
            Table = orddict:fetch(Type, Tables),
            IdsStatsTS =
                [{Ids,
                  Stats,
                  lookup_element(Table, fine_stats_key(ChPid, Ids)),
                  lookup_element(Table, fine_stats_key(ChPid, Ids), 3)} ||
                    {Ids, Stats} <- AllFineStats],
            delete_fine_stats(Type, ChPid, State),
            [handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                              OldStats, OldTimestamp, Table) ||
                {Ids, Stats, OldStats, OldTimestamp} <- IdsStatsTS]
    end.


handle_fine_stat(ChPid, Ids, Stats, Timestamp,
                 OldStats, OldTimestamp,
                 Table) ->
    Id = fine_stats_key(ChPid, Ids),
    Total = lists:sum([V || {K, V} <- Stats, lists:member(K, ?DELIVER_GET)]),
    Stats1 = case Total of
                 0 -> Stats;
                 _ -> [{deliver_get, Total}|Stats]
             end,
    Res = rates(Stats1, Timestamp, OldStats, OldTimestamp, ?FINE_STATS),
    ets:insert(Table, {Id, Res, Timestamp}).

delete_fine_stats(Type, ChPid, #state{tables = Tables}) ->
    Table = orddict:fetch(Type, Tables),
    ets:match_delete(Table, {{ChPid, '_'}, '_', '_'}),
    ets:match_delete(Table, {{ChPid, '_', '_'}, '_', '_'}).

fine_stats_key(ChPid, {QPid, X})              -> {ChPid, id(QPid), X};
fine_stats_key(ChPid, QPid) when is_pid(QPid) -> {ChPid, id(QPid)};
fine_stats_key(ChPid, X)                      -> {ChPid, X}.

created_event(Name, Type, Tables) ->
    Table = orddict:fetch(Type, Tables),
    Id = case ets:match(Table, {{'$1', create}, '_', Name}) of
             []    -> none;
             [[I]] -> I
         end,
    [lookup_element(Table, {Id, create})].

created_events(Type, Tables) ->
    [Facts || {{_, create}, Facts, _Name}
                  <- ets:tab2list(orddict:fetch(Type, Tables))].

get_fine_stats(Type, GroupBy, Tables) ->
    Table = orddict:fetch(Type, Tables),
    All = [{format_id(Id), zero_old_rates(Stats)} ||
              {Id, Stats, _Timestamp} <- ets:tab2list(Table)],
    group_sum(GroupBy, All).

format_id({ChPid, #resource{name=XName, virtual_host=XVhost}}) ->
    [{channel, ChPid}, {exchange, [{name, XName}, {vhost, XVhost}]}];
format_id({ChPid, QPid}) ->
    [{channel, ChPid}, {queue, QPid}];
format_id({ChPid, QPid, #resource{name=XName, virtual_host=XVhost}}) ->
    [{channel, ChPid}, {queue, QPid},
     {exchange, [{name, XName}, {vhost, XVhost}]}].

merge_stats(Objs, FineSpecs, Type, Tables) ->
    WithCoarse =
        case Type of
            none ->
                Objs;
            _ ->
                Table = orddict:fetch(Type, Tables),
                [Obj ++ zero_old_rates(
                          lookup_element(Table, {pget(pid, Obj), stats}))
                 || Obj <- Objs]
        end,
    FineStats = [{AttachName, AttachBy,
                  get_fine_stats(FineStatsType, GroupBy, Tables)}
                 || {FineStatsType, GroupBy, AttachName, AttachBy}
                        <- FineSpecs],
    augment_msg_stats(merge_fine_stats(WithCoarse, FineStats, Tables), Tables).

merge_fine_stats(Stats, [], _Tables) ->
    Stats;
merge_fine_stats(Stats, [{AttachName, AttachBy, Dict} | Rest], Tables) ->
    merge_fine_stats([merge_fine_stats0(AttachName, AttachBy,
                                        Props, Dict, Tables)
                      || Props <- Stats], Rest, Tables).

merge_fine_stats0(AttachName, AttachBy, Props, Dict, Tables) ->
    Id = case AttachBy of
             exchange ->
                 [{name, pget(name, Props)}, {vhost, pget(vhost, Props)}];
             _ ->
                 pget(pid, Props)
         end,
    case dict:find({AttachBy, Id}, Dict) of
        {ok, Stats} -> [{AttachName, pget(AttachName, Props, []) ++
                             augment_fine_stats(Stats, Tables)} |
                        proplists:delete(AttachName, Props)];
        error       -> Props
    end.

augment_fine_stats(Dict, Tables) when element(1, Dict) == dict ->
    [[{stats, augment_fine_stats(Stats, Tables)} |
      augment_msg_stats_items([IdTuple], Tables)]
     || {IdTuple, Stats} <- dict:to_list(Dict)];
augment_fine_stats(Stats, _Tables) ->
    Stats.

zero_old_rates(Stats) -> [maybe_zero_rate(S) || S <- Stats].

maybe_zero_rate({Key, Val}) ->
    case is_details(Key) of
        true  -> Age = rabbit_misc:now_ms() - pget(last_event, Val),
                 {Key, case Age > ?STATS_INTERVAL * 1.5 of
                           true  -> pset(rate, 0, Val);
                           false -> Val
                       end};
        false -> {Key, Val}
    end.

is_details(Key) ->
    lists:suffix("_details", atom_to_list(Key)).

details_key(Key) ->
    list_to_atom(atom_to_list(Key) ++ "_details").

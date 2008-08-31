%% @author Masahito Ikuta <cooldaemon@gmail.com> [http://d.hatena.ne.jp/cooldaemon/]
%% @copyright Masahito Ikuta 2008
%% @doc This module is data store manager.
%%
%%  This module is facade for k-buckets and data store.

%% Copyright 2008 Masahito Ikuta
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(ermlia_facade).
-behaviour(gen_server).

-export([start_link/0, stop/0]).
-export([put/2, put/3, get/1]).
-export([join/2]).
-export([ping/3, add_node/3, lookup_nodes/1, find_value/1]).
-export([
  init/1,
  handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3
]).

-define(FIND_VALUE_MAX_COUNT, 45).
-define(FIND_VALUE_PARALLEL_COUNT, 3).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
  gen_server:call(?MODULE, stop).

put(Key, Value) ->
  put(Key, Value, 0).

put(Key, Value, TTL) ->
  KeyID = key_to_id(Key),
  ermlia_data_store:put(KeyID, Key, Value, TTL),
  publish(lookup_nodes(KeyID), Key, Value, TTL).

publish([], _Key, _Value, _TTL) ->
  ok;
publish([{_ID, IP, Port, _RTT} | Nodes], Key, Value, TTL) ->
  ermlia_node_pipe:put(IP, Port, id(), Key, Value, TTL),
  publish(Nodes, Key, Value, TTL).

get(Key) ->
  get(find_value(Key), Key).

get({value, Value}, _Key) ->
  Value;
get(Result, Key) ->
  KeyID = key_to_id(Key),
  get(Key, KeyID, [], [], Result).

get(_Key, _KeyID, _Nodes, _TermNodes, {value, Value}) ->
  Value;
get(_Key, _KeyID, _Nodes, TermNodes, _Result)
  when ?FIND_VALUE_MAX_COUNT < length(TermNodes)
->
  undefined;
get(Key, KeyID, Nodes, TermNodes, {nodes, AddNodes}) ->
  get(
    Key, KeyID, TermNodes, 
    merge_nodes(KeyID, Nodes, AddNodes, TermNodes)
  ).

get(_Key, _KeyID, _TermNodes, Nodes) when length(Nodes) =:= 0 ->
  undefined;
get(Key, KeyID, TermNodes, Nodes) ->
  {NewTermNodes, NewNodes} = list_utils:split(
    ?FIND_VALUE_PARALLEL_COUNT,
    Nodes
  ),
  MyID = id(),
  get(
    Key, KeyID,
    NewNodes, NewTermNodes ++ TermNodes,
    concat_find_value_results(
      list_utils:pmap(
        fun ({_ID, IP, Port, _RTT}) ->
          ermlia_node_pipe:find_value(IP, Port, MyID, Key)
        end,
        NewTermNodes
      )
    )
  ).

merge_nodes(KeyID, Nodes, AddNodes, TermNodes) ->
  lists:filter(
    fun ({ID, _IP, _Port, _RTT}) ->
      CheckID = ID,
      lists:any(
        fun ({ID, _IPT, _PortT, _RTTT}) ->
          if
            CheckID =:= ID -> false;
            true           -> true
          end
        end,
        TermNodes
      )
    end,
    lists:sort(
      fun ({IDA, _IPA, _PortA, _RTTA}, {IDB, _IPB, _PortB, _RTTB}) ->
        [IA, IB] = lists:map(fun (ID) -> i(ID, KeyID) end, [IDA, IDB]),
        if
          IA < IB -> true;
          true    -> false
        end
      end,
      lists:usort(
        fun ({IDA, _IPA, _PortA, _RTTA}, {IDB, _IPB, _PortB, _RTTB}) ->
          if
            IDA =< IDB -> true;
            true       -> false
          end
        end,
        Nodes ++ AddNodes
      )
    )
  ).

concat_find_value_results(Results) ->
  concat_find_value_results(Results, []).
  
concat_find_value_results([], Nodes) ->
  {nodes, Nodes};
concat_find_value_results([{value, Value} | _Results], _Nodes) ->
  {value, Value};
concat_find_value_results([{nodes, NewNodes} | Results], Nodes) ->
  concat_find_value_results(Results, Nodes ++ NewNodes);
concat_find_value_results([_Other | Results], Nodes) ->
  concat_find_value_results(Results, Nodes).

join(IP, Port) ->
  Nodes = ermlia_node_pipe:find_node(IP, Port, id(), id()),
  add_nodes(Nodes),
  find_nodes(Nodes).

add_nodes(fail) -> fail;
add_nodes([])   -> ok;
add_nodes([{ID, IP, Port, _RTT} | Nodes]) ->
  add_node(ID, IP, Port),
  add_nodes(Nodes).

find_nodes(fail) -> fail;
find_nodes(Nodes) ->
  MyID = id(),
  list_utils:pmap(
    fun ({_ID, IP, Port, _RTT}) ->
      add_nodes(ermlia_node_pipe:find_node(IP, Port, MyID, MyID))
    end,
    Nodes
  ).

ping(IP, Port, Callback) ->
  ermlia_node_pipe:ping(IP, Port, id(), Callback).

add_node(ID, IP, Port) ->
  ermlia_kbukets:add(i(ID), ID, IP, Port).

lookup_nodes(ID) ->
  ermlia_kbukets:lookup(i(ID)).

find_value(Key) ->
  find_value(ermlia_data_store:get(key_to_i(Key), Key), Key).

find_value(undefined, Key) ->
  {nodes, lookup_nodes(key_to_id(Key))};
find_value(Value, _Key) ->
  {value, Value}.

id() ->
  id_cache(erlang:get(ermlia_facade_id)).

id_cache(undefined) ->
  ID = gen_server:call(?MODULE, id),
  erlang:put(ermlia_facade_id, ID),
  ID;
id_cache(ID) ->
  ID.

key_to_i(Key) ->
  i(key_to_id(Key)).

i(TargetID) ->
  i(id(), TargetID).

i(ID, TargetID) ->
  i(ID bxor TargetID, 1 bsl 159, 159).

i(_Digit, _Mask, -1) ->
  -1;
i(Digit, Mask, Interval) when Digit band Mask > 0 ->
  Interval;
i(Digit, Mask, Interval) ->
  i(Digit, Mask bsr 1, Interval - 1).

key_to_id(Key) ->
  <<ID:160>> = crypto:sha(term_to_binary(Key)),
  ID.

init(_Args) ->
  process_flag(trap_exit, true),
  ok = crypto:start(),
  <<ID:160>> = crypto:rand_bytes(20),
  {ok, {ID}}.

handle_call(id, _From, {ID}=State) ->
  {reply, ID, State};

handle_call(stop, _From, State) ->
  {stop, normal, stopped, State};

handle_call(_Message, _From, State) ->
  {reply, ok, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.


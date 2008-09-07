%% @author Masahito Ikuta <cooldaemon@gmail.com> [http://d.hatena.ne.jp/cooldaemon/]
%% @copyright Masahito Ikuta 2008
%% @doc This module is pipe that connects between nodes. 

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

-module(ermlia_node_pipe).
-behaviour(udp_server).

-include("udp_server.hrl").

-export([start_link/1, stop/0]).
-export([ping/3, find_node/4, find_value/4, put/6]).
-export([handle_call/4, handle_info/2]).

-define(PING_TIMEOUT, 3000000).
-define(FIND_NODE_TIMEOUT, 3000000).
-define(FIND_VALUE_TIMEOUT, 3000000).

start_link(Port) ->
  udp_server:receiver_start_link(
    {local, ?MODULE},
    ?MODULE,
    #udp_server_option{option=[binary, {active, true}], port=Port}
  ).

stop() ->
  case whereis(?MODULE) of
    Pid when is_pid(Pid) ->
      exit(Pid, normal),
      ok;
    _Other ->
      not_started
  end.

ping(IP, Port, ID) ->
  ermlia_node_pipe ! {IP, Port, {ping, ID, self()}},
  receive
    pong -> ok
  after ?PING_TIMEOUT ->
    fail
  end.

find_node(IP, Port, ID, TargetID) ->
  find(node, IP, Port, ID, TargetID, ?FIND_NODE_TIMEOUT).

find_value(IP, Port, ID, Key) ->
  find(value, IP, Port, ID, Key, ?FIND_VALUE_TIMEOUT).

find(Method, IP, Port, ID, Target, Timeout) ->
  Message = list_to_atom("find_" ++ atom_to_list(Method)),
  AckMessage = list_to_atom("ack_" ++ atom_to_list(Message)),
  ermlia_node_pipe ! {IP, Port, {Message, ID, Target, self()}},
  receive
    {AckMessage, Result} -> Result
  after Timeout ->
    fail
  end.

put(IP, Port, ID, Key, Value, TTL) ->
  ermlia_node_pipe ! {IP, Port, {put, ID, Key, Value, TTL}}.

handle_call(Socket, IP, Port, Packet) ->
  dispatch(Socket, IP, Port, binary_to_term(Packet)).

handle_info(Socket, {IP, Port, Message}) ->
  gen_udp:send(Socket, IP, Port, term_to_binary(Message));

handle_info(_Socket, _Message) -> ok.

dispatch(Socket, IP, Port, {ping, ID, Pid}) ->
  callback(Socket, IP, Port, ID, {pong, Pid});

dispatch(_Socket, _IP, _Port, {pong, Pid}) ->
  Pid ! pong;

dispatch(Socket, IP, Port, {find_node, ID, TargetID, PID}) ->
  callback(Socket, IP, Port, ID, {
    ack_find_node, ermlia_facade:lookup_nodes(TargetID), PID
  });

dispatch(_Socket, _IP, _Port, {ack_find_node, Nodes, PID}) ->
  PID ! {ack_find_node, Nodes};

dispatch(Socket, IP, Port, {find_value, ID, Key, PID}) ->
  callback(Socket, IP, Port, ID, {
    ack_find_value, ermlia_facade:find_value(Key), PID
  });

dispatch(_Socket, IP, Port, {put, ID, Key, Value, TTL}) ->
  ermlia_facade:add_node(ID, IP, Port),
  ermlia_facade:put(Key, Value, TTL);

dispatch(_Socket, _IP, _Port, _Message) -> ok.

callback(Socket, IP, Port, ID, Message) ->
  ermlia_facade:add_node(ID, IP, Port),
  gen_udp:send(Socket, IP, Port, term_to_binary(Message)).


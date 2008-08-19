%% @author Masahito Ikuta <cooldaemon@gmail.com> [http://d.hatena.ne.jp/cooldaemon/]
%% @copyright Masahito Ikuta 2008
%% @doc This module is supervisor for the ermlia.

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

-module(ermlia_sup).
-behaviour(supervisor).

-include("udp_server.hrl"). 

-export([start_link/1, stop/0]).
-export([init/1]).

start_link(Port) -> sup_utils:start_link(?MODULE, [Port]).
stop() -> sup_utils:stop(?MODULE).

init([Port]) ->
  sup_utils:spec([
    {sup, ermlia_kbukets_sup},
    {worker, ermlia_data_store},
    {worker, udp_server, receiver_start_link, [
      {local, ermlia_node_pipe},
      ermlia_node_pipe,
      #udp_server_option{option=[binary, {active, true}], port=Port}
    ]},
    {worker, mochiweb_http, start, [[
      {port, Port},
      {name, {local, ermlia_web}},
      {loop, {ermlia_web, dispatch}}
    ]]}
  ]).


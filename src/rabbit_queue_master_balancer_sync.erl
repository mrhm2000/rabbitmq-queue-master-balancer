%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Queue Master Balancer.
%%
%% The Developer of this component is Erlang Solutions, Ltd.
%% Copyright (c) 2017-2018 Erlang Solutions, Ltd.  All rights reserved.
%%

-module(rabbit_queue_master_balancer_sync).

-export([sync_mirrors/1, verify_sync/3, verify_sync/4]).
-export([verify_master/2, verify_master/3, verify_master/4]).

-include("rabbit_queue_master_balancer.hrl").

% ---------------------------------------------------------------
-spec sync_mirrors(rabbit_types:amqqueue() | pid()) -> 'ok'.
-spec verify_sync(binary(), binary(), list())               -> 'ok'.
-spec verify_sync(binary(), binary(), list(), integer())    -> 'ok'.
% ----------------------------------------------------------------

-define(SLEEP,  (?DELAY(?DEFAULT_QLOOKUP_DELAY))).

sync_mirrors(Q) ->
  _Any = rabbit_amqqueue:sync_mirrors(Q),
  ok.

verify_sync(VHost, QN, SPids) ->
  verify_sync(VHost, QN, SPids, ?DEFAULT_SYNC_DELAY_TIMEOUT).

verify_sync(VHost, QN, SPids, Timeout) ->
  SynchPPid = self(),
  SynchRef  = make_ref(),
  Syncher   = spawn(fun() ->
                        verify_sync(VHost, SynchPPid, SynchRef, QN, SPids)
                    end),
  receive
    {Syncher, _SyncherRef, done} -> ok;
    {'EXIT',  _Syncher, Reason}  -> throw({sync_termination, Reason})
  after Timeout ->
    exit(Syncher, {timeout, ?MODULE})
  end.

verify_sync(VHost, SynchPPid, SynchRef, QN, SPids) ->
  SSPs = length(synchronised_slave_pids(VHost, QN)),
  if SSPs =:= length(SPids) -> SynchPPid ! {self(), SynchRef, done};
     true -> verify_sync(VHost, SynchPPid, SynchRef, QN, SPids)
  end.

synchronised_slave_pids(VHost, Queue) ->
    ?SLEEP,
    {ok, Q} = rabbit_amqqueue:lookup(rabbit_misc:r(VHost, queue, Queue)),
    SSP = synchronised_slave_pids,
    [{SSP, Pids}] = rabbit_amqqueue:info(Q, [SSP]),
    case Pids of
        '' -> [];
        _  -> Pids
    end.

verify_master(VHost, QN) ->
    verify_master(VHost, QN, ?DEFAULT_MASTER_VERIFICATION_TIMEOUT).
verify_master(VHost, QN, Timeout) ->
  VerifierPPid = self(),
  VerifierRef  = make_ref(),
  Verifier     = spawn(fun() ->
                        verify_master(VHost, VerifierPPid, VerifierRef, QN)
                    end),
  receive
    {Verifier, _VerifierRef, alive} -> ok;
    {'EXIT', _VerifierRef, Reason}  -> throw({verify_master_termination, Reason})
  after Timeout ->
    exit(Verifier, {verify_master_timeout, ?MODULE})
  end.

verify_master(VHost, VerifierPPid, VerifierRef, QN) ->
  IsQMasterAlive = is_queue_master_alive(VHost, QN),
  if IsQMasterAlive -> VerifierPPid ! {self(), VerifierRef, alive};
     true -> verify_master(VHost, VerifierPPid, VerifierRef, QN)
  end.

is_queue_master_alive(VHost, Queue) ->
    ?SLEEP,
    {ok, Q} = rabbit_amqqueue:lookup(rabbit_misc:r(VHost, queue, Queue)),
    {Pid, State} = get_pid_and_state(Q),
    is_pid_alive(Pid) andalso (State =:= live).

%% Queue process can now be exisisting on remote node after migration operations
is_pid_alive(Pid) when is_pid(Pid) ->
    LocalNode = node(),
    case node(Pid) of
        LocalNode -> is_process_alive(Pid);
        RemoteNode ->
            rpc:call(RemoteNode, erlang, is_process_alive, [Pid])
    end.

get_pid_and_state(AMQQueue) ->
  case AMQQueue of
      {amqqueue, {resource, _, queue, _},_,_,_,_,Pid,_,_,_,_,_,_,State} ->
         {Pid, State};
      {amqqueue, {resource, _, queue, _},_,_,_,_,Pid,_,_,_,_,_,_,State,_} ->
         {Pid, State};
      {amqqueue,{resource, _, queue, _},_,_,_,_,Pid,_,_,_,_,_,_,_,State,_,_,_,_} ->
         {Pid, State};
      Other -> error({unsupported_version, Other})
  end.

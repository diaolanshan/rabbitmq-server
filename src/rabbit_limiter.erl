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
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_limiter).

-behaviour(gen_server).

-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([start_link/1, shutdown/1]).
-export([limit/2, can_send/4, ack/2, register/2, unregister/2]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(maybe_pid() :: pid() | 'undefined').

-spec(start_link/1 :: (pid()) -> pid()).
-spec(shutdown/1 :: (maybe_pid()) -> 'ok').
-spec(limit/2 :: (maybe_pid(), non_neg_integer()) -> 'ok').
-spec(can_send/4 :: (maybe_pid(), pid(), boolean(), non_neg_integer()) ->
             boolean()).
-spec(ack/2 :: (maybe_pid(), non_neg_integer()) -> 'ok').
-spec(register/2 :: (maybe_pid(), pid()) -> 'ok').
-spec(unregister/2 :: (maybe_pid(), pid()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

-record(lim, {prefetch_count = 0,
              ch_pid,
              queues = dict:new(), % QPid -> {MonitorRef, Notify, Length}
              volume = 0}).
%% 'Notify' is a boolean that indicates whether a queue should be
%% notified of a change in the limit or volume that may allow it to
%% deliver more messages via the limiter's channel.

%%----------------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------------

start_link(ChPid) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [ChPid], []),
    Pid.

shutdown(undefined) ->
    ok;
shutdown(LimiterPid) ->
    unlink(LimiterPid),
    gen_server2:cast(LimiterPid, shutdown).

limit(undefined, 0) ->
    ok;
limit(LimiterPid, PrefetchCount) ->
    gen_server2:cast(LimiterPid, {limit, PrefetchCount}).

%% Ask the limiter whether the queue can deliver a message without
%% breaching a limit
can_send(undefined, _QPid, _AckRequired, _Length) ->
    true;
can_send(LimiterPid, QPid, AckRequired, Length) ->
    rabbit_misc:with_exit_handler(
      fun () -> true end,
      fun () -> gen_server2:call(LimiterPid, {can_send, QPid, AckRequired,
                                              Length}, infinity) end).

%% Let the limiter know that the channel has received some acks from a
%% consumer
ack(undefined, _Count) -> ok;
ack(LimiterPid, Count) -> gen_server2:cast(LimiterPid, {ack, Count}).

register(undefined, _QPid) -> ok;
register(LimiterPid, QPid) -> gen_server2:cast(LimiterPid, {register, QPid}).

unregister(undefined, _QPid) -> ok;
unregister(LimiterPid, QPid) -> gen_server2:cast(LimiterPid, {unregister, QPid}).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([ChPid]) ->
    {ok, #lim{ch_pid = ChPid} }.

handle_call({can_send, QPid, AckRequired, Length}, _From,
            State = #lim{volume = Volume}) ->
    case limit_reached(State) of
        true ->
            {reply, false, limit_queue(QPid, Length, State)};
        false ->
            {reply, true,
             update_length(QPid, Length,
                           State#lim{volume = if AckRequired -> Volume + 1;
                                                 true        -> Volume
                                              end})}
    end.

handle_cast(shutdown, State) ->
    {stop, normal, State};

handle_cast({limit, PrefetchCount}, State) ->
    {noreply, maybe_notify(State, State#lim{prefetch_count = PrefetchCount})};

handle_cast({ack, Count}, State = #lim{volume = Volume}) ->
    NewVolume = if Volume == 0 -> 0;
                   true        -> Volume - Count
                end,
    {noreply, maybe_notify(State, State#lim{volume = NewVolume})};

handle_cast({register, QPid}, State) ->
    {noreply, remember_queue(QPid, State)};

handle_cast({unregister, QPid}, State) ->
    {noreply, forget_queue(QPid, State)}.

handle_info({'DOWN', _MonitorRef, _Type, QPid, _Info}, State) ->
    {noreply, forget_queue(QPid, State)}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    State.

%%----------------------------------------------------------------------------
%% Internal plumbing
%%----------------------------------------------------------------------------

maybe_notify(OldState, NewState) ->
    case limit_reached(OldState) andalso not(limit_reached(NewState)) of
        true  -> notify_queues(NewState);
        false -> NewState
    end.

limit_reached(#lim{prefetch_count = Limit, volume = Volume}) ->
    Limit =/= 0 andalso Volume >= Limit.

remember_queue(QPid, State = #lim{queues = Queues}) ->
    case dict:is_key(QPid, Queues) of
        false -> MRef = erlang:monitor(process, QPid),
                 State#lim{queues = dict:store(QPid, {MRef, false, 0}, Queues)};
        true  -> State
    end.

forget_queue(QPid, State = #lim{ch_pid = ChPid, queues = Queues}) ->
    case dict:find(QPid, Queues) of
        {ok, {MRef, _, _}} ->
            true = erlang:demonitor(MRef),
            unblock(async, QPid, ChPid),
            State#lim{queues = dict:erase(QPid, Queues)};
        error -> State
    end.

limit_queue(QPid, Length, State = #lim{queues = Queues}) ->
    UpdateFun = fun ({MRef, _, _}) -> {MRef, true, Length} end,
    State#lim{queues = dict:update(QPid, UpdateFun, Queues)}.

update_length(QPid, Length, State = #lim{queues = Queues}) ->
    UpdateFun = fun ({MRef, Notify, _}) -> {MRef, Notify, Length} end,
    State#lim{queues = dict:update(QPid, UpdateFun, Queues)}.

is_zero_num(0) -> 0;
is_zero_num(_) -> 1.

notify_queues(State = #lim{ch_pid = ChPid, queues = Queues,
                           prefetch_count = PrefetchCount, volume = Volume}) ->
    {QTree, LengthSum, NonZeroQCount} =
        dict:fold(fun (_QPid, {_, false, _}, Acc) -> Acc;
                      (QPid, {_MRef, true, Length}, {Tree, Sum, NZQCount}) ->
                          Sum1 = Sum + lists:max([1, Length]),
                          {gb_trees:enter(Length, QPid, Tree), Sum1,
                           NZQCount + is_zero_num(Length)}
                  end, {gb_trees:empty(), 0, 0}, Queues),
    Queues1 =
        case gb_trees:size(QTree) of
            0 -> Queues;
            QCount ->
                Capacity = PrefetchCount - Volume,
                case Capacity >= NonZeroQCount of
                    true -> unblock_all(ChPid, QCount, QTree, Queues);
                    false ->
                        %% try to tell enough queues that we guarantee
                        %% we'll get blocked again
                        {Capacity1, Queues2} =
                            unblock_queues(
                              sync, ChPid, LengthSum, Capacity, QTree, Queues),
                        case 0 == Capacity1 of
                            true -> Queues2;
                            false -> %% just tell everyone
                                unblock_all(ChPid, QCount, QTree, Queues2)
                        end
                end
        end,
    State#lim{queues = Queues1}.

unblock_all(ChPid, QCount, QTree, Queues) ->
    {_Capacity2, Queues1} =
        unblock_queues(async, ChPid, 1, QCount, QTree, Queues),
    Queues1.

unblock_queues(_Mode, _ChPid, _L, 0, _QList, Queues) ->
    {0, Queues};
unblock_queues(Mode, ChPid, L, QueueCount, QList, Queues) ->
    {Length, QPid, QList1} = gb_trees:take_largest(QList),
    {_MRef, Blocked, Length} = dict:fetch(QPid, Queues),
    case Length == 0 andalso Mode == sync of
        true -> {QueueCount, Queues};
        false ->
            {QueueCount1, Queues1} =
                case Blocked of
                    false -> {QueueCount, Queues};
                    true ->
                        case 1 >= L orelse Length >= random:uniform(L) of
                            true ->
                                case unblock(Mode, QPid, ChPid) of
                                    true ->
                                        {QueueCount - 1,
                                         dict:update(
                                           QPid, fun unblock_fun/1, Queues)};
                                    false -> {QueueCount, Queues}
                                end;
                            false -> {QueueCount, Queues}
                        end
                end,
            case gb_trees:is_empty(QList1) of
                true -> {QueueCount1, Queues1};
                false -> unblock_queues(Mode, ChPid, L - Length, QueueCount1,
                                        QList1, Queues1)
            end
    end.

unblock(sync, QPid, ChPid) -> rabbit_amqqueue:unblock_sync(QPid, ChPid);
unblock(async, QPid, ChPid) -> rabbit_amqqueue:unblock_async(QPid, ChPid).

unblock_fun({MRef, _, Length}) -> {MRef, false, Length}.

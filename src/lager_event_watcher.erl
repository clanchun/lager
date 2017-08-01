%%%-------------------------------------------------------------------
%%% @author clanchun <clanchun@gmail.com>
%%% @copyright (C) 2016, clanchun
%%% @doc
%%%
%%% @end
%%% Created : 20 Sep 2016 by clanchun <clanchun@gmail.com>
%%%-------------------------------------------------------------------
-module(lager_event_watcher).

-include("lager.hrl").

-compile([{parse_transform, lager_transform}]).

-behaviour(gen_server).

%% API
-export([start_link/4]).

-export([set/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
          threshold        :: non_neg_integer(),
          interval         :: non_neg_integer(),
          cur_num     :: non_neg_integer(),
          max_num     :: non_neg_integer(),
          reboot_after     :: non_neg_integer()
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Threshold, Interval, MaxOverCnt, RebootAfter) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE,
                          [Threshold, Interval, MaxOverCnt, RebootAfter], []).

-spec set(threshold | interval | max_num | rebbot_after, term()) -> {ok, term()}.

set(Key, Value) ->
    gen_server:call(?SERVER, {set, Key, Value}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Threshold, Interval, MaxOverCnt, RebootAfter]) ->
    erlang:send_after(Interval, self(), check),
    {ok, #state{threshold = Threshold,
                interval = Interval,
                cur_num = 0,
                max_num = MaxOverCnt,
                reboot_after = RebootAfter
               }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({set, threshold, NewThreshold}, _From,
            #state{threshold = OldThreshold} = State) ->
    {reply, {ok, OldThreshold, NewThreshold},
     State#state{threshold = NewThreshold}};

handle_call({set, interval, NewInterval}, _From,
            #state{interval = OldInterval} = State) ->
    {reply, {ok, OldInterval, NewInterval}, State#state{interval = NewInterval}};

handle_call({set, max_num, MaxOverCnt}, _From,
            #state{max_num = OldMaxOverCnt} = State) ->
    {reply, {ok, OldMaxOverCnt, MaxOverCnt},
     State#state{max_num = MaxOverCnt}};

handle_call({set, reboot_after, NewRebootAfter}, _From,
            #state{reboot_after = OldRebootAfter} = State) ->
    {reply, {ok, OldRebootAfter, NewRebootAfter},
     State#state{reboot_after = NewRebootAfter}};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(check, #state{threshold = Threshold,
                          interval = Interval,
                          cur_num = CurOverCnt,
                          max_num = MaxOverCnt,
                          reboot_after = RebootAfter
                         } = State) ->
    {_, QLen} = process_info(whereis(lager_event), message_queue_len),
    case check(QLen, Threshold, MaxOverCnt, CurOverCnt) of
        overflow ->
            supervisor:terminate_child(lager_sup, lager),
            error_logger:error_msg("lager event terminated~n"),
            erlang:send_after(RebootAfter, self(), reboot),
            {noreply, State#state{cur_num = 0}};
        {skip, NewCurOverCnt} ->
            erlang:send_after(Interval, self(), check),
            {noreply, State#state{cur_num = NewCurOverCnt}}
    end;

handle_info(reboot, #state{interval = Interval} = State) ->
    supervisor:restart_child(lager_sup, lager),
    lager_app:clean_up_config_checks(),
    lager_app:boot(lager_event),
    lager:log(info, self(), "lager event rebooted~n"),
    erlang:send_after(Interval, self(), check),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check(QLen, Threshold, _MaxOverCnt, _CurOverCnt) when QLen < Threshold ->
    {skip, 0};
check(_QLen, _Threshold, MaxOverCnt, CurOverCnt) ->
    case MaxOverCnt =< CurOverCnt + 1 of
        true ->
            overflow;
        false ->
            {skip, CurOverCnt + 1}
    end.

-module(roadrunner_gleam_ws).
-moduledoc false.
-behaviour(roadrunner_ws_handler).

%% roadrunner_ws_handler callbacks
-export([init/1, handle_frame/2, handle_info/2, handle_drain/2, terminate/2]).

%% The session state: the Gleam callbacks, the tag of the session's
%% subject, and the Gleam state.
-record(session, {handler, on_close, tag, state}).

%% --------------------------------------------------------------------
%% roadrunner_ws_handler callbacks
%% --------------------------------------------------------------------

%% The subject is made here, in the session process, so it is the owner
%% and the messages sent to it reach `handle_info/2`.
init({OnInit, Handler, OnClose}) ->
    Subject = 'gleam@erlang@process':new_subject(),
    {subject, _Owner, Tag} = Subject,
    Session = #session{handler = Handler, on_close = OnClose, tag = Tag},
    to_result(OnInit(Subject), Session).

%% The session reassembles fragmented messages, so only whole text and
%% binary messages arrive here.
handle_frame(#{opcode := text, payload := Payload}, Session) ->
    handle({text, Payload}, Session);
handle_frame(#{opcode := binary, payload := Payload}, Session) ->
    handle({binary, Payload}, Session).

%% Only messages sent to the session's subject reach Gleam; any other
%% message is dropped, as a handler without `handle_info/2` drops them.
handle_info({Tag, Message}, #session{tag = Tag} = Session) ->
    handle({custom, Message}, Session);
handle_info(_Info, Session) ->
    {ok, Session}.

handle_drain(Deadline, Session) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    handle({draining, Remaining}, Session).

terminate(Reason, #session{on_close = OnClose, state = State}) ->
    OnClose(State, close_reason(Reason)).

%% --------------------------------------------------------------------
%% Internal
%% --------------------------------------------------------------------

handle(Message, #session{handler = Handler, state = State} = Session) ->
    to_result(Handler(State, Message), Session).

to_result({continue, State, []}, Session) ->
    {ok, Session#session{state = State}};
to_result({continue, State, Frames}, Session) ->
    {reply, frames(Frames), Session#session{state = State}};
to_result({close, State, Frames, Code, Reason}, Session) ->
    {close, Code, Reason, frames(Frames), Session#session{state = State}}.

frames(Frames) ->
    [frame(Frame) || Frame <- Frames].

frame({text_frame, Text}) -> {text, Text};
frame({binary_frame, Data}) -> {binary, Data};
frame({ping_frame, Data}) -> {ping, Data}.

close_reason(normal) -> normal;
close_reason(remote) -> remote;
close_reason(shutdown) -> shutdown;
close_reason(timeout) -> timeout;
close_reason({error, Reason}) -> {failed, iolist_to_binary(io_lib:format("~0tp", [Reason]))}.

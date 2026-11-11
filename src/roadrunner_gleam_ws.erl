-module(roadrunner_gleam_ws).
-moduledoc false.
-behaviour(roadrunner_ws_handler).

%% roadrunner_ws_handler callbacks
-export([init/1, handle_frame/2, handle_info/2, handle_drain/2, terminate/2]).

%% The session state: the Gleam callbacks, the selector for the session's
%% subject alone, the selector in use (the subject's merged with the one
%% the handler set), and the Gleam state.
-record(session, {handler, on_close, base, selector, state}).

%% --------------------------------------------------------------------
%% roadrunner_ws_handler callbacks
%% --------------------------------------------------------------------

%% The subject is made here, in the session process, so it is the owner
%% and the messages sent to it reach `handle_info/2`.
init({OnInit, Handler, OnClose}) ->
    Subject = 'gleam@erlang@process':new_subject(),
    Base = 'gleam@erlang@process':select('gleam@erlang@process':new_selector(), Subject),
    Session = #session{handler = Handler, on_close = OnClose, base = Base, selector = Base},
    to_result(OnInit(Subject), Session).

%% The session reassembles fragmented messages, so only whole text and
%% binary messages arrive here.
handle_frame(#{opcode := text, payload := Payload}, Session) ->
    handle({text, Payload}, Session);
handle_frame(#{opcode := binary, payload := Payload}, Session) ->
    handle({binary, Payload}, Session).

%% Only messages the session's selector selects reach Gleam; any other
%% message is dropped, as a handler without `handle_info/2` drops them.
handle_info(Info, #session{selector = Selector} = Session) ->
    case roadrunner_gleam_ffi:select_message(Selector, Info) of
        {ok, Message} -> handle({custom, Message}, Session);
        {error, nil} -> {ok, Session}
    end.

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

to_result({continue, State, Frames, Selector}, Session0) ->
    Session = Session0#session{state = State, selector = selector(Selector, Session0)},
    case Frames of
        [] -> {ok, Session};
        _ -> {reply, frames(Frames), Session}
    end;
to_result({close, State, Frames, Code, Reason}, Session) ->
    {close, Code, Reason, frames(Frames), Session#session{state = State}}.

%% A selector the handler set replaces the one before; the session's own
%% subject wins over it, so its messages always arrive.
selector(none, #session{selector = Selector}) ->
    Selector;
selector({some, Selector}, #session{base = Base}) ->
    gleam_erlang_ffi:merge_selector(Selector, Base).

frames(Frames) ->
    [frame(Frame) || Frame <- Frames].

frame({text_frame, Text}) -> {text, Text};
frame({binary_frame, Data}) -> {binary, Data};
%% A control frame carries at most 125 bytes (RFC 6455 §5.5); a longer
%% ping would go out malformed, so it ends the session instead.
frame({ping_frame, Data}) when byte_size(Data) =< 125 -> {ping, Data};
frame({ping_frame, Data}) -> error({ping_payload_too_large, byte_size(Data)}).

close_reason(normal) -> normal;
close_reason(remote) -> remote;
close_reason(shutdown) -> shutdown;
close_reason(timeout) -> timeout;
close_reason({error, Reason}) -> {failed, iolist_to_binary(io_lib:format("~0tp", [Reason]))}.

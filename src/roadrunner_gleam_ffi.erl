-module(roadrunner_gleam_ffi).
-moduledoc false.
-behaviour(roadrunner_handler).

-include_lib("kernel/include/file.hrl").

%% The state of a pushing response: the Gleam callbacks, the tag of its
%% subject, and the Gleam state.
-record(push, {handler, on_disconnect, tag, state}).

%% roadrunner callbacks
-export([handle/1, handle_info/3]).

%% Listener
-export([start_link/2, stop/1, drain/2, listener_port/1, parse_ip/1, routes/1, tuple2/2]).

%% Request
-export([
    header/2,
    body/1,
    read_body/1,
    read_chunk/2,
    query_params/1,
    client_ip/1,
    request_id/1,
    http_version/1
]).

%% Response
-export([send_chunk/2, push/2, file_size/1, identity/1]).

%% --------------------------------------------------------------------
%% roadrunner callback
%% --------------------------------------------------------------------

%% The listener's single handler. The Gleam handler function is the
%% listener's handler state, so one module serves every Gleam app.
handle(Req) ->
    Handler = roadrunner_req:state(Req),
    {response, Status, Headers, Body} = Handler(Req),
    {to_response(Status, Headers, Body, roadrunner_req:method(Req)), Req}.

%% roadrunner strips the body of buffered and sendfile responses on HEAD
%% but leaves stream and loop responses to the handler, so those get the
%% headers only here (RFC 9110 §9.3.2).
to_response(Status, Headers, {chunked, _Stream}, ~"HEAD") ->
    {Status, Headers, ~""};
to_response(Status, Headers, {push, _Builder}, ~"HEAD") ->
    {Status, Headers, ~""};
to_response(Status, Headers, Body, _Method) ->
    to_response(Status, Headers, Body).

to_response(Status, Headers, {bytes, Data}) ->
    {Status, with_length(Status, Headers, iolist_size(Data)), Data};
to_response(Status, Headers, {file, Path, Offset, Length}) ->
    file_response(Status, Headers, Path, Offset, Length);
to_response(Status, Headers, {chunked, Stream}) ->
    {stream, Status, Headers, fun(Send) ->
        _ = Stream(Send),
        Send(~"", fin)
    end};
to_response(_Status, Headers, {web_socket, {builder, OnInit, Handler, OnClose, Options}}) ->
    {websocket, roadrunner_gleam_ws, {OnInit, Handler, OnClose}, Options#{headers => Headers}};
to_response(Status, Headers, {push, {builder, OnInit, Handler, OnDisconnect}}) ->
    %% Made here, in the process that runs the loop, so the messages sent
    %% to the subject reach `handle_info/3`.
    Subject = 'gleam@erlang@process':new_subject(),
    {subject, _Owner, Tag} = Subject,
    {loop, Status, Headers, #push{
        handler = Handler,
        on_disconnect = OnDisconnect,
        tag = Tag,
        state = OnInit(Subject)
    }}.

%% Messages to a pushing response. Only messages sent to its subject reach
%% Gleam; other messages are dropped.
handle_info({roadrunner_disconnect, _Reason}, _Push, #push{} = Loop) ->
    #push{on_disconnect = OnDisconnect, state = State} = Loop,
    _ = OnDisconnect(State),
    {stop, Loop};
handle_info({roadrunner_drain, Deadline}, Push, #push{} = Loop) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    push_message({draining, Remaining}, Push, Loop);
handle_info({Tag, Message}, Push, #push{tag = Tag} = Loop) ->
    push_message({custom, Message}, Push, Loop);
handle_info(_Info, _Push, Loop) ->
    {ok, Loop}.

push_message(Message, Push, #push{handler = Handler, state = State} = Loop) ->
    case Handler(State, Message, Push) of
        {continue, NewState} -> {ok, Loop#push{state = NewState}};
        {stop, NewState} -> {stop, Loop#push{state = NewState}}
    end.

%% A range past the end of the file would send a wrong content-length
%% (and crash the HTTP/3 reader), so it fails the request instead. A
%% zero length is an empty body: `file:sendfile/5` reads 0 as "to the
%% end of the file".
file_response(Status, Headers, _Path, _Offset, 0) ->
    {Status, with_length(Status, Headers, 0), ~""};
file_response(Status, Headers, Path, Offset, Length) ->
    case file:read_file_info(Path) of
        {ok, #file_info{size = Size}} when Offset + Length =< Size ->
            {sendfile, Status, with_length(Status, Headers, Length), {Path, Offset, Length}};
        _ ->
            error({file_range_past_end, Path, Offset, Length})
    end.

%% roadrunner sends buffered and sendfile responses as given, so the
%% content-length is added here unless the handler set one. Responses
%% that must not carry a body never get one (RFC 9110 §8.6).
with_length(Status, Headers, _Length) when Status < 200; Status =:= 204; Status =:= 304 ->
    Headers;
with_length(_Status, Headers, Length) ->
    case lists:keymember(~"content-length", 1, Headers) of
        true -> Headers;
        false -> [{~"content-length", integer_to_binary(Length)} | Headers]
    end.

%% --------------------------------------------------------------------
%% Listener
%% --------------------------------------------------------------------

%% A listener whose `init` fails exits, and the link would take the
%% caller with it; trap exits while starting so the caller gets the error.
%% The start function consumes the `'EXIT'` message itself.
start_link(Name, Opts) ->
    Trapping = process_flag(trap_exit, true),
    Result = roadrunner_listener:start_link(Name, Opts),
    _ = process_flag(trap_exit, Trapping),
    case Result of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, iolist_to_binary(io_lib:format("~0tp", [Reason]))}
    end.

stop(Name) ->
    ok = roadrunner_listener:stop(Name),
    nil.

drain(Name, Timeout) ->
    case roadrunner_listener:drain(Name, Timeout) of
        {ok, drained} -> {ok, nil};
        {timeout, Remaining} -> {error, Remaining}
    end.

listener_port(Name) ->
    roadrunner_listener:port(Name).

parse_ip(String) ->
    case inet:parse_address(binary_to_list(String)) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> {error, nil}
    end.

%% roadrunner's single-handler form: every request goes to `handle/1`,
%% with the Gleam handler as its state.
routes(Handler) ->
    {?MODULE, Handler}.

tuple2(A, B) ->
    {A, B}.

%% --------------------------------------------------------------------
%% Request
%% --------------------------------------------------------------------

header(Req, Name) ->
    to_result(roadrunner_req:header(Name, Req)).

body(Req) ->
    iolist_to_binary(roadrunner_req:body(Req)).

read_body(Req) ->
    case roadrunner_req:read_body(Req) of
        {ok, Data, Req2} -> {ok, {iolist_to_binary(Data), Req2}};
        {error, Reason} -> {error, read_error(Reason)}
    end.

read_chunk(Req, MaxBytes) ->
    case roadrunner_req:read_body(Req, #{length => MaxBytes}) of
        {more, Data, Req2} -> {ok, {more, iolist_to_binary(Data), Req2}};
        {ok, Data, Req2} -> {ok, {last, iolist_to_binary(Data), Req2}};
        {error, Reason} -> {error, read_error(Reason)}
    end.

read_error(content_length_too_large) ->
    body_too_large;
read_error(Reason) ->
    {read_failed, iolist_to_binary(io_lib:format("~0tp", [Reason]))}.

%% A key with no `=` parses to `true`; Gleam gets an empty value.
query_params(Req) ->
    [
        {Key, query_value(Value)}
     || {Key, Value} <- roadrunner_req:parse_qs(Req)
    ].

query_value(true) -> ~"";
query_value(Value) -> Value.

client_ip(Req) ->
    case roadrunner_req:client_ip(Req) of
        undefined -> {error, nil};
        Ip -> {ok, list_to_binary(inet:ntoa(Ip))}
    end.

request_id(Req) ->
    to_result(roadrunner_req:request_id(Req)).

http_version(Req) ->
    case roadrunner_req:version(Req) of
        {1, 0} -> http10;
        {1, 1} -> http11;
        {2, 0} -> http2;
        {3, 0} -> http3
    end.

to_result(undefined) -> {error, nil};
to_result(Value) -> {ok, Value}.

%% --------------------------------------------------------------------
%% Response
%% --------------------------------------------------------------------

send_chunk(Send, Data) ->
    case Send(Data, nofin) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

push(Push, Data) ->
    case Push(Data) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} -> {ok, Size};
        _ -> {error, nil}
    end.

identity(Term) ->
    Term.

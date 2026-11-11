-module(roadrunner_gleam_ffi).
-moduledoc false.
-behaviour(roadrunner_handler).

-include_lib("kernel/include/file.hrl").

%% The state of a pushing response: the Gleam callbacks, the selector for
%% its subject alone, the selector in use (the subject's merged with the
%% one the handler set), what `on_init` sent and has not gone out yet, and
%% the Gleam state.
-record(push, {handler, on_disconnect, base, selector, pending = none, state}).

%% roadrunner callbacks
-export([handle/1, handle_info/3]).

%% Listener
-export([start_link/2, stop/1, drain/2, listener_port/1, listener_quic_port/1, parse_ip/1, routes/1, tuple2/2]).

%% Request
-export([
    header/2,
    header_bits/2,
    headers/1,
    body/1,
    read_body/1,
    read_chunk/2,
    query_params/1,
    client_ip/1,
    ip_address_to_string/1,
    peer/1,
    local_address/1,
    peer_certificate/1,
    cookies/1,
    from_http/6,
    request_id/1,
    http_version/1
]).

%% Response
-export([send_chunk/2, file_size/1, identity/1]).

%% Sessions
-export([select_message/2]).

%% --------------------------------------------------------------------
%% roadrunner callback
%% --------------------------------------------------------------------

%% The listener's single handler. The Gleam handler function is the
%% listener's handler state, so one module serves every Gleam app.
handle(Req) ->
    Handler = roadrunner_req:state(Req),
    {response, Status, Headers, Body} = Handler(Req),
    {to_response(Status, Headers, Body, Req), Req}.

%% A WebSocket upgrade goes through as it is (its 101 is the upgrade).
%% Statuses that carry no body (1xx, 204, 304, RFC 9110 §6.4.1) drop it.
%% roadrunner strips the body of buffered and sendfile responses on HEAD
%% but leaves stream and loop responses to the handler, so those get the
%% headers only here (RFC 9110 §9.3.2), with the framing a GET would have
%% on HTTP/1.1, so roadrunner adds no `content-length: 0` the GET would
%% not send (RFC 9110 §8.6).
to_response(Status, Headers, {web_socket, _} = Body, _Req) ->
    to_response(Status, Headers, Body);
to_response(Status, Headers, _Body, _Req) when
    Status < 200; Status =:= 204; Status =:= 304
->
    {Status, Headers, ~""};
to_response(Status, Headers, {Streamed, _}, #{method := ~"HEAD"} = Req) when
    Streamed =:= chunked; Streamed =:= push
->
    {Status, head_framing(Headers, roadrunner_req:version(Req)), ~""};
to_response(Status, Headers, Body, _Req) ->
    to_response(Status, Headers, Body).

head_framing(Headers, {1, 1}) ->
    case lists:keymember(~"content-length", 1, Headers) of
        true -> Headers;
        false -> [{~"transfer-encoding", ~"chunked"} | Headers]
    end;
head_framing(Headers, _Version) ->
    Headers.

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
    Base = 'gleam@erlang@process':select('gleam@erlang@process':new_selector(), Subject),
    Loop = #push{handler = Handler, on_disconnect = OnDisconnect, base = Base, selector = Base},
    {loop, Status, Headers, after_init(OnInit(Subject), Loop)}.

%% Nothing can be pushed before the headers go out, so what `on_init` sends,
%% or its stop, waits in `pending` and goes out before the first message
%% the loop handles, whichever it is; a message to itself makes sure there
%% is one.
after_init({continue, State, [], Selector}, Loop) ->
    Loop#push{state = State, selector = push_selector(Selector, Loop)};
after_init({continue, State, Data, Selector}, Loop) ->
    self() ! roadrunner_gleam_push_pending,
    Loop#push{state = State, selector = push_selector(Selector, Loop), pending = {Data, continue}};
after_init({stop, State, Data}, Loop) ->
    self() ! roadrunner_gleam_push_pending,
    Loop#push{state = State, pending = {Data, stop}}.

%% Messages to a pushing response. Only messages its selector selects reach
%% Gleam; other messages are dropped. A client that is gone gets nothing
%% more, pending or not.
handle_info({roadrunner_disconnect, _Reason}, _Push, #push{} = Loop) ->
    disconnected(Loop);
handle_info(Info, Push, #push{pending = {Data, Then}} = Loop0) ->
    Loop = Loop0#push{pending = none},
    case {send_data(Push, Data), Then} of
        {ok, continue} -> handle_info(Info, Push, Loop);
        {ok, stop} -> {stop, Loop};
        {error, _} -> disconnected(Loop)
    end;
handle_info(roadrunner_gleam_push_pending, _Push, #push{} = Loop) ->
    {ok, Loop};
handle_info({roadrunner_drain, Deadline}, Push, #push{} = Loop) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    push_message({draining, Remaining}, Push, Loop);
handle_info(Info, Push, #push{selector = Selector} = Loop) ->
    case select_message(Selector, Info) of
        {ok, Message} -> push_message({custom, Message}, Push, Loop);
        {error, nil} -> {ok, Loop}
    end.

push_message(Message, Push, #push{handler = Handler, state = State} = Loop) ->
    case Handler(State, Message) of
        {continue, NewState, Data, Selector} ->
            Loop2 = Loop#push{state = NewState, selector = push_selector(Selector, Loop)},
            case send_data(Push, Data) of
                ok -> {ok, Loop2};
                error -> disconnected(Loop2)
            end;
        {stop, NewState, Data} ->
            _ = send_data(Push, Data),
            {stop, Loop#push{state = NewState}}
    end.

%% The client went away while the response was still going: a failed send
%% usually notices before roadrunner's `roadrunner_disconnect` message does.
%% The loop then ends, so that message never reaches the handler.
disconnected(#push{on_disconnect = OnDisconnect, state = State} = Loop) ->
    _ = OnDisconnect(State),
    {stop, Loop}.

%% A selector the handler set replaces the one before; the response's own
%% subject wins over it, so its messages always arrive.
push_selector(none, #push{selector = Selector}) ->
    Selector;
push_selector({some, Selector}, #push{base = Base}) ->
    gleam_erlang_ffi:merge_selector(Selector, Base).

%% The client being gone ends the response.
send_data(_Push, []) ->
    ok;
send_data(Push, Data) ->
    case Push(Data) of
        ok -> ok;
        {error, _} -> error
    end.

%% A range past the end of the file, or a negative one, would send a wrong
%% content-length (and crash the HTTP/3 reader), so it fails the request
%% instead. A
%% zero length is an empty body: `file:sendfile/5` reads 0 as "to the
%% end of the file".
file_response(Status, Headers, _Path, _Offset, 0) ->
    {Status, with_length(Status, Headers, 0), ~""};
file_response(Status, Headers, Path, Offset, Length) when Offset >= 0, Length >= 0 ->
    case file:read_file_info(Path) of
        {ok, #file_info{size = Size}} when Offset + Length =< Size ->
            {sendfile, Status, with_length(Status, Headers, Length), {Path, Offset, Length}};
        _ ->
            error({file_range_past_end, Path, Offset, Length})
    end;
file_response(_Status, _Headers, Path, Offset, Length) ->
    error({negative_file_range, Path, Offset, Length}).

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

%% A listener already stopped has nothing left to stop or drain.
stop(Name) ->
    case whereis(Name) of
        undefined ->
            nil;
        _Pid ->
            ok = roadrunner_listener:stop(Name),
            nil
    end.

drain(Name, Timeout) ->
    case whereis(Name) of
        undefined -> {ok, nil};
        _Pid -> drain_running(Name, Timeout)
    end.

drain_running(Name, Timeout) ->
    case roadrunner_listener:drain(Name, Timeout) of
        {ok, drained} -> {ok, nil};
        {timeout, Remaining} -> {error, Remaining}
    end.

listener_port(Name) ->
    roadrunner_listener:port(Name).

listener_quic_port(Name) ->
    to_result(roadrunner_listener:quic_port(Name)).

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

%% HTTP lets header values hold bytes 0x80-0xFF (obs-text, RFC 9110
%% §5.5), and Gleam `String`s must be UTF-8, so values are checked when
%% read: nothing is scanned on a request that never reads them.
header(Req, Name) ->
    case roadrunner_req:header(Name, Req) of
        undefined -> {error, nil};
        Value -> utf8_result(Value)
    end.

header_bits(Req, Name) ->
    to_result(roadrunner_req:header(Name, Req)).

headers(Req) ->
    [Header || {_Name, Value} = Header <- roadrunner_req:headers(Req), is_utf8(Value)].

utf8_result(Value) ->
    case is_utf8(Value) of
        true -> {ok, Value};
        false -> {error, nil}
    end.

is_utf8(Binary) ->
    is_binary(unicode:characters_to_binary(Binary)).

body(Req) ->
    iolist_to_binary(roadrunner_req:body(Req)).

read_body(Req) ->
    case roadrunner_req:read_body(Req) of
        {ok, Data, Req2} -> {ok, {iolist_to_binary(Data), Req2}};
        {error, Reason} -> {error, read_error(Reason)}
    end.

%% roadrunner reads a body on demand in pieces of at most `MaxBytes`, but
%% returns a body it read before the handler (auto mode) whole. That one is
%% cut here, so a piece is never larger, whichever way the body was read.
read_chunk(#{body_reader := _} = Req, MaxBytes) ->
    read_body_chunk(Req, max(MaxBytes, 1));
read_chunk(#{roadrunner_gleam_read := done} = Req, _MaxBytes) ->
    {ok, {last, ~"", Req}};
read_chunk(Req, MaxBytes) ->
    Take = max(MaxBytes, 1),
    case iolist_to_binary(roadrunner_req:body(Req)) of
        <<Piece:Take/binary, Rest/binary>> when Rest =/= <<>> ->
            {ok, {more, Piece, Req#{body => Rest}}};
        Last ->
            %% Reading again after the last piece gives nothing, as a body
            %% read on demand does.
            {ok, {last, Last, Req#{body => Last, roadrunner_gleam_read => done}}}
    end.

read_body_chunk(Req, MaxBytes) ->
    case roadrunner_req:read_body(Req, #{length => MaxBytes}) of
        {more, Data, Req2} -> {ok, {more, iolist_to_binary(Data), Req2}};
        {ok, Data, Req2} -> {ok, {last, iolist_to_binary(Data), Req2}};
        {error, Reason} -> {error, read_error(Reason)}
    end.

read_error(content_length_too_large) ->
    body_too_large;
read_error(Reason) ->
    {read_failed, iolist_to_binary(io_lib:format("~0tp", [Reason]))}.

%% A key with no `=` parses to `true`; Gleam gets an empty value. Keys
%% and values are percent-decoded to raw bytes, so they are checked too.
query_params(Req) ->
    Params = [{Key, query_value(Value)} || {Key, Value} <- roadrunner_req:parse_qs(Req)],
    case lists:all(fun({Key, Value}) -> is_utf8(Key) andalso is_utf8(Value) end, Params) of
        true -> {ok, Params};
        false -> {error, nil}
    end.

query_value(true) -> ~"";
query_value(Value) -> Value.

client_ip(Req) ->
    case roadrunner_req:client_ip(Req) of
        undefined -> {error, nil};
        Ip -> {ok, to_ip_address(Ip)}
    end.

peer(Req) ->
    case roadrunner_req:peer(Req) of
        {Ip, Port} -> {ok, {connection_info, to_ip_address(Ip), Port}};
        undefined -> {error, nil}
    end.

local_address(Req) ->
    case roadrunner_req:sockname(Req) of
        {ok, {Ip, Port}} -> {ok, {connection_info, to_ip_address(Ip), Port}};
        {error, _} -> {error, nil}
    end.

peer_certificate(Req) ->
    case roadrunner_req:peercert(Req) of
        {ok, Der} -> {ok, Der};
        {error, _} -> {error, nil}
    end.

%% Gleam's `IpAddress` variants are the inet tuples with a tag in front.
to_ip_address({A, B, C, D}) -> {ip_v4, A, B, C, D};
to_ip_address({A, B, C, D, E, F, G, H}) -> {ip_v6, A, B, C, D, E, F, G, H}.

%% `IpAddress` is public, so it may hold numbers no address has; those
%% are written out as they are instead of failing.
ip_address_to_string(IpAddress) ->
    [Tag | Parts] = tuple_to_list(IpAddress),
    case inet:ntoa(list_to_tuple(Parts)) of
        {error, einval} -> raw_ip_string(Tag, Parts);
        Text -> list_to_binary(Text)
    end.

raw_ip_string(ip_v4, Parts) ->
    iolist_to_binary(lists:join(~".", [integer_to_binary(Part) || Part <- Parts]));
raw_ip_string(ip_v6, Parts) ->
    iolist_to_binary(lists:join(~":", [integer_to_binary(Part, 16) || Part <- Parts])).

cookies(Req) ->
    [Cookie || {Name, Value} = Cookie <- roadrunner_req:parse_cookies(Req), is_utf8(Name), is_utf8(Value)].

%% The fields roadrunner's accessors need, as its request builders set
%% them, for a request built in a test.
from_http(Method, Target, Path, Headers, Body, Scheme) ->
    #{
        method => Method,
        target => Target,
        path => Path,
        version => {1, 1},
        headers => Headers,
        body => Body,
        scheme => Scheme
    }.

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

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} -> {ok, Size};
        _ -> {error, nil}
    end.

identity(Term) ->
    Term.

%% --------------------------------------------------------------------
%% Sessions
%% --------------------------------------------------------------------

%% Apply a gleam_erlang `Selector` to a message already received, with the
%% lookups `gleam_erlang_ffi:select/2` makes in its `receive`: a monitor's
%% `'DOWN'` by its reference, then a tuple by its tag and size, then the
%% handler for any message.
select_message({selector, Handlers}, {'DOWN', Ref, _, _, _} = Message) when
    is_map_key(Ref, Handlers)
->
    Handler = maps:get(Ref, Handlers),
    {ok, Handler(gleam_erlang_ffi:cast_down_message(Message))};
select_message({selector, Handlers}, Message) when
    is_tuple(Message),
    tuple_size(Message) > 0,
    is_map_key({element(1, Message), tuple_size(Message)}, Handlers)
->
    Handler = maps:get({element(1, Message), tuple_size(Message)}, Handlers),
    {ok, Handler(Message)};
select_message({selector, #{anything := Handler}}, Message) ->
    {ok, Handler(Message)};
select_message({selector, _Handlers}, _Message) ->
    {error, nil}.

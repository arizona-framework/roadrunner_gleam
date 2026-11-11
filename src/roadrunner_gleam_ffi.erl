-module(roadrunner_gleam_ffi).
-moduledoc false.
-behaviour(roadrunner_handler).

-include_lib("kernel/include/file.hrl").

%% roadrunner callback
-export([handle/1]).

%% Listener
-export([start_link/2, stop/1, drain/2, listener_port/1, parse_ip/1, routes/1, tuple2/2]).

%% Request
-export([
    header/2,
    body/1,
    query_params/1,
    client_ip/1,
    request_id/1,
    http_version/1
]).

%% Response
-export([send_chunk/2, file_size/1, identity/1]).

%% --------------------------------------------------------------------
%% roadrunner callback
%% --------------------------------------------------------------------

%% The listener's single handler. The Gleam handler function is the
%% listener's handler state, so one module serves every Gleam app.
handle(Req) ->
    Handler = roadrunner_req:state(Req),
    {response, Status, Headers, Body} = Handler(Req),
    {to_response(Status, Headers, Body), Req}.

to_response(Status, Headers, {bytes, Data}) ->
    {Status, with_length(Status, Headers, iolist_size(Data)), Data};
to_response(Status, Headers, {file, Path, Offset, Length}) ->
    {sendfile, Status, with_length(Status, Headers, Length), {Path, Offset, Length}};
to_response(Status, Headers, {chunked, Stream}) ->
    {stream, Status, Headers, fun(Send) ->
        _ = Stream(Send),
        Send(~"", fin)
    end};
to_response(_Status, Headers, {web_socket, {builder, OnInit, Handler, OnClose, Options}}) ->
    {websocket, roadrunner_gleam_ws, {OnInit, Handler, OnClose}, Options#{headers => Headers}}.

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

start_link(Name, Opts) ->
    case roadrunner_listener:start_link(Name, Opts) of
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

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} -> {ok, Size};
        _ -> {error, nil}
    end.

identity(Term) ->
    Term.

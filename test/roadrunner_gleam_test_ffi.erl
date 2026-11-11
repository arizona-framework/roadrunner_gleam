-module(roadrunner_gleam_test_ffi).
-export([request/4, silence_logger/0, write_cert/1, tls_get/1, alpn/1]).
-export([ws_connect/2, ws_send/3, ws_recv/1, ws_close/1, open_get/2]).

%% A test certificate chain and key written as PEM files under `Dir`.
write_cert(Dir) ->
    Key = fun() -> public_key:generate_key({namedCurve, secp256r1}) end,
    Chain = [{key, Key()}, {digest, sha256}],
    #{server_config := Config} = public_key:pkix_test_data(#{
        server_chain => #{root => Chain, peer => [{key, Key()}, {digest, sha256}]},
        client_chain => #{root => Chain, peer => [{key, Key()}, {digest, sha256}]}
    }),
    Cert = proplists:get_value(cert, Config),
    CaCerts = proplists:get_value(cacerts, Config),
    {KeyType, KeyDer} = proplists:get_value(key, Config),
    ok = filelib:ensure_path(Dir),
    CertFile = filename:join(Dir, ~"cert.pem"),
    KeyFile = filename:join(Dir, ~"key.pem"),
    ok = file:write_file(
        CertFile,
        public_key:pem_encode([{'Certificate', C, not_encrypted} || C <- [Cert | CaCerts]])
    ),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    {CertFile, KeyFile}.

%% An HTTPS GET that skips certificate checks, returning the body.
tls_get(Url) ->
    {ok, _} = application:ensure_all_started([inets, ssl]),
    {ok, {{_, 200, _}, _, Body}} =
        httpc:request(get, {binary_to_list(Url), []}, [{ssl, [{verify, verify_none}]}], [
            {body_format, binary}
        ]),
    Body.

%% The protocol the server picks when a client offers h2 and http/1.1.
alpn(Port) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, Socket} = ssl:connect("127.0.0.1", Port, [
        {verify, verify_none}, {alpn_advertised_protocols, [~"h2", ~"http/1.1"]}
    ]),
    {ok, Protocol} = ssl:negotiated_protocol(Socket),
    ok = ssl:close(Socket),
    Protocol.

silence_logger() ->
    _ = logger:remove_handler(default),
    nil.

%% A plain HTTP/1.1 request through `httpc`, returning
%% `{Status, Headers, Body}` with binary headers and body.
request(Method, Url, Headers, Body) ->
    {ok, _} = application:ensure_all_started(inets),
    HttpcHeaders = [{binary_to_list(N), binary_to_list(V)} || {N, V} <- Headers],
    Request =
        case Method of
            get -> {binary_to_list(Url), HttpcHeaders};
            _ -> {binary_to_list(Url), HttpcHeaders, "application/octet-stream", Body}
        end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [], [{body_format, binary}]),
    {Status, [{list_to_binary(N), list_to_binary(V)} || {N, V} <- RespHeaders], RespBody}.

%% A minimal WebSocket client over a passive socket, enough for small
%% frames: connect returns the socket and the 101 response headers.
ws_connect(Port, Path) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, [
        ~"GET ", Path, ~" HTTP/1.1\r\n",
        ~"host: 127.0.0.1\r\n",
        ~"upgrade: websocket\r\n",
        ~"connection: Upgrade\r\n",
        ~"sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        ~"sec-websocket-version: 13\r\n\r\n"
    ]),
    {ok, Head, Rest} = recv_head(Socket, <<>>),
    %% Frames the server sent right after the 101 can come in the same
    %% read; keep them for `ws_recv/1`.
    _ = put({ws_buffer, Socket}, Rest),
    [StatusLine | Lines] = binary:split(Head, ~"\r\n", [global, trim_all]),
    <<"HTTP/1.1 101", _/binary>> = StatusLine,
    Headers = [
        {roadrunner_bin:ascii_lowercase(Name), Value}
     || Line <- Lines, [Name, Value] <- [binary:split(Line, ~": ")]
    ],
    {Socket, Headers}.

recv_head(Socket, Acc) ->
    case binary:split(Acc, ~"\r\n\r\n") of
        [Head, Rest] ->
            {ok, Head, Rest};
        [_] ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
            recv_head(Socket, <<Acc/binary, Data/binary>>)
    end.

%% Send one masked frame with a payload under 126 bytes.
ws_send(Socket, Opcode, Payload) ->
    Mask = <<1, 2, 3, 4>>,
    Size = byte_size(Payload),
    true = Size < 126,
    Masked = mask(Payload, Mask, <<>>),
    ok = gen_tcp:send(Socket, <<1:1, 0:3, (opcode(Opcode)):4, 1:1, Size:7, Mask/binary, Masked/binary>>),
    nil.

mask(<<Byte, Rest/binary>>, <<M, _/binary>> = Mask, Acc) ->
    <<_, MaskRest/binary>> = Mask,
    mask(Rest, <<MaskRest/binary, M>>, <<Acc/binary, (Byte bxor M)>>);
mask(<<>>, _Mask, Acc) ->
    Acc.

opcode(text) -> 1;
opcode(binary) -> 2;
opcode(close) -> 8;
opcode(ping) -> 9;
opcode(pong) -> 10.

%% Receive one unmasked server frame with a payload under 126 bytes, as
%% `{Opcode, Payload}`.
ws_recv(Socket) ->
    <<_:4, Op:4, 0:1, Size:7>> = recv_exact(Socket, 2),
    true = Size < 126,
    {opcode_name(Op), recv_exact(Socket, Size)}.

%% `Size` bytes, from what the handshake read left over first.
recv_exact(Socket, Size) ->
    Buffer = get({ws_buffer, Socket}),
    case Buffer of
        <<Bytes:Size/binary, Rest/binary>> ->
            _ = put({ws_buffer, Socket}, Rest),
            Bytes;
        _ ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
            _ = put({ws_buffer, Socket}, <<Buffer/binary, Data/binary>>),
            recv_exact(Socket, Size)
    end.

opcode_name(1) -> text;
opcode_name(2) -> binary;
opcode_name(8) -> close;
opcode_name(9) -> ping;
opcode_name(10) -> pong.

ws_close(Socket) ->
    ok = gen_tcp:close(Socket),
    nil.

%% Send a GET and wait for the response headers, leaving the response
%% open: the socket is returned for the caller to close.
open_get(Port, Path) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, [~"GET ", Path, ~" HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n"]),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Socket, 0, 5000),
    Socket.

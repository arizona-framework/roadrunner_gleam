-module(roadrunner_gleam_test_ffi).
-export([request/4, silence_logger/0, write_cert/1, tls_get/1, alpn/1]).

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

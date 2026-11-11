import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/string
import gleam/string_tree
import gleeunit
import roadrunner_gleam.{type Builder, type Listener}
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}

pub fn main() -> Nil {
  silence_logger()
  gleeunit.main()
}

// Expected crashes, such as a listener failing to start, would otherwise
// print reports over the test output.
@external(erlang, "roadrunner_gleam_test_ffi", "silence_logger")
fn silence_logger() -> Nil

// --- helpers --------------------------------------------------------

fn serve(
  name: String,
  handler: fn(Request) -> Response,
  test_body: fn(String) -> a,
) -> a {
  roadrunner_gleam.new(handler)
  |> roadrunner_gleam.port(0)
  |> roadrunner_gleam.bind("127.0.0.1")
  |> roadrunner_gleam.name(name)
  |> with_listener(test_body)
}

fn with_listener(builder: Builder, test_body: fn(String) -> a) -> a {
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.start(builder)
  let result = test_body(base_url(listener))
  roadrunner_gleam.stop(listener)
  result
}

fn base_url(listener: Listener) -> String {
  "http://127.0.0.1:" <> int.to_string(roadrunner_gleam.listener_port(listener))
}

fn get(url: String) -> #(Int, List(#(String, String)), BitArray) {
  http_call(atom.create("get"), url, [], <<>>)
}

fn post(
  url: String,
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray) {
  http_call(atom.create("post"), url, [], body)
}

@external(erlang, "roadrunner_gleam_test_ffi", "request")
fn http_call(
  method: Atom,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

fn header(
  headers: List(#(String, String)),
  name: String,
) -> Result(String, Nil) {
  list.key_find(headers, name)
}

fn header_count(headers: List(#(String, String)), name: String) -> Int {
  list.count(headers, fn(header) { header.0 == name })
}

// --- request --------------------------------------------------------

pub fn request_fields_test() {
  use url <- serve("rg_request_fields", fn(req) {
    let assert http.Get = request.method(req)
    let assert ["users", "42"] = request.path_segments(req)
    let assert http.Http = request.scheme(req)
    let assert request.Http11 = request.http_version(req)
    let assert Ok("127.0.0.1") = request.client_ip(req)
    let assert Ok(id) = request.request_id(req)
    let assert True = id != ""
    let assert Ok("yes") = request.header(req, "X-Test")
    let assert True = list.contains(request.headers(req), #("x-test", "yes"))
    response.text(
      request.path(req)
      <> "?"
      <> request.query(req)
      <> " "
      <> string.inspect(request.query_params(req)),
    )
  })
  let #(status, _, body) =
    http_call(
      atom.create("get"),
      url <> "/users/42?a=1&b&c=x%20y",
      [#("x-test", "yes")],
      <<>>,
    )
  assert status == 200
  assert body
    == <<
      "/users/42?a=1&b&c=x%20y Ok([#(\"a\", \"1\"), #(\"b\", \"\"), #(\"c\", \"x y\")])",
    >>
}

pub fn request_missing_header_test() {
  use url <- serve("rg_missing_header", fn(req) {
    let assert Error(Nil) = request.header(req, "x-missing")
    response.new(204)
  })
  let #(status, _, _) = get(url)
  assert status == 204
}

pub fn request_body_test() {
  use url <- serve("rg_request_body", fn(req) {
    let assert http.Post = request.method(req)
    response.new(200)
    |> response.set_body(
      response.Bytes(bytes_tree.from_bit_array(request.body(req))),
    )
  })
  let #(status, _, body) = post(url, <<"hello body">>)
  assert status == 200
  assert body == <<"hello body">>
}

pub fn request_other_method_test() {
  use url <- serve("rg_other_method", fn(req) {
    response.text(http.method_to_string(request.method(req)))
  })
  let #(_, _, body) = http_call(atom.create("patch"), url, [], <<"x">>)
  assert body == <<"PATCH">>
}

pub fn to_http_test() {
  let self = process.new_subject()
  use url <- serve("rg_to_http", fn(req) {
    process.send(self, request.to_http(req))
    response.new(204)
  })
  let #(status, _, _) = post(url <> "/a/b?x=1", <<"payload">>)
  assert status == 204
  let assert Ok(http_request.Request(
    method: http.Post,
    scheme: http.Http,
    host: "127.0.0.1",
    port: Some(_),
    path: "/a/b",
    query: Some("x=1"),
    body: <<"payload">>,
    ..,
  )) = process.receive(self, 1000)
}

pub fn to_http_without_query_test() {
  let self = process.new_subject()
  use url <- serve("rg_to_http_no_query", fn(req) {
    process.send(self, request.to_http(req))
    response.new(204)
  })
  let _ = get(url)
  let assert Ok(http_request.Request(query: None, ..)) =
    process.receive(self, 1000)
}

// --- response -------------------------------------------------------

pub fn text_response_test() {
  use url <- serve("rg_text", fn(_) { response.text("hello, roadrunner!") })
  let #(status, headers, body) = get(url)
  assert status == 200
  assert body == <<"hello, roadrunner!">>
  assert header(headers, "content-type") == Ok("text/plain; charset=utf-8")
  assert header(headers, "content-length") == Ok("18")
}

pub fn html_and_json_response_test() {
  use url <- serve("rg_html_json", fn(req) {
    case request.path_segments(req) {
      ["html"] -> response.html(string_tree.from_string("<p>hi</p>"))
      _ -> response.json(string_tree.from_string("{\"ok\":true}"))
    }
  })
  let #(_, html_headers, html) = get(url <> "/html")
  assert html == <<"<p>hi</p>">>
  assert header(html_headers, "content-type") == Ok("text/html; charset=utf-8")
  let #(_, json_headers, json) = get(url <> "/json")
  assert json == <<"{\"ok\":true}">>
  assert header(json_headers, "content-type") == Ok("application/json")
}

pub fn content_length_kept_test() {
  use url <- serve("rg_content_length_kept", fn(_) {
    response.text("abc") |> response.set_header("content-length", "3")
  })
  let #(_, headers, body) = get(url)
  assert body == <<"abc">>
  assert header_count(headers, "content-length") == 1
}

pub fn no_content_length_on_204_test() {
  use url <- serve("rg_no_length_204", fn(_) { response.new(204) })
  let #(status, headers, _) = get(url)
  assert status == 204
  assert header(headers, "content-length") == Error(Nil)
}

pub fn chunked_response_test() {
  use url <- serve("rg_chunked", fn(_) {
    response.new(200)
    |> response.set_body(
      response.Chunked(fn(sender) {
        let assert Ok(Nil) =
          response.send_chunk(sender, bytes_tree.from_string("one "))
        let assert Ok(Nil) =
          response.send_chunk(sender, bytes_tree.from_string("two"))
        Nil
      }),
    )
  })
  let #(status, _, body) = get(url)
  assert status == 200
  assert body == <<"one two">>
}

pub fn file_response_test() {
  let path = "gleam.toml"
  use url <- serve("rg_file", fn(_) {
    let assert Ok(body) = response.file(path)
    response.new(200) |> response.set_body(body)
  })
  let #(status, headers, body) = get(url)
  let assert Ok(contents) = read_file(path)
  assert status == 200
  assert body == contents
  assert header(headers, "content-length")
    == Ok(int.to_string(bit_array.byte_size(contents)))
}

pub fn file_range_response_test() {
  use url <- serve("rg_file_range", fn(_) {
    response.new(200)
    |> response.set_body(response.File(path: "gleam.toml", offset: 0, length: 4))
  })
  let #(_, headers, body) = get(url)
  assert body == <<"name">>
  assert header(headers, "content-length") == Ok("4")
}

pub fn missing_file_test() {
  assert response.file("does/not/exist") == Error(Nil)
  assert response.file("src") == Error(Nil)
}

pub fn from_http_test() {
  use url <- serve("rg_from_http", fn(_) {
    http_response.new(201)
    |> http_response.set_header("x-from", "gleam_http")
    |> http_response.set_body(bytes_tree.from_string("created"))
    |> response.from_http
  })
  let #(status, headers, body) = get(url)
  assert status == 201
  assert body == <<"created">>
  assert header(headers, "x-from") == Ok("gleam_http")
}

// --- listener -------------------------------------------------------

pub fn option_test() {
  let builder =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.name("rg_option")
    |> roadrunner_gleam.option("max_content_length", dynamic.int(4))
  use url <- with_listener(builder)
  let #(status, _, _) = post(url, <<"too long">>)
  assert status == 413
}

pub fn default_name_test() {
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.start
  let #(status, _, _) = get(base_url(listener))
  assert status == 200
  roadrunner_gleam.stop(listener)
}

pub fn invalid_ip_test() {
  let assert Error(actor.InitFailed("invalid ip address: nope")) =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.bind("nope")
    |> roadrunner_gleam.start
}

pub fn http3_needs_tls_test() {
  let assert Error(actor.InitFailed("http3 needs tls")) =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.http3
    |> roadrunner_gleam.start
}

// A port already in use fails on every OTP version, and the caller gets
// the error instead of exiting with the listener.
pub fn start_error_test() {
  let assert Ok(actor.Started(data: taken, ..)) =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.name("rg_port_taken")
    |> roadrunner_gleam.start
  let result =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.port(roadrunner_gleam.listener_port(taken))
    |> roadrunner_gleam.name("rg_start_error")
    |> roadrunner_gleam.start
  roadrunner_gleam.stop(taken)
  let assert Error(actor.InitFailed(_)) = result
}

pub fn http3_needs_fixed_port_test() {
  let assert Error(actor.InitFailed(
    "http3 needs a fixed port: with port 0, HTTP/3 gets its own",
  )) =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.tls(certfile: "cert.pem", keyfile: "key.pem")
    |> roadrunner_gleam.http3
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.start
}

pub fn drain_test() {
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.name("rg_drain")
    |> roadrunner_gleam.start
  assert roadrunner_gleam.drain(listener, 1000) == Ok(Nil)
}

pub fn supervised_test() {
  let self = process.new_subject()
  let child =
    roadrunner_gleam.new(fn(_) { response.text("supervised") })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.name("rg_supervised")
    |> roadrunner_gleam.supervised
    |> supervision.map_data(fn(listener) {
      process.send(self, listener)
      listener
    })
  let assert Ok(actor.Started(pid: supervisor, ..)) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  let assert Ok(listener) = process.receive(self, 1000)
  let #(_, _, body) = get(base_url(listener))
  assert body == <<"supervised">>
  process.unlink(supervisor)
  process.kill(supervisor)
}

pub fn tls_test() {
  let #(certfile, keyfile) = write_cert("build/test_tls")
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(fn(req) {
      let assert http.Https = request.scheme(req)
      response.text("secure")
    })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name("rg_tls")
    |> roadrunner_gleam.tls(certfile:, keyfile:)
    |> roadrunner_gleam.start
  let port = roadrunner_gleam.listener_port(listener)
  assert tls_get("https://127.0.0.1:" <> int.to_string(port)) == <<"secure">>
  assert alpn(port) == "h2"
  roadrunner_gleam.stop(listener)
}

@external(erlang, "roadrunner_gleam_test_ffi", "write_cert")
fn write_cert(dir: String) -> #(String, String)

@external(erlang, "roadrunner_gleam_test_ffi", "tls_get")
fn tls_get(url: String) -> BitArray

@external(erlang, "roadrunner_gleam_test_ffi", "alpn")
fn alpn(port: Int) -> String

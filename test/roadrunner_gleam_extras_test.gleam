import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string
import roadrunner_gleam.{type Builder}
import roadrunner_gleam/request
import roadrunner_gleam/response

// --- helpers --------------------------------------------------------

fn serve(builder: Builder, name: String, test_body: fn(Int) -> a) -> a {
  let assert Ok(actor.Started(data: listener, ..)) =
    builder
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> roadrunner_gleam.start
  let result = test_body(roadrunner_gleam.listener_port(listener))
  roadrunner_gleam.stop(listener)
  result
}

fn get(
  port: Int,
  headers: List(#(String, String)),
) -> #(Int, List(#(String, String)), BitArray) {
  http_call(
    atom.create("get"),
    "http://127.0.0.1:" <> int.to_string(port),
    headers,
    <<>>,
  )
}

@external(erlang, "roadrunner_gleam_test_ffi", "request")
fn http_call(
  method: Atom,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray)

@external(erlang, "zlib", "gunzip")
fn gunzip(data: BitArray) -> BitArray

// --- cookies --------------------------------------------------------

pub fn cookies_test() {
  let builder =
    roadrunner_gleam.new(fn(req) {
      response.text(string.inspect(request.cookies(req)))
    })
  use port <- serve(builder, "rg_cookies")
  let #(_, _, body) = get(port, [#("cookie", "a=1; b=two")])
  assert body == <<"[#(\"a\", \"1\"), #(\"b\", \"two\")]">>
}

// --- connection info ------------------------------------------------

pub fn connection_info_test() {
  let self = process.new_subject()
  let builder =
    roadrunner_gleam.new(fn(req) {
      process.send(self, #(
        request.peer(req),
        request.local_address(req),
        request.peer_certificate(req),
      ))
      response.new(204)
    })
  use port <- serve(builder, "rg_conn_info")
  let _ = get(port, [])
  let assert Ok(#(Ok(peer), Ok(local), Error(Nil))) =
    process.receive(self, 1000)
  assert peer.ip_address == request.IpV4(127, 0, 0, 1)
  assert peer.port > 0
  assert local == request.ConnectionInfo(request.IpV4(127, 0, 0, 1), port)
}

pub fn ip_address_to_string_test() {
  assert request.ip_address_to_string(request.IpV4(10, 0, 0, 1)) == "10.0.0.1"
  assert request.ip_address_to_string(request.IpV6(0, 0, 0, 0, 0, 0, 0, 1))
    == "::1"
}

// --- compression ----------------------------------------------------

fn large_text(_) {
  response.text(string.repeat("roadrunner ", 100))
}

pub fn compress_test() {
  let builder = roadrunner_gleam.new(large_text) |> roadrunner_gleam.compress
  use port <- serve(builder, "rg_compress")
  let #(_, headers, body) = get(port, [#("accept-encoding", "gzip")])
  assert list.key_find(headers, "content-encoding") == Ok("gzip")
  assert gunzip(body) == <<string.repeat("roadrunner ", 100):utf8>>
}

pub fn no_compress_by_default_test() {
  use port <- serve(roadrunner_gleam.new(large_text), "rg_no_compress")
  let #(_, headers, body) = get(port, [#("accept-encoding", "gzip")])
  assert list.key_find(headers, "content-encoding") == Error(Nil)
  assert bit_array.byte_size(body) == 1100
}

// --- from_http ------------------------------------------------------

pub fn from_http_test() {
  let req =
    http_request.new()
    |> http_request.set_method(http.Post)
    |> http_request.set_host("example.com")
    |> http_request.set_path("/users/42")
    |> http_request.set_query([#("page", "2")])
    |> http_request.set_header("x-test", "yes")
    |> http_request.set_body(<<"payload">>)
    |> request.from_http
  assert request.method(req) == http.Post
  assert request.path_segments(req) == ["users", "42"]
  assert request.query_params(req) == Ok([#("page", "2")])
  assert request.header(req, "x-test") == Ok("yes")
  assert request.body(req) == <<"payload">>
  assert request.read_body(req) |> result_data == Ok(<<"payload">>)
  assert request.http_version(req) == request.Http11
  assert request.client_ip(req) == Error(Nil)
  assert request.request_id(req) == Error(Nil)
  let back = request.to_http(req)
  assert back.host == "example.com"
  assert back.query == Some("page=2")
  assert back.scheme == http.Https
}

fn result_data(
  result: Result(#(BitArray, request.Request), request.ReadError),
) -> Result(BitArray, request.ReadError) {
  case result {
    Ok(#(data, _)) -> Ok(data)
    Error(error) -> Error(error)
  }
}

// `IpAddress` is public, so it can hold numbers no address has.
pub fn ip_address_to_string_out_of_range_test() {
  assert request.ip_address_to_string(request.IpV4(256, 0, 0, -1))
    == "256.0.0.-1"
  assert request.ip_address_to_string(request.IpV6(65_536, 0, 0, 0, 0, 0, 0, 1))
    == "10000:0:0:0:0:0:0:1"
}

pub fn stop_twice_test() {
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(fn(_) { response.new(200) })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.name("rg_stop_twice")
    |> roadrunner_gleam.start
  roadrunner_gleam.stop(listener)
  roadrunner_gleam.stop(listener)
  assert roadrunner_gleam.drain(listener, 100) == Ok(Nil)
}

// --- heap floor -----------------------------------------------------

/// Two pipelined requests on one connection: `/alloc` grows the heap, then
/// `/report` answers with the `min_heap_size` the connection runs at.
fn floor_after_alloc(builder: Builder, name: String) -> Int {
  use port <- serve(builder, name)
  let response =
    raw_request(port, <<
      "GET /alloc HTTP/1.1\r\nhost: x\r\n\r\n":utf8,
      "GET /report HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n":utf8,
    >>)
  let assert Ok(text) = bit_array.to_string(response)
  let assert Ok(last) = list.last(string.split(text, "\r\n\r\n"))
  let assert Ok(floor) = int.parse(last)
  floor
}

fn floor_handler(req: request.Request) -> response.Response {
  case request.path_segments(req) {
    ["alloc"] -> response.text(int.to_string(alloc()))
    _ -> response.text(int.to_string(min_heap_size()))
  }
}

pub fn heap_floor_test() {
  let floor =
    roadrunner_gleam.new(floor_handler)
    |> roadrunner_gleam.heap_floor(max: 1000)
    |> floor_after_alloc("rg_heap_floor")
  assert floor == rounded_heap_size(1000)
}

pub fn no_heap_floor_test() {
  let floor =
    roadrunner_gleam.new(floor_handler)
    |> roadrunner_gleam.no_heap_floor
    |> floor_after_alloc("rg_no_heap_floor")
  assert floor == default_min_heap_size()
}

@external(erlang, "roadrunner_gleam_test_ffi", "raw_request")
fn raw_request(port: Int, request: BitArray) -> BitArray

@external(erlang, "roadrunner_gleam_test_ffi", "alloc")
fn alloc() -> Int

@external(erlang, "roadrunner_gleam_test_ffi", "min_heap_size")
fn min_heap_size() -> Int

@external(erlang, "roadrunner_gleam_test_ffi", "default_min_heap_size")
fn default_min_heap_size() -> Int

@external(erlang, "roadrunner_gleam_test_ffi", "rounded_heap_size")
fn rounded_heap_size(words: Int) -> Int

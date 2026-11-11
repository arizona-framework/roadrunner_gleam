import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/atom.{type Atom}
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string
import roadrunner_gleam.{type Builder}
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}

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

fn post(
  port: Int,
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray) {
  http_call(
    atom.create("post"),
    "http://127.0.0.1:" <> int.to_string(port),
    [],
    body,
  )
}

/// A chunked upload of these chunks, on a connection that closes after.
fn chunked_post(port: Int, chunks: List(String)) -> String {
  let body =
    string.concat(
      list.map(chunks, fn(chunk) {
        int.to_base16(string.byte_size(chunk)) <> "\r\n" <> chunk <> "\r\n"
      }),
    )
  let request =
    "POST / HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n"
    <> "transfer-encoding: chunked\r\n\r\n"
    <> body
    <> "0\r\n\r\n"
  let assert Ok(response) =
    bit_array.to_string(raw_request(port, <<request:utf8>>))
  response
}

@external(erlang, "roadrunner_gleam_test_ffi", "request")
fn http_call(
  method: Atom,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray)

@external(erlang, "roadrunner_gleam_test_ffi", "raw_request")
fn raw_request(port: Int, request: BitArray) -> BitArray

/// Reads the body in pieces of 3 bytes and answers them joined with "|".
fn pieces(request: Request) -> Response {
  case read_pieces(request, "") {
    Ok(joined) -> response.text(joined)
    Error(request.BodyTooLarge) -> response.text("too large")
    Error(request.ReadFailed(reason)) -> response.text(reason)
  }
}

fn read_pieces(
  request: Request,
  joined: String,
) -> Result(String, request.ReadError) {
  case request.read_chunk(request, 3) {
    Ok(request.More(data, next)) ->
      read_pieces(next, joined <> to_string(data) <> "|")
    Ok(request.Last(data, _)) -> Ok(joined <> to_string(data))
    Error(error) -> Error(error)
  }
}

fn to_string(data: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(data)
  text
}

fn on_demand(handler: fn(Request) -> Response) -> Builder {
  roadrunner_gleam.new(handler) |> roadrunner_gleam.read_body_on_demand
}

// --- tests ----------------------------------------------------------

pub fn read_chunk_test() {
  use port <- serve(on_demand(pieces), "rg_read_chunk")
  let #(status, _, body) = post(port, <<"hello world">>)
  assert status == 200
  assert body == <<"hel|lo |wor|ld">>
}

pub fn read_chunk_chunked_upload_test() {
  use port <- serve(on_demand(pieces), "rg_read_chunk_chunked")
  let response = chunked_post(port, ["he", "llo w", "orld"])
  assert string.ends_with(response, "\r\n\r\nhel|lo |wor|ld")
}

pub fn read_body_test() {
  let handler = fn(request) {
    let assert "" = to_string(request.body(request))
    let assert Ok(#(data, _)) = request.read_body(request)
    response.new(200)
    |> http_response.set_body(response.Bytes(bytes_tree.from_bit_array(data)))
  }
  use port <- serve(on_demand(handler), "rg_read_body")
  let #(_, _, body) = post(port, <<"whole body">>)
  assert body == <<"whole body">>
}

// A body roadrunner read before the handler comes in pieces of the same
// size as one read on demand.
pub fn read_chunk_when_already_read_test() {
  use port <- serve(roadrunner_gleam.new(pieces), "rg_read_chunk_auto")
  let #(_, _, body) = post(port, <<"hello world">>)
  assert body == <<"hel|lo |wor|ld">>
}

pub fn read_body_when_already_read_test() {
  let handler = fn(request) {
    let assert Ok(#(data, _)) = request.read_body(request)
    response.text(to_string(data))
  }
  use port <- serve(roadrunner_gleam.new(handler), "rg_read_body_auto")
  let #(_, _, body) = post(port, <<"abc">>)
  assert body == <<"abc">>
}

pub fn body_too_large_test() {
  let builder =
    on_demand(pieces)
    |> roadrunner_gleam.option("max_content_length", dynamic.int(4))
  use port <- serve(builder, "rg_body_too_large")
  let response = chunked_post(port, ["hello", "world"])
  assert string.ends_with(response, "\r\n\r\ntoo large")
}

// A declared length over the limit fails the read, the handler running.
pub fn body_too_large_declared_test() {
  let builder =
    on_demand(pieces)
    |> roadrunner_gleam.option("max_content_length", dynamic.int(4))
  use port <- serve(builder, "rg_body_too_large_declared")
  let #(status, _, body) = post(port, <<"hello world">>)
  assert status == 200
  assert body == <<"too large">>
}

fn pieces_of(size: Int) -> fn(Request) -> Response {
  fn(request) { response.text(int.to_string(count_pieces(request, size, 0))) }
}

fn count_pieces(request: Request, size: Int, count: Int) -> Int {
  case request.read_chunk(request, size) {
    Ok(request.More(_, next)) -> count_pieces(next, size, count + 1)
    Ok(request.Last(_, _)) -> count + 1
    Error(_) -> -1
  }
}

// A size below 1 reads a byte at a time instead of nothing forever.
pub fn read_chunk_zero_test() {
  use port <- serve(on_demand(pieces_of(0)), "rg_read_chunk_zero")
  let #(_, _, body) = post(port, <<"abc">>)
  assert body == <<"3">>
}

pub fn read_chunk_zero_already_read_test() {
  use port <- serve(
    roadrunner_gleam.new(pieces_of(-2)),
    "rg_read_chunk_zero_auto",
  )
  let #(_, _, body) = post(port, <<"abc">>)
  assert body == <<"3">>
}

// After the last piece, reading again gives an empty last piece, however
// the body was read.
pub fn read_after_last_test() {
  let handler = fn(req) {
    let assert Ok(request.Last(data, next)) = request.read_chunk(req, 100)
    let assert Ok(request.Last(again, _)) = request.read_chunk(next, 100)
    response.text(to_string(data) <> "/" <> to_string(again))
  }
  use port <- serve(roadrunner_gleam.new(handler), "rg_read_after_last")
  let #(_, _, body) = post(port, <<"abc">>)
  assert body == <<"abc/">>
  use port <- serve(on_demand(handler), "rg_read_after_last_demand")
  let #(_, _, body) = post(port, <<"abc">>)
  assert body == <<"abc/">>
}

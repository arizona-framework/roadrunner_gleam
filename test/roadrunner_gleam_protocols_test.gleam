//// The same handlers over HTTP/2 and HTTP/3, through curl.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string
import roadrunner_gleam
import roadrunner_gleam/push
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}

// --- helpers --------------------------------------------------------

type Protocol {
  H2
  H3
}

fn handler(request: Request) -> Response {
  case request.path_segments(request) {
    ["version"] -> response.text(string.inspect(request.http_version(request)))
    ["chunked"] ->
      response.new(200)
      |> http_response.set_body(
        response.Chunked(fn(sender) {
          let _ = response.send_chunk(sender, bytes_tree.from_string("one "))
          let _ = response.send_chunk(sender, bytes_tree.from_string("two"))
          Nil
        }),
      )
    ["push"] ->
      // `on_init` sends the response one message, which the handler answers
      // and stops on.
      push.new(
        on_init: fn(subject) {
          process.send(subject, Nil)
          push.continue(Nil) |> push.send(bytes_tree.from_string("first "))
        },
        handler: fn(state, _) {
          push.stop(state) |> push.send(bytes_tree.from_string("last"))
        },
      )
      |> push.response(200)
    ["pieces"] -> {
      let assert Ok(pieces) = read_pieces(request, [])
      response.text(string.join(pieces, "|"))
    }
    ["file"] -> {
      let assert Ok(body) = response.file("gleam.toml")
      response.new(200) |> http_response.set_body(body)
    }
    _ -> response.new(404)
  }
}

fn read_pieces(
  request: Request,
  pieces: List(String),
) -> Result(List(String), request.ReadError) {
  case request.read_chunk(request, 4) {
    Ok(request.More(data, next)) ->
      read_pieces(next, [to_string(data), ..pieces])
    Ok(request.Last(data, _)) -> Ok(list.reverse([to_string(data), ..pieces]))
    Error(error) -> Error(error)
  }
}

fn to_string(data: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(data)
  text
}

/// A TLS listener on port 0 serving HTTP/1.1, HTTP/2 and HTTP/3, handing
/// the test its TCP port and the UDP port HTTP/3 got.
fn serve(name: String, test_body: fn(Int, Int) -> a) -> a {
  let #(certfile, keyfile) = write_cert("build/test_tls")
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(handler)
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> roadrunner_gleam.tls(certfile:, keyfile:)
    |> roadrunner_gleam.http3
    |> roadrunner_gleam.read_body_on_demand
    |> roadrunner_gleam.start
  let assert Ok(quic_port) = roadrunner_gleam.listener_quic_port(listener)
  let result = test_body(roadrunner_gleam.listener_port(listener), quic_port)
  roadrunner_gleam.stop(listener)
  result
}

/// The response body from one request. HTTP/3 goes through
/// `h3_request`, which picks a client that can speak it.
fn fetch(
  protocol: Protocol,
  port: Int,
  path: String,
  method: String,
  body: String,
) -> String {
  case protocol {
    H2 -> {
      let url = "https://127.0.0.1:" <> int.to_string(port) <> path
      let data = case body {
        "" -> []
        _ -> ["--data-binary", body]
      }
      let method = case method {
        "HEAD" -> ["-I"]
        _ -> ["-X", method]
      }
      to_string(
        curl(list.flatten([["-s", "-k", "--http2"], method, data, [url]])),
      )
    }
    H3 -> to_string(h3_request(port, path, method, <<body:utf8>>))
  }
}

@external(erlang, "roadrunner_gleam_test_ffi", "h3_request")
fn h3_request(
  port: Int,
  path: String,
  method: String,
  body: BitArray,
) -> BitArray

@external(erlang, "roadrunner_gleam_test_ffi", "curl")
fn curl(args: List(String)) -> BitArray

@external(erlang, "roadrunner_gleam_test_ffi", "write_cert")
fn write_cert(dir: String) -> #(String, String)

fn each_protocol(name: String, check: fn(Protocol, Int) -> Nil) -> Nil {
  use tcp_port, quic_port <- serve(name)
  check(H2, tcp_port)
  check(H3, quic_port)
}

// --- tests ----------------------------------------------------------

pub fn version_test() {
  use protocol, port <- each_protocol("rg_proto_version")
  let expected = case protocol {
    H2 -> "Http2"
    H3 -> "Http3"
  }
  assert fetch(protocol, port, "/version", "GET", "") == expected
}

pub fn chunked_test() {
  use protocol, port <- each_protocol("rg_proto_chunked")
  assert fetch(protocol, port, "/chunked", "GET", "") == "one two"
}

pub fn push_test() {
  use protocol, port <- each_protocol("rg_proto_push")
  assert fetch(protocol, port, "/push", "GET", "") == "first last"
}

pub fn read_chunk_test() {
  use protocol, port <- each_protocol("rg_proto_pieces")
  assert fetch(protocol, port, "/pieces", "POST", "hello world")
    == "hell|o wo|rld"
}

pub fn file_test() {
  use protocol, port <- each_protocol("rg_proto_file")
  let assert Ok(contents) = read_file("gleam.toml")
  assert fetch(protocol, port, "/file", "GET", "") == to_string(contents)
}

// HTTP/2 only: curl prints the response headers for `HEAD`, while quiche
// prints nothing at all, so there is nothing to check over HTTP/3.
pub fn head_chunked_test() {
  use port, _ <- serve("rg_proto_head")
  let url = "https://127.0.0.1:" <> int.to_string(port) <> "/chunked"
  let output = to_string(curl(["-s", "-k", "--http2", "-I", url]))
  assert string.starts_with(output, "HTTP/2 200")
  assert !string.contains(string.lowercase(output), "content-length")
  assert !string.contains(output, "one two")
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Nil)

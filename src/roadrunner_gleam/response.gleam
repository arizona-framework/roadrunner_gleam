//// The response a handler returns: a `gleam/http` response whose body is
//// a `Body`. Build it with `gleam/http/response`, as in
//// `response.new(200) |> response.set_body(Bytes(...))`, or with the
//// helpers here.

import gleam/bytes_tree.{type BytesTree}
import gleam/http/response as http_response
import gleam/string_tree.{type StringTree}

/// The response a handler returns. `gleam/http/response`'s functions work on
/// it, such as `set_header`, `prepend_header`, `set_cookie` and `redirect`.
pub type Response =
  http_response.Response(Body)

/// What a response sends after its headers.
pub type Body {
  /// A complete body. `content-length` is set from its size unless the
  /// headers already have one.
  Bytes(BytesTree)
  /// `length` bytes of a file, starting at `offset`, sent by the kernel
  /// without copying them into the BEAM. `content-length` is set to
  /// `length` unless the headers already have one. Set `content-type`
  /// yourself. A range that runs past the end of the file fails the
  /// request with a `500`.
  File(path: String, offset: Int, length: Int)
  /// A body sent in parts. Roadrunner calls the function with a `Sender`;
  /// send each part with `send_chunk`. The body ends when the function
  /// returns. A `HEAD` request gets the headers only, and the function is
  /// not called.
  Chunked(fn(Sender) -> Nil)
  /// A WebSocket upgrade, made with `websocket.upgrade`.
  WebSocket(Upgrade)
  /// A body that stays open and pushes data, made with `push.response`.
  Push(PushBody)
}

/// A pushing body, made with `push.response`.
pub type PushBody

/// A WebSocket session to upgrade to, made with `websocket.upgrade`.
pub type Upgrade

/// Sends the parts of a `Chunked` body.
pub type Sender

/// A response with an empty body.
pub fn new(status: Int) -> Response {
  http_response.new(status)
  |> http_response.set_body(Bytes(bytes_tree.new()))
}

/// A `200` response with a `text/plain` body.
pub fn text(body: String) -> Response {
  new(200)
  |> http_response.set_header("content-type", "text/plain; charset=utf-8")
  |> http_response.set_body(Bytes(bytes_tree.from_string(body)))
}

/// A `200` response with a `text/html` body.
pub fn html(body: StringTree) -> Response {
  new(200)
  |> http_response.set_header("content-type", "text/html; charset=utf-8")
  |> http_response.set_body(Bytes(bytes_tree.from_string_tree(body)))
}

/// A `200` response with an `application/json` body.
pub fn json(body: StringTree) -> Response {
  new(200)
  |> http_response.set_header("content-type", "application/json")
  |> http_response.set_body(Bytes(bytes_tree.from_string_tree(body)))
}

/// A `File` body with the whole file. Fails when the path is not a regular
/// file that can be read.
pub fn file(path: String) -> Result(Body, Nil) {
  case file_size(path) {
    Ok(length) -> Ok(File(path:, offset: 0, length:))
    Error(Nil) -> Error(Nil)
  }
}

@external(erlang, "roadrunner_gleam_ffi", "file_size")
fn file_size(path: String) -> Result(Int, Nil)

/// Send one part of a `Chunked` body. Fails when the connection is gone,
/// after which the function should return. Call it only from the function
/// roadrunner called: from another process it can wait forever on an
/// HTTP/2 connection that went away.
@external(erlang, "roadrunner_gleam_ffi", "send_chunk")
pub fn send_chunk(sender: Sender, data: BytesTree) -> Result(Nil, Nil)

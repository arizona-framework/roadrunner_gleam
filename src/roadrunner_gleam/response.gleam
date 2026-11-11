//// The response a handler returns.

import gleam/bytes_tree.{type BytesTree}
import gleam/http/response as http_response
import gleam/list
import gleam/string
import gleam/string_tree.{type StringTree}

/// An HTTP response. Header names must be lowercase, as HTTP/2 and HTTP/3
/// require; `set_header` and `prepend_header` lowercase them for you.
pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: Body)
}

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
  Response(status:, headers: [], body: Bytes(bytes_tree.new()))
}

/// Set a header, replacing any with the same name. The name is lowercased,
/// as HTTP/2 and HTTP/3 require.
pub fn set_header(response: Response, name: String, value: String) -> Response {
  let name = string.lowercase(name)
  let headers = list.filter(response.headers, fn(header) { header.0 != name })
  Response(..response, headers: [#(name, value), ..headers])
}

/// Add a header, keeping any with the same name, for headers that can
/// repeat such as `set-cookie`. The name is lowercased.
pub fn prepend_header(
  response: Response,
  name: String,
  value: String,
) -> Response {
  let name = string.lowercase(name)
  Response(..response, headers: [#(name, value), ..response.headers])
}

/// Set the body.
pub fn set_body(response: Response, body: Body) -> Response {
  Response(..response, body:)
}

/// A `200` response with a `text/plain` body.
pub fn text(body: String) -> Response {
  new(200)
  |> set_header("content-type", "text/plain; charset=utf-8")
  |> set_body(Bytes(bytes_tree.from_string(body)))
}

/// A `200` response with a `text/html` body.
pub fn html(body: StringTree) -> Response {
  new(200)
  |> set_header("content-type", "text/html; charset=utf-8")
  |> set_body(Bytes(bytes_tree.from_string_tree(body)))
}

/// A `200` response with an `application/json` body.
pub fn json(body: StringTree) -> Response {
  new(200)
  |> set_header("content-type", "application/json")
  |> set_body(Bytes(bytes_tree.from_string_tree(body)))
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

/// Build a response from a `gleam/http` response.
pub fn from_http(response: http_response.Response(BytesTree)) -> Response {
  Response(
    status: response.status,
    headers: response.headers,
    body: Bytes(response.body),
  )
}

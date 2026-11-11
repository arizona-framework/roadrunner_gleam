//// WebSocket sessions.
////
//// A handler upgrades a request by returning `upgrade(builder)`. The
//// session then runs in the connection's process: `on_init` runs once
//// after the handshake, `handler` gets every message, and `on_close` runs
//// when the session ends.
////
//// ```gleam
//// fn handle(request: Request) -> Response {
////   case request.path_segments(request) {
////     ["ws"] ->
////       websocket.new(
////         on_init: fn(_subject) { websocket.continue(Nil) },
////         handler: fn(state, message) {
////           case message {
////             websocket.Text(text) ->
////               websocket.continue(state)
////               |> websocket.send([websocket.TextFrame(text)])
////             _ -> websocket.continue(state)
////           }
////         },
////       )
////       |> websocket.upgrade
////     _ -> response.new(404)
////   }
//// }
//// ```
////
//// Roadrunner serves WebSocket over HTTP/1.1. An upgrade asked over
//// HTTP/2 or HTTP/3 is answered `501`.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/response as http_response
import gleam/list
import gleam/option.{type Option, None, Some}
import roadrunner_gleam/response.{type Response}

/// What the handler gets.
pub type Message(custom) {
  /// A text message from the client.
  Text(String)
  /// A binary message from the client.
  Binary(BitArray)
  /// A message sent to the `Subject` that `on_init` got, or one selected by
  /// `with_selector`.
  Custom(custom)
  /// The listener is draining: close the session within `remaining`
  /// milliseconds, or it is closed for you.
  Draining(remaining: Int)
}

/// A frame to send to the client.
pub type Frame {
  TextFrame(String)
  BinaryFrame(BitArray)
  PingFrame(BitArray)
}

/// What to do after a callback, built with `continue` or `close` and the
/// functions that follow them.
pub opaque type Next(state, custom) {
  Continue(
    state: state,
    frames: List(Frame),
    selector: Option(Selector(custom)),
  )
  Close(state: state, frames: List(Frame), code: Int, reason: String)
}

/// Why the session ended.
pub type CloseReason {
  /// The handler closed it.
  Normal
  /// The client sent a close frame.
  Remote
  /// The handler closed it while the listener drained.
  Shutdown
  /// The client sent nothing for the session's `idle_timeout`.
  Timeout
  /// The connection or the client failed.
  Failed(String)
}

/// Keep the session open.
pub fn continue(state: state) -> Next(state, custom) {
  Continue(state:, frames: [], selector: None)
}

/// Close the session normally, with code 1000.
pub fn close(state: state) -> Next(state, custom) {
  close_with(state, code: 1000, reason: "")
}

/// Close the session with a close code and a reason. `code` must be one a
/// server may send: 1000 to 1003, 1007 to 1014, or 3000 to 4999. `reason`
/// must be at most 123 bytes.
pub fn close_with(
  state: state,
  code code: Int,
  reason reason: String,
) -> Next(state, custom) {
  Close(state:, frames: [], code:, reason:)
}

/// Send these frames to the client, before the close frame when closing.
pub fn send(
  next: Next(state, custom),
  frames: List(Frame),
) -> Next(state, custom) {
  case next {
    Continue(..) -> Continue(..next, frames: list.append(next.frames, frames))
    Close(..) -> Close(..next, frames: list.append(next.frames, frames))
  }
}

/// Also receive the messages this selector selects, as `Custom`, from now
/// on: monitors, messages to other subjects, or anything else. It replaces
/// the selector set before; messages to the session's `Subject` always
/// arrive.
pub fn with_selector(
  next: Next(state, custom),
  selector: Selector(custom),
) -> Next(state, custom) {
  case next {
    Continue(..) -> Continue(..next, selector: Some(selector))
    Close(..) -> next
  }
}

/// A WebSocket session, built with `new` and the functions that follow it.
pub opaque type Builder(state, custom) {
  Builder(
    on_init: fn(Subject(custom)) -> Next(state, custom),
    handler: fn(state, Message(custom)) -> Next(state, custom),
    on_close: fn(state, CloseReason) -> Nil,
    options: Dict(Atom, Dynamic),
  )
}

/// A session. `on_init` gets a `Subject` owned by the session: messages
/// sent to it reach `handler` as `Custom`, so other processes can push to
/// the client through it.
pub fn new(
  on_init on_init: fn(Subject(custom)) -> Next(state, custom),
  handler handler: fn(state, Message(custom)) -> Next(state, custom),
) -> Builder(state, custom) {
  Builder(on_init:, handler:, on_close: fn(_, _) { Nil }, options: dict.new())
}

/// Run `on_close` when the session ends in an orderly way. It does not run
/// when a callback crashes.
pub fn on_close(
  builder: Builder(state, custom),
  on_close: fn(state, CloseReason) -> Nil,
) -> Builder(state, custom) {
  Builder(..builder, on_close:)
}

/// Close the session, with code 1001, when the client sends nothing for
/// this many milliseconds.
pub fn idle_timeout(
  builder: Builder(state, custom),
  milliseconds: Int,
) -> Builder(state, custom) {
  option(builder, "idle_timeout", dynamic.int(milliseconds))
}

/// Whether to accept the client's offer to compress messages
/// (permessage-deflate). Defaults to the listener's `ws` option.
pub fn compress(
  builder: Builder(state, custom),
  compress: Bool,
) -> Builder(state, custom) {
  option(builder, "compress", dynamic.bool(compress))
}

/// The largest message, in bytes, the client may send.
pub fn max_message_size(
  builder: Builder(state, custom),
  bytes: Int,
) -> Builder(state, custom) {
  option(builder, "max_message_size", dynamic.int(bytes))
}

/// The largest frame, in bytes, the client may send.
pub fn max_frame_size(
  builder: Builder(state, custom),
  bytes: Int,
) -> Builder(state, custom) {
  option(builder, "max_frame_size", dynamic.int(bytes))
}

/// Hibernate the session after this many milliseconds without messages,
/// which saves memory on mostly idle sessions.
pub fn hibernate_after(
  builder: Builder(state, custom),
  milliseconds: Int,
) -> Builder(state, custom) {
  option(builder, "hibernate_after", dynamic.int(milliseconds))
}

fn option(
  builder: Builder(state, custom),
  name: String,
  value: Dynamic,
) -> Builder(state, custom) {
  let options = dict.insert(builder.options, atom.create(name), value)
  Builder(..builder, options:)
}

/// The response that upgrades the request to the session. Headers set on
/// it with `gleam/http/response.set_header` go on the `101 Switching Protocols`
/// response, such as a `set-cookie`.
pub fn upgrade(builder: Builder(state, custom)) -> Response {
  http_response.Response(
    status: 101,
    headers: [],
    body: response.WebSocket(to_upgrade(builder)),
  )
}

@external(erlang, "roadrunner_gleam_ffi", "identity")
fn to_upgrade(builder: Builder(state, custom)) -> response.Upgrade

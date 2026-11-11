//// Responses that stay open and push data as messages arrive, such as
//// server-sent events.
////
//// The response's headers go out first. Then the handler runs for every
//// message sent to the `Subject` that `on_init` got, and can push data to
//// the client, until it returns `Stop` or the client goes away. It works
//// the same over HTTP/1.1, HTTP/2 and HTTP/3. A `HEAD` request gets the
//// headers only, and `on_init` is not called.
////
//// ```gleam
//// fn events(request: Request) -> Response {
////   push.new(
////     on_init: fn(subject) {
////       pubsub.subscribe(subject)
////       Nil
////     },
////     handler: fn(state, message, pusher) {
////       case message {
////         push.Custom(text) -> {
////           let _ = push.push(pusher, push.event(text))
////           push.Continue(state)
////         }
////         push.Draining(_) -> push.Stop(state)
////       }
////     },
////   )
////   |> push.response(200)
////   |> http_response.set_header("content-type", "text/event-stream")
//// }
//// ```

import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Subject}
import gleam/http/response as http_response
import gleam/list
import gleam/string
import roadrunner_gleam/response.{type Response}

/// What the handler gets.
pub type Message(custom) {
  /// A message sent to the `Subject` that `on_init` got.
  Custom(custom)
  /// The listener is draining: stop within `remaining` milliseconds, or
  /// the response is closed for you.
  Draining(remaining: Int)
}

/// What to do after the handler.
pub type Next(state) {
  /// Keep the response open.
  Continue(state)
  /// End the response.
  Stop(state)
}

/// Pushes data to the client.
pub type Pusher

/// A response that pushes, built with `new` and the functions that follow
/// it.
pub opaque type Builder(state, custom) {
  Builder(
    on_init: fn(Subject(custom)) -> state,
    handler: fn(state, Message(custom), Pusher) -> Next(state),
    on_disconnect: fn(state) -> Nil,
  )
}

/// A response that pushes. `on_init` runs once, before the headers go out,
/// and gets a `Subject` owned by the response: messages sent to it reach
/// `handler` as `Custom`.
pub fn new(
  on_init on_init: fn(Subject(custom)) -> state,
  handler handler: fn(state, Message(custom), Pusher) -> Next(state),
) -> Builder(state, custom) {
  Builder(on_init:, handler:, on_disconnect: fn(_) { Nil })
}

/// Run `on_disconnect` when the client goes away before the handler
/// stops, to drop subscriptions and stop work.
pub fn on_disconnect(
  builder: Builder(state, custom),
  on_disconnect: fn(state) -> Nil,
) -> Builder(state, custom) {
  Builder(..builder, on_disconnect:)
}

/// The response, with this status. Add headers with
/// `gleam/http/response.set_header`.
pub fn response(builder: Builder(state, custom), status: Int) -> Response {
  http_response.Response(
    status:,
    headers: [],
    body: response.Push(to_push_body(builder)),
  )
}

/// Send data to the client. Fails when the client is gone. Call it only
/// from the handler: from another process it can wait forever on an
/// HTTP/2 connection that went away. Send to the response's `Subject`
/// instead.
@external(erlang, "roadrunner_gleam_ffi", "push")
pub fn push(pusher: Pusher, data: BytesTree) -> Result(Nil, Nil)

/// A server-sent event with this data, ready to push.
pub fn event(data: String) -> BytesTree {
  data_lines(bytes_tree.new(), data)
  |> bytes_tree.append_string("\n")
}

/// A server-sent event with a name, which the browser's `EventSource`
/// delivers to listeners of that name.
pub fn named_event(name: String, data: String) -> BytesTree {
  bytes_tree.from_string("event: " <> name <> "\n")
  |> data_lines(data)
  |> bytes_tree.append_string("\n")
}

// Each line of the data goes on its own `data:` line.
fn data_lines(tree: BytesTree, data: String) -> BytesTree {
  string.split(data, "\n")
  |> list.fold(tree, fn(tree, line) {
    bytes_tree.append_string(tree, "data: " <> line <> "\n")
  })
}

@external(erlang, "roadrunner_gleam_ffi", "identity")
fn to_push_body(builder: Builder(state, custom)) -> response.PushBody

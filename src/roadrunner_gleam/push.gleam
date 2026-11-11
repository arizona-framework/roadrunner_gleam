//// Responses that stay open and push data as messages arrive, such as
//// server-sent events.
////
//// The response's headers go out first, then whatever `on_init` sends.
//// After that the handler runs for every message sent to the `Subject`
//// that `on_init` got, or selected with `with_selector`, and sends data to
//// the client, until it stops or the client goes away. It works the same
//// over HTTP/1.1, HTTP/2 and HTTP/3. A `HEAD` request gets the headers
//// only, and `on_init` is not called.
////
//// ```gleam
//// fn events(request: Request) -> Response {
////   push.new(
////     on_init: fn(subject) {
////       pubsub.subscribe(subject)
////       push.continue(Nil)
////       |> push.send_event(push.event("connected") |> push.event_retry(5000))
////     },
////     handler: fn(state, message) {
////       case message {
////         push.Custom(text) ->
////           push.continue(state) |> push.send_event(push.event(text))
////         push.Draining(_) -> push.stop(state)
////       }
////     },
////   )
////   |> push.response(200)
////   |> http_response.set_header("content-type", "text/event-stream")
//// }
//// ```

import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import roadrunner_gleam/response.{type Response}

/// What the handler gets.
pub type Message(custom) {
  /// A message sent to the `Subject` that `on_init` got, or one selected by
  /// `with_selector`.
  Custom(custom)
  /// The listener is draining: stop within `remaining` milliseconds, or
  /// the response is closed for you.
  Draining(remaining: Int)
}

/// What to do after a callback, built with `continue` or `stop` and the
/// functions that follow them.
pub opaque type Next(state, custom) {
  Continue(
    state: state,
    data: List(BytesTree),
    selector: Option(Selector(custom)),
  )
  Stop(state: state, data: List(BytesTree))
}

/// Keep the response open.
pub fn continue(state: state) -> Next(state, custom) {
  Continue(state:, data: [], selector: None)
}

/// End the response, after sending what was given to `send`.
pub fn stop(state: state) -> Next(state, custom) {
  Stop(state:, data: [])
}

/// Send this data to the client after the callback.
pub fn send(next: Next(state, custom), data: BytesTree) -> Next(state, custom) {
  case next {
    Continue(..) -> Continue(..next, data: list.append(next.data, [data]))
    Stop(..) -> Stop(..next, data: list.append(next.data, [data]))
  }
}

/// Send a server-sent event to the client after the callback.
pub fn send_event(
  next: Next(state, custom),
  event: Event,
) -> Next(state, custom) {
  send(next, event_to_bytes(event))
}

/// Also receive the messages this selector selects, as `Custom`, from now
/// on: monitors, messages to other subjects, or anything else. It replaces
/// the selector set before; messages to the response's `Subject` always
/// arrive.
pub fn with_selector(
  next: Next(state, custom),
  selector: Selector(custom),
) -> Next(state, custom) {
  case next {
    Continue(..) -> Continue(..next, selector: Some(selector))
    Stop(..) -> next
  }
}

/// A response that pushes, built with `new` and the functions that follow
/// it.
pub opaque type Builder(state, custom) {
  Builder(
    on_init: fn(Subject(custom)) -> Next(state, custom),
    handler: fn(state, Message(custom)) -> Next(state, custom),
    on_disconnect: fn(state) -> Nil,
  )
}

/// A response that pushes. `on_init` runs once, before the headers go out,
/// and gets a `Subject` owned by the response: messages sent to it reach
/// `handler` as `Custom`. What it sends goes out right after the headers.
pub fn new(
  on_init on_init: fn(Subject(custom)) -> Next(state, custom),
  handler handler: fn(state, Message(custom)) -> Next(state, custom),
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

@external(erlang, "roadrunner_gleam_ffi", "identity")
fn to_push_body(builder: Builder(state, custom)) -> response.PushBody

/// A server-sent event, built with `event` and the functions that follow
/// it.
pub opaque type Event {
  Event(
    data: String,
    name: Option(String),
    id: Option(String),
    retry: Option(Int),
  )
}

/// A server-sent event with this data. Data with line breaks is sent as
/// several `data:` lines, which the browser joins back.
pub fn event(data: String) -> Event {
  Event(data:, name: None, id: None, retry: None)
}

/// The event's name: the browser's `EventSource` delivers it to the
/// listeners of that name instead of `onmessage`.
pub fn event_name(event: Event, name: String) -> Event {
  Event(..event, name: Some(name))
}

/// The event's id, which the browser sends back as `last-event-id` when it
/// reconnects.
pub fn event_id(event: Event, id: String) -> Event {
  Event(..event, id: Some(id))
}

/// How many milliseconds the browser waits before reconnecting.
pub fn event_retry(event: Event, milliseconds: Int) -> Event {
  Event(..event, retry: Some(milliseconds))
}

/// The event as it goes on the wire.
pub fn event_to_bytes(event: Event) -> BytesTree {
  let tree =
    bytes_tree.new()
    |> field("event", event.name)
    |> field("id", event.id)
    |> field("retry", option.map(event.retry, int.to_string))
  string.split(event.data, "\n")
  |> list.fold(tree, fn(tree, line) {
    bytes_tree.append_string(tree, "data: " <> line <> "\n")
  })
  |> bytes_tree.append_string("\n")
}

fn field(tree: BytesTree, name: String, value: Option(String)) -> BytesTree {
  case value {
    Some(value) -> bytes_tree.append_string(tree, name <> ": " <> value <> "\n")
    None -> tree
  }
}

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import roadrunner_gleam
import roadrunner_gleam/push
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}

// --- helpers --------------------------------------------------------

type Socket

fn serve(
  name: String,
  handler: fn(Request) -> Response,
  test_body: fn(roadrunner_gleam.Listener, String) -> a,
) -> a {
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(handler)
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> roadrunner_gleam.start
  let port = roadrunner_gleam.listener_port(listener)
  test_body(listener, "http://127.0.0.1:" <> int.to_string(port))
}

/// Run a GET in another process, as it only returns once the response
/// ends, and get its body back through the returned subject.
fn get_later(url: String) -> Subject(BitArray) {
  let result = process.new_subject()
  process.spawn(fn() {
    let #(_, _, body) = http_call(atom.create("get"), url, [], <<>>)
    process.send(result, body)
  })
  result
}

@external(erlang, "roadrunner_gleam_test_ffi", "request")
fn http_call(
  method: Atom,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray)

@external(erlang, "roadrunner_gleam_test_ffi", "open_get")
fn open_get(port: Int, path: String) -> Socket

@external(erlang, "roadrunner_gleam_test_ffi", "ws_close")
fn close(socket: Socket) -> Nil

/// Pushes every `Custom` text until it gets "stop", and stops on drain.
fn pushing(self: Subject(Subject(String))) -> Response {
  push.new(
    on_init: fn(subject) {
      process.send(self, subject)
      push.continue(Nil)
    },
    handler: fn(state, message) {
      case message {
        push.Custom("stop") -> push.stop(state)
        push.Custom(text) ->
          push.continue(state) |> push.send(bytes_tree.from_string(text))
        push.Draining(_) ->
          push.stop(state) |> push.send(bytes_tree.from_string("bye"))
      }
    },
  )
  |> push.response(200)
}

// --- tests ----------------------------------------------------------

pub fn push_test() {
  let self = process.new_subject()
  use listener, url <- serve("rg_push", fn(_) { pushing(self) })
  let body = get_later(url)
  let assert Ok(session) = process.receive(self, 1000)
  process.send(session, "one ")
  process.send(session, "two")
  process.send(session, "stop")
  assert process.receive(body, 5000) == Ok(<<"one two">>)
  roadrunner_gleam.stop(listener)
}

pub fn draining_test() {
  let self = process.new_subject()
  use listener, url <- serve("rg_push_drain", fn(_) { pushing(self) })
  let body = get_later(url)
  let assert Ok(session) = process.receive(self, 1000)
  process.send(session, "hello ")
  assert roadrunner_gleam.drain(listener, 5000) == Ok(Nil)
  assert process.receive(body, 5000) == Ok(<<"hello bye">>)
}

pub fn on_disconnect_test() {
  let self = process.new_subject()
  use listener, _ <- serve("rg_push_disconnect", fn(_) {
    push.new(
      on_init: fn(_: Subject(Nil)) {
        process.send(self, "init")
        push.continue("state")
      },
      handler: fn(state, _) { push.continue(state) },
    )
    |> push.on_disconnect(fn(state) { process.send(self, state) })
    |> push.response(200)
  })
  let socket = open_get(roadrunner_gleam.listener_port(listener), "/")
  assert process.receive(self, 1000) == Ok("init")
  close(socket)
  assert process.receive(self, 5000) == Ok("state")
  roadrunner_gleam.stop(listener)
}

pub fn on_init_sends_and_stops_test() {
  use listener, url <- serve("rg_push_init_stop", fn(_) {
    push.new(
      on_init: fn(_: Subject(Nil)) {
        push.stop(Nil)
        |> push.send_event(push.event("only") |> push.event_retry(10))
      },
      handler: fn(state, _) { push.continue(state) },
    )
    |> push.response(200)
  })
  assert process.receive(get_later(url), 5000)
    == Ok(<<"retry: 10\ndata: only\n\n">>)
  roadrunner_gleam.stop(listener)
}

pub fn selector_test() {
  let self = process.new_subject()
  use listener, url <- serve("rg_push_selector", fn(_) {
    push.new(
      on_init: fn(_: Subject(String)) {
        // A worker the response monitors; its exit arrives through the
        // selector.
        let worker = process.spawn_unlinked(fn() { process.sleep(50) })
        let monitor = process.monitor(worker)
        process.send(self, Nil)
        push.continue(Nil)
        |> push.with_selector(
          process.new_selector()
          |> process.select_specific_monitor(monitor, fn(_) { "worker done" }),
        )
      },
      handler: fn(state, message) {
        case message {
          push.Custom(text) ->
            push.stop(state) |> push.send(bytes_tree.from_string(text))
          push.Draining(_) -> push.stop(state)
        }
      },
    )
    |> push.response(200)
  })
  let body = get_later(url)
  let assert Ok(Nil) = process.receive(self, 1000)
  assert process.receive(body, 5000) == Ok(<<"worker done">>)
  roadrunner_gleam.stop(listener)
}

pub fn event_test() {
  assert bytes_tree.to_bit_array(push.event_to_bytes(push.event("hi")))
    == <<"data: hi\n\n">>
  assert bytes_tree.to_bit_array(push.event_to_bytes(push.event("a\nb")))
    == <<"data: a\ndata: b\n\n">>
  let event =
    push.event("1")
    |> push.event_name("tick")
    |> push.event_id("7")
    |> push.event_retry(3000)
  assert bit_array.to_string(
      bytes_tree.to_bit_array(push.event_to_bytes(event)),
    )
    == Ok("event: tick\nid: 7\nretry: 3000\ndata: 1\n\n")
}

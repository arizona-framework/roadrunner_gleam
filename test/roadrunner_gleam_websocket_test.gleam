import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Subject}
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/otp/actor
import roadrunner_gleam.{type Listener}
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}
import roadrunner_gleam/websocket

// --- helpers --------------------------------------------------------

type Socket

fn serve(
  name: String,
  handler: fn(Request) -> Response,
  test_body: fn(Listener, Int) -> a,
) -> a {
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(handler)
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> roadrunner_gleam.start
  test_body(listener, roadrunner_gleam.listener_port(listener))
}

fn send_text(socket: Socket, text: String) -> Nil {
  ws_send(socket, atom.create("text"), <<text:utf8>>)
}

@external(erlang, "roadrunner_gleam_test_ffi", "ws_connect")
fn ws_connect(port: Int, path: String) -> #(Socket, List(#(String, String)))

@external(erlang, "roadrunner_gleam_test_ffi", "ws_send")
fn ws_send(socket: Socket, opcode: Atom, payload: BitArray) -> Nil

@external(erlang, "roadrunner_gleam_test_ffi", "ws_recv")
fn ws_recv(socket: Socket) -> #(Atom, BitArray)

@external(erlang, "roadrunner_gleam_test_ffi", "ws_close")
fn ws_close(socket: Socket) -> Nil

fn text_frame(text: String) -> #(Atom, BitArray) {
  #(atom.create("text"), <<text:utf8>>)
}

fn close_frame(code: Int, reason: String) -> #(Atom, BitArray) {
  #(atom.create("close"), <<code:16, reason:utf8>>)
}

/// Echoes text and binary messages, and closes on "bye".
fn echo_session() -> Response {
  websocket.new(
    on_init: fn(_) { websocket.continue(Nil) },
    handler: fn(state, message) {
      case message {
        websocket.Text("bye") ->
          websocket.close_with(state, code: 4000, reason: "done")
          |> websocket.send([websocket.TextFrame("ciao")])
        websocket.Text(text) ->
          websocket.continue(state)
          |> websocket.send([websocket.TextFrame(text)])
        websocket.Binary(data) ->
          websocket.continue(state)
          |> websocket.send([websocket.BinaryFrame(data)])
        _ -> websocket.continue(state)
      }
    },
  )
  |> websocket.upgrade
}

// --- tests ----------------------------------------------------------

pub fn echo_test() {
  use listener, port <- serve("rg_ws_echo", fn(_) { echo_session() })
  let #(socket, _) = ws_connect(port, "/")
  send_text(socket, "hello")
  assert ws_recv(socket) == text_frame("hello")
  ws_send(socket, atom.create("binary"), <<1, 2, 3>>)
  assert ws_recv(socket) == #(atom.create("binary"), <<1, 2, 3>>)
  ws_close(socket)
  roadrunner_gleam.stop(listener)
}

pub fn close_test() {
  use listener, port <- serve("rg_ws_close", fn(_) { echo_session() })
  let #(socket, _) = ws_connect(port, "/")
  send_text(socket, "bye")
  assert ws_recv(socket) == text_frame("ciao")
  assert ws_recv(socket) == close_frame(4000, "done")
  ws_close(socket)
  roadrunner_gleam.stop(listener)
}

pub fn on_init_frames_and_headers_test() {
  use listener, port <- serve("rg_ws_init", fn(_) {
    websocket.new(
      on_init: fn(_) {
        websocket.continue(0)
        |> websocket.send([websocket.TextFrame("ready")])
      },
      handler: fn(count, _) { websocket.continue(count + 1) },
    )
    |> websocket.upgrade
    |> http_response.set_header("set-cookie", "session=1")
  })
  let #(socket, headers) = ws_connect(port, "/")
  assert list.key_find(headers, "set-cookie") == Ok("session=1")
  assert ws_recv(socket) == text_frame("ready")
  ws_close(socket)
  roadrunner_gleam.stop(listener)
}

pub fn custom_message_test() {
  let self = process.new_subject()
  use listener, port <- serve("rg_ws_custom", fn(_) {
    websocket.new(
      on_init: fn(subject) {
        process.send(self, subject)
        websocket.continue(Nil)
      },
      handler: fn(state, message) {
        case message {
          websocket.Custom(text) ->
            websocket.continue(state)
            |> websocket.send([websocket.TextFrame(text)])
          _ -> websocket.continue(state)
        }
      },
    )
    |> websocket.upgrade
  })
  let #(socket, _) = ws_connect(port, "/")
  let assert Ok(session): Result(Subject(String), Nil) =
    process.receive(self, 1000)
  process.send(session, "pushed")
  assert ws_recv(socket) == text_frame("pushed")
  ws_close(socket)
  roadrunner_gleam.stop(listener)
}

pub fn on_close_test() {
  let self = process.new_subject()
  use listener, port <- serve("rg_ws_on_close", fn(_) {
    websocket.new(
      on_init: fn(_) { websocket.continue("state") },
      handler: fn(state, _) { websocket.continue(state) },
    )
    |> websocket.on_close(fn(state, reason) {
      process.send(self, #(state, reason))
    })
    |> websocket.upgrade
  })
  let #(socket, _) = ws_connect(port, "/")
  ws_send(socket, atom.create("close"), <<1000:16>>)
  assert ws_recv(socket) == #(atom.create("close"), <<1000:16>>)
  assert process.receive(self, 1000) == Ok(#("state", websocket.Remote))
  ws_close(socket)
  roadrunner_gleam.stop(listener)
}

pub fn idle_timeout_test() {
  let self = process.new_subject()
  use listener, port <- serve("rg_ws_idle", fn(_) {
    websocket.new(
      on_init: fn(_) { websocket.continue(Nil) },
      handler: fn(state, _) { websocket.continue(state) },
    )
    |> websocket.idle_timeout(50)
    |> websocket.on_close(fn(_, reason) { process.send(self, reason) })
    |> websocket.upgrade
  })
  let #(socket, _) = ws_connect(port, "/")
  let #(opcode, _) = ws_recv(socket)
  assert opcode == atom.create("close")
  assert process.receive(self, 1000) == Ok(websocket.Timeout)
  ws_close(socket)
  roadrunner_gleam.stop(listener)
}

pub fn draining_test() {
  let self = process.new_subject()
  use listener, port <- serve("rg_ws_drain", fn(_) {
    websocket.new(
      on_init: fn(_) {
        process.send(self, Nil)
        websocket.continue(Nil)
      },
      handler: fn(state, message) {
        case message {
          websocket.Draining(_) ->
            websocket.close_with(state, code: 1001, reason: "draining")
          _ -> websocket.continue(state)
        }
      },
    )
    |> websocket.upgrade
  })
  let #(socket, _) = ws_connect(port, "/")
  let assert Ok(Nil) = process.receive(self, 1000)
  let drained = process.new_subject()
  process.spawn(fn() {
    process.send(drained, roadrunner_gleam.drain(listener, 5000))
  })
  assert ws_recv(socket) == close_frame(1001, "draining")
  ws_close(socket)
  assert process.receive(drained, 5000) == Ok(Ok(Nil))
}

pub fn selector_test() {
  use listener, port <- serve("rg_ws_selector", fn(_) {
    websocket.new(
      on_init: fn(_: Subject(String)) {
        // A worker the session monitors; its exit arrives through the
        // selector.
        let worker = process.spawn_unlinked(fn() { process.sleep(50) })
        let monitor = process.monitor(worker)
        websocket.continue(Nil)
        |> websocket.with_selector(
          process.new_selector()
          |> process.select_specific_monitor(monitor, fn(_) { "worker done" }),
        )
      },
      handler: fn(state, message) {
        case message {
          websocket.Custom(text) ->
            websocket.continue(state)
            |> websocket.send([websocket.TextFrame(text)])
          _ -> websocket.continue(state)
        }
      },
    )
    |> websocket.upgrade
  })
  let #(socket, _) = ws_connect(port, "/")
  assert ws_recv(socket) == text_frame("worker done")
  ws_close(socket)
  roadrunner_gleam.stop(listener)
}

// A ping longer than a control frame may carry ends the session instead
// of going out malformed.
pub fn long_ping_test() {
  use listener, port <- serve("rg_ws_long_ping", fn(_) {
    websocket.new(
      on_init: fn(_) { websocket.continue(Nil) },
      handler: fn(state, _) {
        websocket.continue(state)
        |> websocket.send([websocket.PingFrame(<<0:size(126)-unit(8)>>)])
      },
    )
    |> websocket.upgrade
  })
  let #(socket, _) = ws_connect(port, "/")
  send_text(socket, "go")
  assert ws_closed(socket)
  roadrunner_gleam.stop(listener)
}

@external(erlang, "roadrunner_gleam_test_ffi", "ws_closed")
fn ws_closed(socket: Socket) -> Bool

// --- heap floor -----------------------------------------------------

/// A session whose `Custom("alloc")` grows its heap and whose
/// `Custom("report")` answers with the `min_heap_size` it runs at, set up
/// by `configure`. Runs `test_body` with a function that sends a custom
/// message and one that reads the next text frame.
fn heap_session(
  name: String,
  listener: fn(roadrunner_gleam.Builder) -> roadrunner_gleam.Builder,
  configure: fn(websocket.Builder(Nil, String)) ->
    websocket.Builder(Nil, String),
) -> Int {
  let self = process.new_subject()
  let assert Ok(actor.Started(data: server, ..)) =
    roadrunner_gleam.new(fn(_) {
      websocket.new(
        on_init: fn(subject) {
          process.send(self, subject)
          websocket.continue(Nil)
        },
        handler: fn(state, message) {
          case message {
            websocket.Custom("alloc") -> {
              let _ = alloc()
              websocket.continue(state)
              |> websocket.send([websocket.TextFrame("allocated")])
            }
            websocket.Custom(_) ->
              websocket.continue(state)
              |> websocket.send([
                websocket.TextFrame(int.to_string(min_heap_size())),
              ])
            _ -> websocket.continue(state)
          }
        },
      )
      |> configure
      |> websocket.upgrade
    })
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> listener
    |> roadrunner_gleam.start
  let #(socket, _) = ws_connect(roadrunner_gleam.listener_port(server), "/")
  let assert Ok(session): Result(Subject(String), Nil) =
    process.receive(self, 1000)
  process.send(session, "alloc")
  assert ws_recv(socket) == text_frame("allocated")
  process.send(session, "report")
  let #(_, report) = ws_recv(socket)
  let assert Ok(report) = bit_array_to_int(report)
  ws_close(socket)
  roadrunner_gleam.stop(server)
  report
}

fn bit_array_to_int(bits: BitArray) -> Result(Int, Nil) {
  case bit_array.to_string(bits) {
    Ok(text) -> int.parse(text)
    Error(_) -> Error(Nil)
  }
}

pub fn heap_floor_by_default_test() {
  let floor = heap_session("rg_ws_floor_default", fn(b) { b }, fn(b) { b })
  assert floor > default_min_heap_size()
}

pub fn heap_floor_test() {
  let floor =
    heap_session("rg_ws_floor", fn(b) { b }, websocket.heap_floor(
      _,
      max: 1000,
      min: 0,
    ))
  assert floor == rounded_heap_size(1000)
}

pub fn no_heap_floor_test() {
  let floor =
    heap_session("rg_ws_no_floor", fn(b) { b }, websocket.no_heap_floor)
  assert floor == default_min_heap_size()
}

/// The listener's `no_heap_floor` turns it off for sessions too.
pub fn listener_no_heap_floor_test() {
  let floor =
    heap_session(
      "rg_ws_listener_no_floor",
      roadrunner_gleam.no_heap_floor,
      fn(b) { b },
    )
  assert floor == default_min_heap_size()
}

@external(erlang, "roadrunner_gleam_test_ffi", "alloc")
fn alloc() -> Int

@external(erlang, "roadrunner_gleam_test_ffi", "min_heap_size")
fn min_heap_size() -> Int

@external(erlang, "roadrunner_gleam_test_ffi", "default_min_heap_size")
fn default_min_heap_size() -> Int

@external(erlang, "roadrunner_gleam_test_ffi", "rounded_heap_size")
fn rounded_heap_size(words: Int) -> Int

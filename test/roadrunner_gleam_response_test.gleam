import gleam/bit_array
import gleam/dynamic
import gleam/http/response as http_response
import gleam/list
import gleam/otp/actor
import gleam/string
import roadrunner_gleam.{type Builder}
import roadrunner_gleam/push
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

/// The raw response to a request on a connection that closes after it.
fn raw(port: Int, method: String, path: String) -> String {
  let request =
    method
    <> " "
    <> path
    <> " HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n"
  let assert Ok(response) =
    bit_array.to_string(raw_request(port, <<request:utf8>>))
  response
}

@external(erlang, "roadrunner_gleam_test_ffi", "raw_request")
fn raw_request(port: Int, request: BitArray) -> BitArray

fn split_response(response: String) -> #(List(String), String) {
  let assert Ok(#(head, body)) = string.split_once(response, "\r\n\r\n")
  let assert [_status, ..headers] = string.split(head, "\r\n")
  #(headers, body)
}

fn status(response: String) -> String {
  let assert [line, ..] = string.split(response, "\r\n")
  line
}

// --- HEAD -----------------------------------------------------------

fn chunked_or_push(request: Request) -> Response {
  case request.path_segments(request) {
    ["push"] ->
      push.new(
        on_init: fn(_) { panic as "on_init on HEAD" },
        handler: fn(state, _, _) { push.Stop(state) },
      )
      |> push.response(200)
    _ ->
      response.new(200)
      |> http_response.set_body(
        response.Chunked(fn(_) { panic as "stream on HEAD" }),
      )
  }
}

pub fn head_chunked_test() {
  use port <- serve(roadrunner_gleam.new(chunked_or_push), "rg_head_chunked")
  let response = raw(port, "HEAD", "/chunked")
  assert status(response) == "HTTP/1.1 200 OK"
  assert string.ends_with(response, "\r\n\r\n")
}

pub fn head_push_test() {
  use port <- serve(roadrunner_gleam.new(chunked_or_push), "rg_head_push")
  let response = raw(port, "HEAD", "/push")
  assert status(response) == "HTTP/1.1 200 OK"
  assert string.ends_with(response, "\r\n\r\n")
}

// --- files ----------------------------------------------------------

pub fn file_range_past_end_test() {
  let handler = fn(_) {
    response.new(200)
    |> http_response.set_body(response.File(
      path: "gleam.toml",
      offset: 0,
      length: 1_000_000,
    ))
  }
  use port <- serve(roadrunner_gleam.new(handler), "rg_file_past_end")
  assert status(raw(port, "GET", "/")) == "HTTP/1.1 500 Internal Server Error"
}

pub fn file_zero_length_test() {
  let handler = fn(_) {
    response.new(200)
    |> http_response.set_body(response.File(
      path: "gleam.toml",
      offset: 5,
      length: 0,
    ))
  }
  use port <- serve(roadrunner_gleam.new(handler), "rg_file_zero")
  let #(headers, body) = split_response(raw(port, "GET", "/"))
  assert list.contains(headers, "content-length: 0")
  assert body == ""
}

// --- options --------------------------------------------------------

pub fn option_never_replaces_routes_test() {
  let builder =
    roadrunner_gleam.new(fn(_) { response.text("handler") })
    |> roadrunner_gleam.option("routes", dynamic.int(1))
  use port <- serve(builder, "rg_routes_kept")
  let #(_, body) = split_response(raw(port, "GET", "/"))
  assert body == "handler"
}

import gleam/bit_array
import gleam/list
import gleam/otp/actor
import gleam/string
import roadrunner_gleam
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}

fn serve(
  name: String,
  handler: fn(Request) -> Response,
  raw: BitArray,
) -> String {
  let assert Ok(actor.Started(data: listener, ..)) =
    roadrunner_gleam.new(handler)
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> roadrunner_gleam.start
  let response = raw_request(roadrunner_gleam.listener_port(listener), raw)
  roadrunner_gleam.stop(listener)
  let assert Ok(response) = bit_array.to_string(response)
  let assert Ok(#(_, body)) = string.split_once(response, "\r\n\r\n")
  body
}

@external(erlang, "roadrunner_gleam_test_ffi", "raw_request")
fn raw_request(port: Int, request: BitArray) -> BitArray

// A header value with obs-text (0xFF), which HTTP allows.
const obs_text_request = <<
  "GET /?a=%FF HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n":utf8,
  "x-raw: caf":utf8, 0xFF, "\r\nx-ok: fine\r\n\r\n":utf8,
>>

pub fn invalid_utf8_header_test() {
  let body =
    serve(
      "rg_utf8_header",
      fn(req) {
        let assert Error(Nil) = request.header(req, "x-raw")
        let assert Ok(<<"caf":utf8, 0xFF>>) = request.header_bits(req, "x-raw")
        let assert Ok("fine") = request.header(req, "x-ok")
        let headers = request.headers(req)
        let assert True = list.key_find(headers, "x-raw") == Error(Nil)
        let assert True = list.contains(headers, #("x-ok", "fine"))
        response.text("checked")
      },
      obs_text_request,
    )
  assert body == "checked"
}

pub fn invalid_utf8_query_test() {
  let body =
    serve(
      "rg_utf8_query",
      fn(req) {
        let assert Error(Nil) = request.query_params(req)
        response.text("checked")
      },
      obs_text_request,
    )
  assert body == "checked"
}

pub fn missing_header_bits_test() {
  let body =
    serve(
      "rg_missing_bits",
      fn(req) {
        let assert Error(Nil) = request.header_bits(req, "x-missing")
        response.text("checked")
      },
      obs_text_request,
    )
  assert body == "checked"
}

//// The request a handler receives.
////
//// A `Request` is roadrunner's own request, so reading it costs the same
//// as in an Erlang handler: nothing is copied or converted until you ask
//// for a value. Use `to_http` when you need a `gleam/http` request, for
//// example to hand it to a library built on `gleam_http`.

import gleam/http.{type Method, type Scheme}
import gleam/http/request as http_request
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// An HTTP request served by roadrunner, over HTTP/1.1, HTTP/2 or HTTP/3.
pub type Request

/// The HTTP version the request came over.
pub type HttpVersion {
  Http10
  Http11
  Http2
  Http3
}

/// The request method.
pub fn method(request: Request) -> Method {
  let method = raw_method(request)
  case http.parse_method(method) {
    Ok(method) -> method
    Error(Nil) -> http.Other(method)
  }
}

@external(erlang, "roadrunner_req", "method")
fn raw_method(request: Request) -> String

/// The request path, without the query string.
@external(erlang, "roadrunner_req", "path")
pub fn path(request: Request) -> String

/// The path split into its decoded segments, handy for routing with
/// pattern matching: `/users/42` gives `["users", "42"]`.
pub fn path_segments(request: Request) -> List(String) {
  uri.path_segments(path(request))
}

/// The raw query string, without the `?`. Empty when there is none.
@external(erlang, "roadrunner_req", "qs")
pub fn query(request: Request) -> String

/// The decoded query parameters, in order. A key with no `=` gets an empty
/// value.
@external(erlang, "roadrunner_gleam_ffi", "query_params")
pub fn query_params(request: Request) -> List(#(String, String))

/// All request headers, in order, with lowercase names.
@external(erlang, "roadrunner_req", "headers")
pub fn headers(request: Request) -> List(#(String, String))

/// The first value of a header. The name is matched without regard to case.
@external(erlang, "roadrunner_gleam_ffi", "header")
pub fn header(request: Request, name: String) -> Result(String, Nil)

/// The request body. Roadrunner reads it before calling the handler, up to
/// the listener's `max_content_length`.
@external(erlang, "roadrunner_gleam_ffi", "body")
pub fn body(request: Request) -> BitArray

/// `Http` on a plain listener, `Https` on a TLS one.
@external(erlang, "roadrunner_req", "scheme")
pub fn scheme(request: Request) -> Scheme

/// The HTTP version the request came over.
@external(erlang, "roadrunner_gleam_ffi", "http_version")
pub fn http_version(request: Request) -> HttpVersion

/// The client's IP address. Behind trusted proxies configured with the
/// listener's `real_ip` option, this is the address they forwarded.
@external(erlang, "roadrunner_gleam_ffi", "client_ip")
pub fn client_ip(request: Request) -> Result(String, Nil)

/// The id roadrunner gives each request, also set in the logger metadata.
@external(erlang, "roadrunner_gleam_ffi", "request_id")
pub fn request_id(request: Request) -> Result(String, Nil)

/// Build a `gleam/http` request with the body read as a `BitArray`.
pub fn to_http(request: Request) -> http_request.Request(BitArray) {
  let #(host, port) = host_and_port(request)
  let query = case query(request) {
    "" -> None
    query -> Some(query)
  }
  http_request.Request(
    method: method(request),
    headers: headers(request),
    body: body(request),
    scheme: scheme(request),
    host:,
    port:,
    path: path(request),
    query:,
  )
}

fn host_and_port(request: Request) -> #(String, Option(Int)) {
  let authority = header(request, "host") |> result.unwrap("")
  // An IPv6 host is bracketed, `[::1]:8080`, so its colons are skipped.
  let split = case authority {
    "[" <> _ -> string.split_once(authority, "]:") |> result.map(bracket)
    _ -> string.split_once(authority, ":")
  }
  case split {
    Ok(#(host, port)) ->
      case int.parse(port) {
        Ok(port) -> #(host, Some(port))
        Error(Nil) -> #(authority, None)
      }
    Error(Nil) -> #(authority, None)
  }
}

fn bracket(split: #(String, String)) -> #(String, String) {
  #(split.0 <> "]", split.1)
}

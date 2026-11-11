//// The request a handler receives.
////
//// A `Request` is roadrunner's own request, so reading it costs the same
//// as in an Erlang handler: nothing is copied or converted until you ask
//// for a value. Use `to_http` when you need a `gleam/http` request, for
//// example to hand it to a library built on `gleam_http`.

import gleam/http.{type Method, type Scheme}
import gleam/http/request as http_request
import gleam/int
import gleam/list
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

/// The path split into its segments, handy for routing with pattern
/// matching: `/users/42` gives `["users", "42"]`. The segments are not
/// percent-decoded: decode one with `uri.percent_decode` when it may hold
/// escapes, such as `caf%C3%A9`.
pub fn path_segments(request: Request) -> List(String) {
  uri.path_segments(path(request))
}

/// The raw query string, without the `?`. Empty when there is none.
@external(erlang, "roadrunner_req", "qs")
pub fn query(request: Request) -> String

/// The decoded query parameters, in order. A key with no `=` gets an empty
/// value. Fails when a decoded key or value is not valid UTF-8, as
/// `gleam/http/request.get_query` does.
@external(erlang, "roadrunner_gleam_ffi", "query_params")
pub fn query_params(request: Request) -> Result(List(#(String, String)), Nil)

/// All request headers, in order, with lowercase names. HTTP lets a value
/// hold bytes that are not UTF-8; such a header is left out here. Read it
/// with `header_bits`.
@external(erlang, "roadrunner_gleam_ffi", "headers")
pub fn headers(request: Request) -> List(#(String, String))

/// The first value of a header. The name is matched without regard to case.
/// Fails when the header is missing, or when its value is not valid UTF-8:
/// read that one with `header_bits`.
@external(erlang, "roadrunner_gleam_ffi", "header")
pub fn header(request: Request, name: String) -> Result(String, Nil)

/// The first value of a header as raw bytes, whatever they are. The name is
/// matched without regard to case.
@external(erlang, "roadrunner_gleam_ffi", "header_bits")
pub fn header_bits(request: Request, name: String) -> Result(BitArray, Nil)

/// The request body. Roadrunner reads it before calling the handler, up to
/// the listener's `max_content_length`. On a listener that reads bodies on
/// demand (`roadrunner_gleam.read_body_on_demand`) it is empty: read the
/// body with `read_body` or `read_chunk` instead.
@external(erlang, "roadrunner_gleam_ffi", "body")
pub fn body(request: Request) -> BitArray

/// Why reading the body failed.
pub type ReadError {
  /// The body is larger than the listener's `max_content_length`.
  BodyTooLarge
  /// The client went away or sent a malformed body.
  ReadFailed(String)
}

/// A piece of the body. Read the next one from `next`.
pub type Chunk {
  /// More of the body follows.
  More(data: BitArray, next: Request)
  /// The last piece: the body has been read.
  Last(data: BitArray, next: Request)
}

/// Read the rest of the body. Returns the request to use after the read.
/// On a listener that reads bodies before the handler, this is the body
/// already read.
@external(erlang, "roadrunner_gleam_ffi", "read_body")
pub fn read_body(request: Request) -> Result(#(BitArray, Request), ReadError)

/// Read the next piece of the body, at most `max_bytes` long, so a large
/// upload never sits in memory whole. Bodies sent with chunked encoding
/// are read across chunk boundaries the same way, and a body roadrunner
/// already read is cut into pieces of the same size. Read only in the
/// process that runs the handler.
@external(erlang, "roadrunner_gleam_ffi", "read_chunk")
pub fn read_chunk(request: Request, max_bytes: Int) -> Result(Chunk, ReadError)

/// `Http` on a plain listener, `Https` on a TLS one.
@external(erlang, "roadrunner_req", "scheme")
pub fn scheme(request: Request) -> Scheme

/// The HTTP version the request came over.
@external(erlang, "roadrunner_gleam_ffi", "http_version")
pub fn http_version(request: Request) -> HttpVersion

/// An IP address.
pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// An address and port at one end of the connection.
pub type ConnectionInfo {
  ConnectionInfo(ip_address: IpAddress, port: Int)
}

/// The address in its usual text form, such as `127.0.0.1` or `::1`.
@external(erlang, "roadrunner_gleam_ffi", "ip_address_to_string")
pub fn ip_address_to_string(ip_address: IpAddress) -> String

/// The client's IP address. Behind trusted proxies configured with the
/// listener's `real_ip` option, this is the address they forwarded;
/// otherwise it is the peer's.
@external(erlang, "roadrunner_gleam_ffi", "client_ip")
pub fn client_ip(request: Request) -> Result(IpAddress, Nil)

/// The address and port the connection comes from: the client, or the
/// last proxy in front of it.
@external(erlang, "roadrunner_gleam_ffi", "peer")
pub fn peer(request: Request) -> Result(ConnectionInfo, Nil)

/// The address and port of this server that the connection reached.
@external(erlang, "roadrunner_gleam_ffi", "local_address")
pub fn local_address(request: Request) -> Result(ConnectionInfo, Nil)

/// The certificate the client sent over TLS, DER-encoded. Fails on plain
/// connections and when the client sent none.
@external(erlang, "roadrunner_gleam_ffi", "peer_certificate")
pub fn peer_certificate(request: Request) -> Result(BitArray, Nil)

/// The cookies the client sent, in order. A cookie whose name or value is
/// not valid UTF-8 is left out. Set cookies with
/// `gleam/http/response.set_cookie`.
@external(erlang, "roadrunner_gleam_ffi", "cookies")
pub fn cookies(request: Request) -> List(#(String, String))

/// The id roadrunner gives each request, also set in the logger metadata.
@external(erlang, "roadrunner_gleam_ffi", "request_id")
pub fn request_id(request: Request) -> Result(String, Nil)

/// Build a `gleam/http` request with the body as a `BitArray`. On a
/// listener that reads bodies on demand, the body is what has been read
/// so far: read it first with `read_body` and convert the request it
/// returns.
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

/// Build a request from a `gleam/http` request, to test a handler without
/// starting a listener. The request comes over HTTP/1.1, with the body
/// already read. It has no peer, client address or request id.
pub fn from_http(request: http_request.Request(BitArray)) -> Request {
  let target = case request.query {
    Some(query) -> request.path <> "?" <> query
    None -> request.path
  }
  let host = case request.port {
    Some(port) -> request.host <> ":" <> int.to_string(port)
    None -> request.host
  }
  let headers = case list.key_find(request.headers, "host") {
    Ok(_) -> request.headers
    Error(Nil) -> [#("host", host), ..request.headers]
  }
  ffi_from_http(
    http.method_to_string(request.method),
    target,
    request.path,
    headers,
    request.body,
    request.scheme,
  )
}

@external(erlang, "roadrunner_gleam_ffi", "from_http")
fn ffi_from_http(
  method: String,
  target: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  scheme: Scheme,
) -> Request

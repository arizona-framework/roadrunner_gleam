//// Run Gleam handlers on roadrunner.
////
//// ```gleam
//// import gleam/erlang/process
//// import roadrunner_gleam
//// import roadrunner_gleam/request.{type Request}
//// import roadrunner_gleam/response.{type Response}
////
//// pub fn main() {
////   let assert Ok(_) =
////     roadrunner_gleam.new(handle)
////     |> roadrunner_gleam.port(8080)
////     |> roadrunner_gleam.start
////   process.sleep_forever()
//// }
////
//// fn handle(request: Request) -> Response {
////   case request.path_segments(request) {
////     [] -> response.text("hello, roadrunner!")
////     _ -> response.new(404)
////   }
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}

/// How to run a listener, built with `new` and the functions that follow it.
pub opaque type Builder {
  Builder(
    handler: fn(Request) -> Response,
    port: Int,
    ip: Option(String),
    name: Option(String),
    tls: Option(Tls),
    http3: Bool,
    options: Dict(Atom, Dynamic),
  )
}

type Tls {
  Tls(certfile: String, keyfile: String)
}

/// A started listener.
pub opaque type Listener {
  Listener(name: Atom)
}

/// A listener on port 4000 of every interface, over plain HTTP/1.1.
pub fn new(handler: fn(Request) -> Response) -> Builder {
  Builder(
    handler:,
    port: 4000,
    ip: None,
    name: None,
    tls: None,
    http3: False,
    options: dict.new(),
  )
}

/// The port to listen on. `0` picks a free one; read it with
/// `listener_port`.
pub fn port(builder: Builder, port: Int) -> Builder {
  Builder(..builder, port:)
}

/// The address to listen on, such as `"127.0.0.1"` or `"::1"`.
pub fn bind(builder: Builder, ip: String) -> Builder {
  Builder(..builder, ip: Some(ip))
}

/// The name the listener is registered under. Defaults to one built from
/// the port. Give each listener its own name when you run several on
/// port `0`.
pub fn name(builder: Builder, name: String) -> Builder {
  Builder(..builder, name: Some(name))
}

/// Serve over TLS with the certificate and key in these PEM files. TLS
/// listeners serve HTTP/2 as well as HTTP/1.1.
pub fn tls(
  builder: Builder,
  certfile certfile: String,
  keyfile keyfile: String,
) -> Builder {
  Builder(..builder, tls: Some(Tls(certfile:, keyfile:)))
}

/// Also serve HTTP/3, over QUIC on the UDP port with the same number. Needs
/// `tls` and a fixed port.
pub fn http3(builder: Builder) -> Builder {
  Builder(..builder, http3: True)
}

/// Leave request bodies unread until the handler reads them with
/// `request.read_body` or `request.read_chunk`, so large uploads can be
/// read in pieces. A body declared larger than `max_content_length` is
/// still refused with `413` before the handler runs.
pub fn read_body_on_demand(builder: Builder) -> Builder {
  option(builder, "body_buffering", atom_dynamic("manual"))
}

/// Set any other roadrunner listener option, such as `max_content_length`
/// or `keep_alive_timeout`. See `roadrunner_listener:opts()` in
/// roadrunner's docs for the full list. It overrides what the functions
/// above set, except `routes`, which carries the handler.
pub fn option(builder: Builder, name: String, value: Dynamic) -> Builder {
  let options = dict.insert(builder.options, atom.create(name), value)
  Builder(..builder, options:)
}

/// Start the listener, linked to the calling process. A listener that
/// cannot start, such as on a port already in use, returns an error and
/// leaves the caller running.
pub fn start(
  builder: Builder,
) -> Result(actor.Started(Listener), actor.StartError) {
  case listener_options(builder) {
    Ok(options) -> {
      let name = listener_name(builder)
      case start_link(name, options) {
        Ok(pid) -> Ok(actor.Started(pid:, data: Listener(name:)))
        Error(reason) -> Error(actor.InitFailed(reason))
      }
    }
    Error(reason) -> Error(actor.InitFailed(reason))
  }
}

/// A child specification to start the listener under a `gleam/otp`
/// supervisor.
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(Listener) {
  supervision.worker(fn() { start(builder) })
}

/// The port the listener is bound to.
pub fn listener_port(listener: Listener) -> Int {
  ffi_listener_port(listener.name)
}

/// Stop the listener and close its port, without waiting for open
/// connections.
pub fn stop(listener: Listener) -> Nil {
  ffi_stop(listener.name)
}

/// Stop accepting connections, ask open ones to finish, and stop the
/// listener once they are gone or after `timeout` milliseconds, when the
/// rest are closed. Fails with how many were still open at the timeout.
///
/// A supervised listener exits after the drain, so its supervisor starts it
/// again unless it is shut down too.
pub fn drain(listener: Listener, timeout: Int) -> Result(Nil, Int) {
  ffi_drain(listener.name, timeout)
}

fn listener_name(builder: Builder) -> Atom {
  case builder.name {
    Some(name) -> atom.create(name)
    None -> atom.create("roadrunner_gleam_" <> int.to_string(builder.port))
  }
}

fn listener_options(builder: Builder) -> Result(Dict(Atom, Dynamic), String) {
  use ip <- try_ip(builder.ip)
  use protocols <- try_protocols(builder)
  let ip = case ip {
    Some(ip) -> [#("ip", ip)]
    None -> []
  }
  let tls = case builder.tls {
    Some(tls) -> [#("tls", tls_options(tls))]
    None -> []
  }
  let options =
    [
      #("port", dynamic.int(builder.port)),
      #("protocols", dynamic.list(list.map(protocols, atom_dynamic))),
      ..list.append(ip, tls)
    ]
    |> list.map(fn(option) { #(atom.create(option.0), option.1) })
    |> dict.from_list
  // The routes carry the handler, so an `option` never replaces them.
  Ok(
    dict.merge(options, builder.options)
    |> dict.insert(atom.create("routes"), routes(builder.handler)),
  )
}

fn try_ip(
  ip: Option(String),
  next: fn(Option(Dynamic)) -> Result(a, String),
) -> Result(a, String) {
  case ip {
    None -> next(None)
    Some(ip) ->
      case parse_ip(ip) {
        Ok(ip) -> next(Some(ip))
        Error(Nil) -> Error("invalid ip address: " <> ip)
      }
  }
}

fn try_protocols(
  builder: Builder,
  next: fn(List(String)) -> Result(a, String),
) -> Result(a, String) {
  case builder.tls, builder.http3 {
    None, False -> next(["http1"])
    None, True -> Error("http3 needs tls")
    Some(_), True if builder.port == 0 ->
      Error("http3 needs a fixed port: with port 0, HTTP/3 gets its own")
    Some(_), False -> next(["http1", "http2"])
    Some(_), True -> next(["http1", "http2", "http3"])
  }
}

fn tls_options(tls: Tls) -> Dynamic {
  dynamic.list([
    tuple2(atom_dynamic("certfile"), dynamic.string(tls.certfile)),
    tuple2(atom_dynamic("keyfile"), dynamic.string(tls.keyfile)),
  ])
}

fn atom_dynamic(name: String) -> Dynamic {
  atom.to_dynamic(atom.create(name))
}

@external(erlang, "roadrunner_gleam_ffi", "routes")
fn routes(handler: fn(Request) -> Response) -> Dynamic

@external(erlang, "roadrunner_gleam_ffi", "tuple2")
fn tuple2(a: Dynamic, b: Dynamic) -> Dynamic

@external(erlang, "roadrunner_gleam_ffi", "parse_ip")
fn parse_ip(ip: String) -> Result(Dynamic, Nil)

@external(erlang, "roadrunner_gleam_ffi", "start_link")
fn start_link(name: Atom, options: Dict(Atom, Dynamic)) -> Result(Pid, String)

@external(erlang, "roadrunner_gleam_ffi", "listener_port")
fn ffi_listener_port(name: Atom) -> Int

@external(erlang, "roadrunner_gleam_ffi", "stop")
fn ffi_stop(name: Atom) -> Nil

@external(erlang, "roadrunner_gleam_ffi", "drain")
fn ffi_drain(name: Atom, timeout: Int) -> Result(Nil, Int)

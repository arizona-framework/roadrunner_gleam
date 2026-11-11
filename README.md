# roadrunner_gleam

[![CI](https://github.com/arizona-framework/roadrunner_gleam/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/arizona-framework/roadrunner_gleam/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/roadrunner_gleam.svg)](https://hex.pm/packages/roadrunner_gleam)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/roadrunner_gleam/)
[![License](https://img.shields.io/hexpm/l/roadrunner_gleam.svg)](https://github.com/arizona-framework/roadrunner_gleam/blob/main/LICENSE.md)

Run [Gleam](https://gleam.run) web apps on
[Roadrunner](https://github.com/arizona-framework/roadrunner), the
pure-Erlang HTTP/1.1, HTTP/2, HTTP/3 and WebSocket server.

## Requirements

Requires **OTP 27+** and **Gleam 1.19+**, with `rebar3` installed to build
Roadrunner.

## 🚧 Status

roadrunner_gleam is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact version in your
deps if you need stability across upgrades.

## Installation

```sh
gleam add roadrunner_gleam
```

## Usage

```gleam
import gleam/erlang/process
import roadrunner_gleam
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}

pub fn main() {
  let assert Ok(_) =
    roadrunner_gleam.new(handle)
    |> roadrunner_gleam.port(8080)
    |> roadrunner_gleam.start
  process.sleep_forever()
}

fn handle(request: Request) -> Response {
  case request.path_segments(request) {
    [] -> response.text("hello, roadrunner!")
    ["hello", name] -> response.text("hello, " <> name <> "!")
    _ -> response.new(404)
  }
}
```

```
$ curl localhost:8080/hello/gleam
hello, gleam!
```

To run the listener under a `gleam/otp` supervisor, add
`roadrunner_gleam.supervised(builder)` as a child.

## TLS, HTTP/2 and HTTP/3

```gleam
roadrunner_gleam.new(handle)
|> roadrunner_gleam.port(8443)
|> roadrunner_gleam.tls(certfile: "cert.pem", keyfile: "key.pem")
|> roadrunner_gleam.http3
|> roadrunner_gleam.start
```

A TLS listener serves HTTP/1.1 and HTTP/2 on the TCP port. `http3` also
serves HTTP/3 over QUIC on the UDP port with the same number.

Any other Roadrunner listener option, such as `max_content_length` or
`keep_alive_timeout`, can be set with `roadrunner_gleam.option`.

## What works

- Handlers are plain Gleam functions, the same on HTTP/1.1, HTTP/2 and
  HTTP/3
- Requests are read in place, at the same cost as an Erlang handler
- Responses: complete, chunked and files sent by the kernel
- `content-length` set for you on complete and file responses
- WebSocket sessions over HTTP/1.1, with typed state and a `Subject` other
  processes can push through
- Responses that stay open and push data as messages arrive, such as
  server-sent events, on HTTP/1.1, HTTP/2 and HTTP/3
- `request.to_http` and `response.from_http` for libraries built on
  `gleam_http`
- Start, stop and drain listeners, or run them under a `gleam/otp`
  supervisor

## Sponsors

roadrunner_gleam is open source and maintained on personal time. If you or your company find it useful,
consider [sponsoring](https://github.com/sponsors/williamthome).

I also accept coffees ☕

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/williamthome)

<a href="https://github.com/sponsors/williamthome">
  <img
    src="https://raw.githubusercontent.com/williamthome/williamthome/sponsorkit/sponsors.svg"
    alt="Sponsors"
  />
</a>

## License

Copyright (c) 2026 [William Fank Thomé](https://github.com/williamthome)

roadrunner_gleam is open-source under the Apache 2.0 License on
[GitHub](https://github.com/arizona-framework/roadrunner_gleam).

See [LICENSE.md](https://github.com/arizona-framework/roadrunner_gleam/blob/main/LICENSE.md) for more information.

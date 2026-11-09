---
title: "HTTP from a Component"
order: 11
part: "Interfaces: HTTP & gRPC"
description: "Serve HTTP from a WebAssembly component with the wasi-http proxy world, compose it with the cargo provider via wac plug, and run it under wasmtime serve in Rust and Go."
duration: "14 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what `include wasi:http/proxy` adds to a WIT world and why it lets `wasmtime serve` drive the component with no listener inside it.
- Build an HTTP front door for the cargo domain in Rust (`cargo-component`) and in Go (the TinyGo reactor pipeline), and compose each with a provider via `wac plug`.
- Diagnose the `wasmtime serve -S cli` requirement from its failure mode.
- Name every `wasi:*` package `cargo-component` needs declared, and say why `wasm-tools` doesn't.
- Explain why the handler books a cargo and reads it back within one request.
- Decide when a component terminates HTTP itself and when a gateway belongs in front of it.

## Why this matters

Composing two components proves they agree on a WIT boundary. Nothing so far has put the cargo domain on a network socket. One WIT world does: `wasi:http/proxy`.

A component that includes `wasi:http/proxy` exports `wasi:http/incoming-handler`, one function the host calls per request with an `incoming-request` and a `response-outparam`. The component opens no socket, parses no request line and manages no connection. `wasmtime serve` does that and hands the component one fully parsed request at a time. The component states what it needs through its world and the runtime supplies it; here the runtime supplies an HTTP server.

The cargo domain answers real HTTP requests in both languages, unchanged from its shared WIT contract and its Rust and Go providers. For status codes, content negotiation and resource naming, see the sibling site [Designing Cloud-Native APIs: REST](https://github.com/patterncatalyst/api-patterns-and-practices-rest). What changes here is that a WebAssembly component answers.

{% include excalidraw.html file="11-wasi-http-request-path" alt="A curl client box sends GET /cargo/CARGO-USNYC-DEHAM (or GET /cargo/NOPE) to a wasmtime serve -S cli box running composed.wasm on 127.0.0.1:8080. An outer frame labeled composed.wasm, wac plug output, contains two boxes: the http-rust or http-go adapter, exporting wasi:http/incoming-handler and importing booking and handling (resolved by wac plug), and the part2 cargo provider (Rust or Go), exporting booking and handling, noted as a fresh instance per request with in-memory state, doing book-cargo then get-cargo in one request. Arrows: HTTP request from curl to wasmtime serve, incoming-handler.handle from wasmtime serve into the adapter, an amber WIT call arrow labeled book-cargo and get-cargo from the adapter down into the provider, a dashed return arrow labeled 200 JSON or 404 error from the provider back to the adapter, and an HTTP response arrow from wasmtime serve back to curl. A caption notes that the Rust and Go front doors produce byte-identical JSON, and an id that is never booked misses get-cargo and maps to a 404." caption="Figure 11.1: One HTTP request's path from curl through wasmtime serve into a composed wasi-http component, and back out as JSON." %}

## The `wasi:http/proxy` world

```wit
package patterncatalyst:cargo-http@0.1.0;

/// An HTTP front door for the cargo domain, as a WebAssembly component.
///
/// This world INCLUDES `wasi:http/proxy` (so the component exports
/// `wasi:http/incoming-handler` and `wasmtime serve` can drive it directly) and
/// additionally IMPORTS the three cargo interfaces from the repository
/// contract (`patterncatalyst:cargo`, supplied as a path dependency in
/// Cargo.toml, so the contract stays pristine). The handler terminates HTTP and
/// calls the imported `booking` interface across the component boundary; once
/// composed with a `cargo` provider via `wac plug`, the import is satisfied and
/// the result serves live under `wasmtime serve`.
///
/// The vendored `wasi:*` packages under wit/deps are pinned to 0.2.8 (an
/// internally consistent set from the wasi-http v0.2.8 release). wasmtime 50
/// satisfies any 0.2.x import through semver-compatible component linking.
world cargo-http {
    include wasi:http/proxy@0.2.8;

    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;
}
```

`include wasi:http/proxy@0.2.8` pulls a whole predefined world into this one. The upstream `proxy` world exports `wasi:http/incoming-handler` and imports a narrow slice of WASI (`wasi:io/streams`, `wasi:io/poll`, `wasi:clocks/monotonic-clock`, `wasi:http/outgoing-handler` among them), sized for something that terminates or proxies HTTP. The three `import` lines add the cargo contract. The world gives one component two jobs, HTTP server and cargo caller, and composition turns the second from a compile-time obligation into a runtime capability.

`http-go/wit/world.wit` has the same include and imports under its own package name. `wit-bindgen-go` resolves a WIT directory tree with no path-dependency mechanism, so the Go side keeps a read-only copy of the cargo contract under `wit/deps/cargo` instead of pointing at `contracts/wit/`.

## Naming every `wasi:*` package by hand

`cargo-component`, unlike `wasm-tools`, does not discover a WIT package just because the file sits under `wit/deps`. Each package is declared in `Cargo.toml`:

```toml
[package.metadata.component]
package = "patterncatalyst:cargo-http"

[package.metadata.component.target]
path = "wit"
world = "cargo-http"

[package.metadata.component.target.dependencies]
"patterncatalyst:cargo" = { path = "../../../contracts/wit" }
"wasi:http" = { path = "wit/deps/http" }
"wasi:io" = { path = "wit/deps/io" }
"wasi:clocks" = { path = "wit/deps/clocks" }
"wasi:random" = { path = "wit/deps/random" }
"wasi:cli" = { path = "wit/deps/cli" }
"wasi:filesystem" = { path = "wit/deps/filesystem" }
"wasi:sockets" = { path = "wit/deps/sockets" }
```

Seven of the eight entries are `wasi:*` packages that the `include` needs to resolve, because the proxy world's dependency graph reaches into all of them even though it imports only a subset at the top level. Drop one and `cargo component build` fails at the `include wasi:http/proxy@0.2.8` line with `package not found`, naming the missing package rather than the missing declaration. The `patterncatalyst:cargo` entry is a relative path to the shared contract, so the imported interfaces cannot drift from what the providers export.

## The handler in Rust

`handle` takes an `IncomingRequest` and a `ResponseOutparam` and returns nothing: the response is delivered by writing into the outparam. For a `CARGO-{ORIGIN}-{DEST}` id the handler books the cargo, reads it back and returns the JSON:

{% raw %}
```rust
        // Known shape CARGO-{ORIGIN}-{DEST}: book (seed) then read back.
        let parts: Vec<&str> = id.splitn(3, '-').collect();
        if parts.len() == 3 && parts[0] == "CARGO" {
            let spec = RouteSpec {
                origin: location_for(parts[1]),
                destination: location_for(parts[2]),
                arrival_deadline: ARRIVAL_DEADLINE.to_string(),
            };
            match booking::book_cargo(&spec, DEFAULT_WEIGHT_KG) {
                Ok(b) => match booking::get_cargo(&b.cargo_id) {
                    Ok(cargo) => {
                        let body = format!(
                            "{{\"tracking_id\":\"{}\",\"origin\":\"{}\",\"destination\":\"{}\",\"weight_kg\":{},\"price\":{{\"amount\":\"{}\",\"currency\":\"{}\"}}}}",
                            json_escape(&cargo.tracking_id),
                            json_escape(&cargo.origin.unlocode),
                            json_escape(&cargo.destination.unlocode),
                            cargo.weight_kg,
                            json_escape(&b.price.amount),
                            json_escape(&b.price.currency),
                        );
                        send(response_out, 200, body.as_bytes());
                    }
                    Err(e) => send_error(response_out, &e),
                },
                Err(e) => send_error(response_out, &e),
            }
            return;
```
{% endraw %}

`booking::book_cargo` and `booking::get_cargo` are calls across the component boundary into whichever provider `wac plug` composes in. The source names the provider only as an interface. The `send` helper shows the `wasi:http` resource model:

```rust
fn send(response_out: ResponseOutparam, status: u16, body: &[u8]) {
    let headers = Fields::new();
    headers
        .set(&"content-type".to_string(), &[b"application/json".to_vec()])
        .expect("set content-type");
    let resp = OutgoingResponse::new(headers);
    resp.set_status_code(status).expect("set status code");
    // Obtain the body handle BEFORE handing the response to the outparam: the
    // outparam call moves the OutgoingResponse.
    let out_body = resp.body().expect("response body");
    ResponseOutparam::set(response_out, Ok(resp));
    let stream = out_body.write().expect("body write stream");
    stream
        .blocking_write_and_flush(body)
        .expect("write body bytes");
    drop(stream);
    OutgoingBody::finish(out_body, None).expect("finish body");
}
```

The body handle has to be taken before `ResponseOutparam::set` consumes the response, because `wasi:http` resources are move-only like every Component Model resource. Getting the order wrong is a compile error. The 200 body is built with `format!` rather than a JSON library: four fields and a nested price don't justify `serde_json`.

`cargo-error` carries no HTTP semantics, so the adapter decides the mapping:

{% raw %}
```rust
fn send_error(response_out: ResponseOutparam, e: &CargoError) {
    let (status, msg): (u16, String) = match e {
        CargoError::NotFound(m) => (404, m.clone()),
        CargoError::InvalidBooking(m) => (400, m.clone()),
        CargoError::InvalidLocation(m) => (400, m.clone()),
        CargoError::Conflict(m) => (409, m.clone()),
    };
    let body = format!("{{\"error\":\"{}\"}}", json_escape(&msg));
    send(response_out, status, body.as_bytes());
}
```
{% endraw %}

## The same front door in Go

TinyGo uses the reactor export model. The handler is wired during `init()`, so it is live by the time `_initialize` returns and the host delivers the first request:

```go
// Reactor export: wire up the handler during package init so it is live by the
// time `_initialize` returns and the host delivers the first request.
func init() {
	incominghandler.Exports.Handle = handle
}

func main() {}
```

Routing matches the Rust version, down to splitting the id on its first two `-` characters and checking for a three-part `CARGO-{ORIGIN}-{DEST}` shape before booking. Each cross-component call returns a `cm.Result`, and its `.Result()` method yields the three values `(value, error, isErr)`:

```go
		b, bErr, isErr := booking.BookCargo(spec, defaultWeightKg).Result()
		if isErr {
			sendError(responseOut, bErr)
			return
		}
		cargo, cErr, isErr := booking.GetCargo(b.CargoID).Result()
		if isErr {
			sendError(responseOut, cErr)
			return
		}
```

Go's `send` takes the body handle before the outparam call for the same reason, but Go has no move semantics, so nothing at compile time catches a wrong order and the comment carries the rule:

```go
	// Obtain the body handle before handing the response to the outparam: the
	// set call consumes the OutgoingResponse. OK() is a pointer method, so the
	// cm.Result must live in a local first.
	bodyRes := resp.Body()
	outBody := *bodyRes.OK()
	ok := cm.OK[cm.Result[httptypes.ErrorCodeShape, httptypes.OutgoingResponse, httptypes.ErrorCode]](resp)
	httptypes.ResponseOutparamSet(responseOut, ok)
```

`sendError` can't switch on an enum, because `cm` generates a variant type with no Go-native cases. It reads the variant's `String()` form and checks the prefix (`not-found`, `conflict`), then maps to the same status codes.

`build.sh` regenerates the bindings with `wit-bindgen-go`, compiles a `wasip1` reactor module with TinyGo, then runs `wasm-tools component embed` and `component new --adapt`. The `incoming-handler` export is a reactor export, and TinyGo reaches a WASI 0.2 component through that embed-and-adapt pipeline rather than a one-shot `-target=wasip2` build, the same path the Go provider uses.

{% include excalidraw.html file="11-build-compose-serve-pipeline" alt="http-rust builds with cargo component build release to cargo_http_rust.wasm. http-go builds with build.sh, which runs wit-bindgen-go, tinygo, and wasm-tools component new adapt, producing cargo-http-go.wasm. A part2 provider box holds cargo_rust.wasm or cargo-go.wasm, built from its own recipe and not edited here. Arrows from all three feed into a wac plug box: wac plug --plug part2 provider http component -o composed.wasm, with the provider as --plug and the http component as the socket. An amber arrow labeled composed.wasm leads down into a final box: wasmtime serve -S cli composed.wasm --addr 127.0.0.1:8080, curl /cargo/CARGO-USNYC-DEHAM returns 200 JSON, curl /cargo/NOPE returns 404 JSON. A caption notes that two toolchains and one WIT world produce byte-identical responses." caption="Figure 11.2: Two toolchains, one WIT world, one wac recipe: building, composing and serving both front doors." %}

## Composing and serving

`wac plug --plug <PROVIDER> <CONSUMER> -o out.wasm` uses the usual orientation: the provider, which exports the three cargo interfaces, is the plug, and the HTTP adapter, which imports them, is the socket. Then serve the result:

```bash
wac plug --plug cargo_rust.wasm cargo_http_rust.wasm -o composed-http-rust.wasm
wasmtime serve -S cli composed-http-rust.wasm --addr 127.0.0.1:8080
```

`GET /cargo/CARGO-USNYC-DEHAM` returns the booked cargo as JSON and `GET /cargo/NOPE` returns 404. The Go front door composes the same way with `cargo-http-go.wasm` and the Go provider, and returns byte-identical JSON.

`-S cli` is required. By default `wasmtime serve` links a restricted `wasi:http/proxy` linker, narrower than the full command environment. The Rust standard library layer and the provider still import `wasi:cli/environment` and `wasi:filesystem`, and the default linker supplies neither. Without the flag the failure surfaces at the first request, not at startup: `instance export get-environment ... implementation is missing`. `-S cli` enables the full WASI CLI set inside the proxy-shaped linker.

## Why book, then get, in one request

`wasmtime serve` creates a fresh instance of the composed component for every request, and the provider keeps cargo state in that instance's linear memory. A `get_cargo` on a cold instance always returns `cargo-error::not-found`, correctly. Booking first, inside the same request, returns live data without pretending the provider has a durable store.

An id that isn't a `CARGO-{ORIGIN}-{DEST}` triple skips the booking branch and goes straight to `get_cargo`, so the 404 for `NOPE` is the provider's own `not-found`, mapped through `send_error`, not a short-circuit in the handler.

## Calling out over HTTP

The vendored `wasi:http` package includes `wasi:http/outgoing-handler`, and both languages' generated bindings expose it. Neither handler calls it. It is the interface a component imports to act as an HTTP client, issuing a request and awaiting a response. A front door that calls another service imports it explicitly in its world, the same way this world imports the cargo interfaces. No handler here makes an outbound call.

## When to terminate HTTP in the component

| Terminate in the component | Put a gateway in front |
| --- | --- |
| The whole request lifecycle fits the `wasi:http/proxy` imports plus the domain imports | The workload needs state that survives across requests |
| A fresh instance per request is a feature | It needs capabilities the proxy world lacks: long-lived connections, other protocols, broad filesystem or process access |
| Request/response work over a stable domain contract | TLS termination, authentication, rate limiting or protocol translation shouldn't be recompiled with the domain logic |

> **Decision**
>
> Terminate HTTP in the component when routing, response construction and every call it makes fit the proxy world and per-request isolation helps. Put a gateway in front when state must outlive a request, when the workload needs more than the proxy world offers, or when request-level concerns should deploy separately from the domain logic.

> **🤖 Explore with your agent**
>
> "In examples/part3-interfaces/http-rust, add a `GET /cargo/{id}/price` route to the `cargo-http` world's handler in src/lib.rs that books the cargo and returns only the price object as JSON, mapping `cargo-error` variants with `send_error`. Rebuild, compose it with the Part 2 Rust provider using `wac plug --plug`, and run it under `wasmtime serve -S cli`. Apply the decision rule: say whether this route still fits the `wasi:http/proxy` world or needs a gateway, and why."
>
> Check: `curl http://127.0.0.1:8080/cargo/CARGO-USNYC-DEHAM/price` returns the price object and `curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/cargo/NOPE` still prints 404.

## Build, run, observe

```bash
cd examples/part3-interfaces && ./verify.sh
```

The script builds the Part 2 providers and the Rust and Go front doors, composes the Rust front door with the Rust provider and the Go front door with the Go provider via `wac plug`, and serves each under `wasmtime serve -S cli` (on ports 18080 and 18081). For both languages, `GET /cargo/CARGO-USNYC-DEHAM` returns the exact expected JSON and `GET /cargo/NOPE` returns 404. Expect `PASS`.

Experiments:

- Run `wasmtime serve` without `-S cli`. The first request fails with `implementation is missing` for `wasi:cli/environment`.
- Remove the `"wasi:io"` line from `[package.metadata.component.target.dependencies]` in `http-rust/Cargo.toml`. `cargo component build` fails with `package not found`.
- Call `booking::get_cargo` first in the handler for a `CARGO-USNYC-DEHAM` id. The response becomes a 404, because the fresh instance has nothing booked.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the wasi-http treatment of the proxy world and the `incoming-handler`/`outgoing-handler` split.
- Shashank Jain, *WebAssembly for Cloud* (Apress): cross-language HTTP front doors and the production trade-offs of composing a protocol adapter with a domain provider.
- [wasi-http WIT definitions](https://github.com/WebAssembly/wasi-http): the authoritative `proxy` world and the `incoming-handler`/`outgoing-handler` interfaces.
- [Wasmtime CLI reference: `wasmtime serve`](https://docs.wasmtime.dev/cli-options.html): the `-S cli` flag and the rest of the proxy linker's capability switches.
- [wac: WebAssembly Composition tool](https://github.com/bytecodealliance/wac): the `wac plug` plug/socket reference.
- [Designing Cloud-Native APIs: REST](https://github.com/patterncatalyst/api-patterns-and-practices-rest) (sibling site): status semantics, resource design and content negotiation.

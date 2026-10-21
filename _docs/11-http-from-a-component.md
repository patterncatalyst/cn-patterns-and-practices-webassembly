---
title: "HTTP from a Component"
order: 11
part: "Interfaces: HTTP & gRPC"
description: "Serve HTTP directly from a WebAssembly component with the wasi-http proxy world, compose it with the Part 2 cargo provider via wac plug, and run it under wasmtime serve with no native host, in both Rust and Go."
duration: "24 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what `include wasi:http/proxy@0.2.8` adds to a WIT world, and why that single line is what makes a component export `wasi:http/incoming-handler` for `wasmtime serve` to drive directly, with no TCP listener written inside the component itself.
- Build an HTTP front door for the cargo domain in Rust (`cargo-component`) and in Go (the TinyGo reactor pipeline from Chapter 7), both importing the three `patterncatalyst:cargo` interfaces and composing with a Part 2 provider via `wac plug`, the identical socket/plug model Chapter 8 used for `wasi:cli/run`.
- Diagnose the `wasmtime serve -S cli` requirement from its failure mode (`implementation is missing` for `wasi:cli/environment` and `wasi:filesystem`), and explain why the default proxy linker omits those imports in the first place.
- State why `cargo-component` needs every vendored `wasi:*` package named explicitly under `[package.metadata.component.target.dependencies]`, unlike `wasm-tools`, which resolves `wit/deps` on its own.
- Trace why the handler books a cargo and then reads it back within one HTTP request, tying that pattern to `wasmtime serve`'s fresh-instance-per-request model and the Part 2 provider's in-memory state.
- Decide when a component should terminate HTTP directly against `wasmtime serve` and when it should sit behind a gateway instead, given what the `wasi:http/proxy` world does and does not let it do.

## Why this matters

Chapter 8 proved that two independently built components agree on a WIT boundary without either one reading the other's source, by composing a command component against a provider and running the result with `wasmtime run`. Chapter 10 then drew a hard line between a recoverable `cargo-error` and an unrecoverable trap, both still observed from inside a single process talking to a single component over a single `Store`. Nothing so far has put the cargo domain on a network socket. This chapter does, and the mechanism is not a web framework bundled into the component: it is one WIT world, `wasi:http/proxy`, included into the same kind of component this book has been building since Chapter 6.

A component that includes `wasi:http/proxy` exports `wasi:http/incoming-handler`, a single function the host calls once per HTTP request with an `incoming-request` and a `response-outparam`. The component never opens a socket, never parses an HTTP/1.1 request line, and never manages a connection; `wasmtime serve` does all of that, and hands the component exactly one request at a time, fully parsed. That division of labor is the same shape this book has used for every WASI capability since Chapter 4: the component states what it needs through its world, and the runtime supplies it. Here what gets supplied is an entire HTTP server, and the examples under `examples/part3-interfaces/http-rust/` and `examples/part3-interfaces/http-go/` show the same cargo domain, unchanged from Chapter 5's contract and Chapters 6 and 7's providers, answering real HTTP requests in both languages. For HTTP and REST protocol mechanics this chapter leans on without re-explaining (status code semantics, content negotiation, resource naming), see the sibling site [Designing Cloud-Native APIs: REST](https://github.com/patterncatalyst/api-patterns-and-practices-rest); this chapter's job is what changes when the thing answering those requests is a WebAssembly component rather than a conventional server process.

{% include excalidraw.html file="11-wasi-http-request-path" alt="A curl client box sends GET /cargo/CARGO-USNYC-DEHAM (or GET /cargo/NOPE) to a wasmtime serve -S cli box running composed.wasm on 127.0.0.1:8080. An outer frame labeled composed.wasm, wac plug output, contains two boxes: the http-rust or http-go adapter, exporting wasi:http/incoming-handler and importing booking and handling (resolved by wac plug), and the part2 cargo provider (Rust or Go), exporting booking and handling, noted as a fresh instance per request with in-memory state, doing book-cargo then get-cargo in one request. Arrows: HTTP request from curl to wasmtime serve, incoming-handler.handle from wasmtime serve into the adapter, an amber WIT call arrow labeled book-cargo and get-cargo from the adapter down into the provider, a dashed return arrow labeled 200 JSON or 404 error from the provider back to the adapter, and an HTTP response arrow from wasmtime serve back to curl. A caption notes Rust and Go front doors produce byte-identical JSON, and an id that is never booked legitimately misses get-cargo and maps to a 404." caption="Figure 11.1 — one HTTP request's path from curl through wasmtime serve into a composed wasi-http component, and back out as JSON." %}

## The `wasi:http/proxy` world

`http-rust/wit/world.wit` is short enough to quote in full, and every line in it earns a sentence:

```wit
package patterncatalyst:cargo-http@0.1.0;

/// An HTTP front door for the cargo domain, as a WebAssembly component.
///
/// This world INCLUDES `wasi:http/proxy` (so the component exports
/// `wasi:http/incoming-handler` and `wasmtime serve` can drive it directly) and
/// additionally IMPORTS the three cargo interfaces from the repository
/// contract (`patterncatalyst:cargo`, supplied as a path dependency in
/// Cargo.toml — the contract stays pristine). The handler terminates HTTP and
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

`include wasi:http/proxy@0.2.8` is a WIT `include`, not an `import`: it pulls an entire predefined world's imports and exports into this one wholesale, rather than naming one interface. The `proxy` world, as the upstream `wasi-http` package defines it, exports `wasi:http/incoming-handler` and imports a narrow slice of WASI (`wasi:io/streams`, `wasi:io/poll`, `wasi:clocks/monotonic-clock`, and `wasi:http/outgoing-handler` among them) sized for something that proxies or terminates HTTP, not a general-purpose program. Everything below that `include` line is this chapter's own addition: three `import` statements pulling in `types`, `booking`, and `handling` from `patterncatalyst:cargo`, the identical contract Chapter 5 defined and Chapters 6 and 7 implemented against. The world declares two jobs for one component at once: be an HTTP server (from the included proxy world) and be a cargo-domain caller (from the three explicit imports). Composition is what turns the second job from a compile-time obligation into a runtime capability, the same way it did in Chapter 8.

`http-go/wit/world.wit` states the identical three imports and the identical `include wasi:http/proxy@0.2.8` line, under its own package name (`patterncatalyst:cargo-http-go@0.1.0`) because `wit-bindgen-go` resolves a WIT directory tree with no path-dependency mechanism of its own, so the Go side keeps a read-only copy of the cargo contract under its own `wit/deps/cargo` rather than pointing at `contracts/wit/` the way Cargo.toml does. The repository contract itself is never edited by either side; only the local `world.wit` files that reference it differ in how they reach it.

## Naming every `wasi:*` package by hand

`http-rust/Cargo.toml`'s `[package.metadata.component.target.dependencies]` table lists seven path dependencies, and every one of them exists because `cargo-component`, unlike `wasm-tools`, will not discover a WIT package on its own just because the file sits under `wit/deps`:

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

Six of those seven entries are `wasi:*` packages that `include wasi:http/proxy@0.2.8` transitively needs just to resolve: `wasi:http` for the proxy world itself, then `wasi:io`, `wasi:clocks`, `wasi:random`, `wasi:cli`, `wasi:filesystem`, and `wasi:sockets` because the proxy world's own dependency graph reaches into all of them even though the world only imports a subset at the top level. Drop any one line and `cargo component build` fails at the `include wasi:http/proxy@0.2.8` statement with a `package not found` error that names the missing package, not the missing dependency declaration, which is the detail that costs a reader real time the first time it happens. The seventh entry, `"patterncatalyst:cargo" = { path = "../../../contracts/wit" }`, is the same relative path dependency Chapter 6's Decision callout already covers: pointing at the shared contract rather than vendoring a copy, so the three cargo interfaces this component imports cannot drift from what Chapters 6 and 7 export.

## The handler: Rust

`http-rust/src/lib.rs` is the whole HTTP front door, and its shape follows directly from the `incoming-handler` contract: one function, `handle`, taking an `IncomingRequest` and a `ResponseOutparam`, with no return value, because the response is delivered by writing into the outparam rather than returning it:

```rust
impl Guest for Component {
    fn handle(request: IncomingRequest, response_out: ResponseOutparam) {
        let path = request.path_with_query().unwrap_or_default();
        let raw = path.split('?').next().unwrap_or("");

        let id = match raw.strip_prefix("/cargo/") {
            Some(rest) if !rest.is_empty() => rest.to_string(),
            _ => {
                send(
                    response_out,
                    404,
                    br#"{"error":"not found","hint":"GET /cargo/{id}"}"#,
                );
                return;
            }
        };

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
                    Ok(cargo) => { /* ...build and send the 200 JSON body... */ }
                    Err(e) => send_error(response_out, &e),
                },
                Err(e) => send_error(response_out, &e),
            }
            return;
        }

        // Any other id is never booked, so get-cargo legitimately misses.
        match booking::get_cargo(&id) {
            Ok(cargo) => { /* ...200 with just the tracking id... */ }
            Err(e) => send_error(response_out, &e),
        }
    }
}
```

`booking::book_cargo` and `booking::get_cargo` are calls across the component boundary, into whatever provider `wac plug` eventually composes this adapter with; `use bindings::patterncatalyst::cargo::booking;` at the top of the file is the only place this source file names the provider at all, and it names it as an interface, not an implementation. The routing itself is five lines of string matching against a path a real REST API would route far more elaborately (see the sibling REST site for that); what belongs in this chapter is the `send` helper underneath it, because it is where the `wasi:http` resource model shows up directly:

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

The comment in the source states the ordering constraint directly: `resp.body()` has to run before `ResponseOutparam::set` consumes `resp` by value, because `wasi:http`'s resources are move-only the way every Component Model resource is (Chapter 3 introduced that constructor/destructor/method shape; this is the first chapter where getting the order wrong produces a real compile error rather than an abstract rule). The handler for `GET /cargo/CARGO-USNYC-DEHAM` builds its 200 body by hand with `format!`, not a JSON library, because the response shape is four fields and a nested price object and pulling in `serde_json` for that would be weight this example doesn't need:

{% raw %}
```rust
let body = format!(
    "{{\"tracking_id\":\"{}\",\"origin\":\"{}\",\"destination\":\"{}\",\"weight_kg\":{},\"price\":{{\"amount\":\"{}\",\"currency\":\"{}\"}}}}",
    json_escape(&cargo.tracking_id),
    json_escape(&cargo.origin.unlocode),
    json_escape(&cargo.destination.unlocode),
    cargo.weight_kg,
    json_escape(&b.price.amount),
    json_escape(&b.price.currency),
);
```
{% endraw %}

`send_error` maps the four `CargoError` variants Chapter 10 defined onto HTTP status codes directly: `NotFound` to 404, `InvalidBooking` and `InvalidLocation` to 400, `Conflict` to 409. That mapping is the one piece of this handler that is this chapter's own design decision rather than something the WIT contract or `wasi:http` dictates: `cargo-error` carries no HTTP semantics of its own, so some layer has to decide that `not-found` means 404 specifically, and here that layer is the adapter, not the provider.

## The same front door in Go

`http-go/main.go` solves the identical problem with TinyGo's reactor export model from Chapter 7, wiring the handler during `init()` rather than exporting a function the WIT tooling finds by name:

```go
// Reactor export: wire up the handler during package init so it is live by the
// time `_initialize` returns and the host delivers the first request.
func init() {
	incominghandler.Exports.Handle = handle
}

func main() {}
```

The routing in `handle` matches the Rust version line for line in intent, down to splitting on the first two `-` characters and checking for a three-part `CARGO-{ORIGIN}-{DEST}` shape before booking. `cm.Result`'s `.Result()` method, the same three-value `(value, error, isErr)` shape Chapter 7 introduced for the Go bindings, carries both `booking.BookCargo` and `booking.GetCargo` across the boundary:

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

Go's `send` helper hits the same move-before-consume ordering Rust's does, expressed through `go.bytecodealliance.org/cm`'s generated types instead of Rust ownership:

```go
// Obtain the body handle before handing the response to the outparam: the
// set call consumes the OutgoingResponse. OK() is a pointer method, so the
// cm.Result must live in a local first.
bodyRes := resp.Body()
outBody := *bodyRes.OK()
ok := cm.OK[cm.Result[httptypes.ErrorCodeShape, httptypes.OutgoingResponse, httptypes.ErrorCode]](resp)
httptypes.ResponseOutparamSet(responseOut, ok)
```

Go has no borrow checker to catch the ordering mistake at compile time the way Rust's move semantics would, so the comment here is doing more work than its Rust counterpart, which is only a convenience note. `sendError` reads the `CargoError` variant's `String()` form and checks its prefix (`"not-found"`, `"conflict"`) rather than matching on an enum, because `cm`'s generated variant type does not hand back a Go-native switchable case the way `bindgen`'s Rust enum does; the mapping to status codes is otherwise identical to the Rust side. `build.sh` regenerates bindings with `wit-bindgen-go`, compiles a `wasip1` reactor core module with TinyGo, then runs the same `wasm-tools component embed` plus `component new --adapt` pipeline Chapter 7's provider used, because `incoming-handler` is a reactor export and TinyGo 0.43's one-shot `-target=wasip2` path still cannot reconcile WASI versions cleanly, the identical constraint Chapter 7 documented for the provider itself. No new TinyGo limitation shows up in this chapter; the HTTP front door inherits exactly the build path the provider already established.

{% include excalidraw.html file="11-build-compose-serve-pipeline" alt="http-rust builds with cargo component build release to cargo_http_rust.wasm. http-go builds with build.sh, which runs wit-bindgen-go, tinygo, and wasm-tools component new adapt, producing cargo-http-go.wasm. A part2 provider box holds cargo_rust.wasm or cargo-go.wasm, built from its own recipe and not edited here. Arrows from all three feed into a wac plug box: wac plug --plug part2 provider http component -o composed.wasm, with the provider as --plug and the http component as the socket. An amber arrow labeled composed.wasm leads down into a final box: wasmtime serve -S cli composed.wasm --addr 127.0.0.1:8080, curl /cargo/CARGO-USNYC-DEHAM returns 200 JSON, curl /cargo/NOPE returns 404 JSON. A caption notes two toolchains and one WIT world produce byte-identical responses." caption="Figure 11.2 — two toolchains, one WIT world, one wac recipe: building, composing, and serving both front doors." %}

## Composing and serving: `wac plug` plus `wasmtime serve -S cli`

The full recipe for the Rust side, taken directly from `examples/part3-interfaces/README.md`, is four commands and two `curl` calls:

```bash
( cd http-rust && cargo component build --release )
wac plug --plug <part2 rust provider cargo_rust.wasm> \
         http-rust/target/wasm32-wasip1/release/cargo_http_rust.wasm \
         -o composed-http-rust.wasm
wasmtime serve -S cli composed-http-rust.wasm --addr 127.0.0.1:8080 &
curl http://127.0.0.1:8080/cargo/CARGO-USNYC-DEHAM
# {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/cargo/NOPE   # 404
```

`wac plug --plug <PROVIDER> <CONSUMER> -o out.wasm` is the same orientation Chapter 8 established: the provider, which exports the three cargo interfaces, is the `--plug`; the HTTP adapter, which imports them, is the positional socket argument. Composing with the TinyGo side is identical with `http-go/cargo-http-go.wasm` standing in for the Rust artifact, run against the Go provider, and `verify.sh`'s own `serve_assert` helper runs both compositions against both providers in a loop, asserting the same expected JSON string against each:

```bash
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

serve_assert() {
  local label="$1" composed="$2" port="$3"
  local base="http://127.0.0.1:$port"
  wasmtime serve -S cli "$composed" --addr "127.0.0.1:$port" >"$log" 2>&1 &
  # ...wait for the server, then...
  body="$(curl -s "$base/cargo/CARGO-USNYC-DEHAM")"
  assert_eq "$EXPECTED_JSON" "$body" "$label GET /cargo/CARGO-USNYC-DEHAM body"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base/cargo/NOPE")"
  assert_eq "404" "$code" "$label GET /cargo/NOPE status"
}
```

Both calls to `serve_assert` in `verify.sh`, one for `composed-http-rust.wasm` and one for `composed-http-go.wasm`, assert against the literal same `EXPECTED_JSON` string, which is the chapter's proof claim made executable: Rust and TinyGo produce byte-identical JSON from the identical request, through two separately built toolchains, composed with two separately built providers.

`-S cli` on the `wasmtime serve` command line is not optional, and the failure mode without it is specific enough to quote rather than paraphrase. `wasmtime serve` by default links against a restricted `wasi:http/proxy` linker, narrower than the full WASI command environment, because a proxy is supposed to need less host access than a general-purpose program. But both the Rust `std`/adapter layer and the Part 2 provider (built the ordinary way, not stripped down for this chapter) still import `wasi:cli/environment` and `wasi:filesystem`, and the default proxy linker does not satisfy either one. Run `wasmtime serve composed-http-rust.wasm` without the flag and the failure surfaces at the first request, not at startup: `instance export get-environment ... implementation is missing`. `-S cli` tells `wasmtime serve` to enable the full WASI CLI capability set inside what is otherwise a proxy-shaped linker, which is the specific gap the `proxy` world's narrow import set leaves for a component that, in practice, still links against ordinary Rust or Go standard library code underneath its HTTP-specific surface.

## Why book then get in one request

The handler's `book_cargo` followed immediately by `get_cargo` on the same tracking ID looks redundant on first read; the provider's own test suite never does that, because by the time a test calls `get_cargo` the cargo has usually already been booked in an earlier call against the same running instance. `wasmtime serve` breaks that assumption: it creates a fresh instance of the composed component for every single incoming request, and the Part 2 provider keeps cargo state in that instance's own linear memory, not in any store external to it. A `get_cargo` call on a cold instance that nothing has booked yet always returns `cargo-error::not-found`, correctly, because from that instance's point of view nothing was ever booked. Booking first, inside the same request, is how this handler demonstrates a cross-component call that returns live data without pretending the provider has a durable state store it does not actually have; it is also how the 404 path reflects the provider's actual state rather than a staged response. Any ID that does not parse as `CARGO-{ORIGIN}-{DEST}` skips the booking branch entirely and falls straight through to `get_cargo` on an ID nothing ever created, so `GET /cargo/NOPE`'s 404 is the provider's own `not-found` case, mapped through `send_error` the same way any other `CargoError` would be, not a special-cased short-circuit in the handler.

## Consuming HTTP from a component

The vendored `wasi:http` package under `wit/deps/http` in both `http-rust` and `http-go` includes `wasi:http/outgoing-handler` as part of the standard `wasi-http` dependency closure, and both languages' generated bindings expose it; neither this chapter's Rust handler nor its Go handler calls it. This chapter's examples are server-side only: a component that terminates inbound HTTP and answers from the cargo domain, never one that makes an outbound HTTP call of its own. `outgoing-handler` is the interface a component would use to act as an HTTP *client*, issuing a request and awaiting a response the same shape `incoming-handler` receives in reverse, and it is already present and resolvable in this example's dependency tree because `wasi:http` ships both directions of the contract as one package. A production front door that needs to call another service over HTTP from inside the sandbox would import `wasi:http/outgoing-handler` explicitly in its own world, the same way this chapter's world imports the three cargo interfaces; this book does not build and verify that example, so treat the interface as present and real, not as a gap in the `wasi:http` specification itself.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Let a component terminate HTTP directly against <code>wasmtime serve</code> when the entire request lifecycle, routing, response construction, and every service call it makes fit inside the <code>wasi:http/proxy</code> world's narrow import set, and when per-request process isolation (a fresh instance per request, no shared in-process state) is a feature rather than a limitation for the workload. That shape fits request/response work over a stable domain contract well, which is exactly this chapter's cargo front door, and it fits any handler where the proxy world's restricted imports (no raw sockets, no filesystem by default, `wasi:cli` only when a host opts a reader in with <code>-S cli</code>) are an acceptable, even desirable, ceiling on what the handler can reach. Put a gateway in front of a component instead when the workload needs state that must survive across requests without re-deriving it from a provider call each time, when it needs capabilities the proxy world does not include at all (long-lived connections, non-HTTP protocols, broad filesystem or process access), or when request-level concerns, TLS termination, authentication, rate limiting, protocol translation, belong at a layer that should not have to be recompiled and redeployed every time the domain logic one layer in changes. This chapter's own front door earns the direct-serve shape because its entire job, book then read one cargo record and return JSON, never leaves what <code>wasi:http/proxy</code> plus three domain imports can express; Part 5's sidecar and ambassador chapters are where a component sits behind something else instead, for reasons this callout's second half names.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning) — the wasi-http chapter's treatment of the proxy world and the `incoming-handler`/`outgoing-handler` split this chapter builds one half of.
- Shashank Jain, *WebAssembly for Cloud* (Apress) — cross-language HTTP front doors and the production trade-offs of composing a protocol adapter with a domain provider, the same split this chapter's `wac plug` recipe makes concrete.
- [wasi-http WIT definitions](https://github.com/WebAssembly/wasi-http) — the authoritative `proxy` world and the `incoming-handler`/`outgoing-handler` interfaces `http-rust/wit/world.wit` and `http-go/wit/world.wit` both include.
- [Wasmtime CLI reference: `wasmtime serve`](https://docs.wasmtime.dev/cli-options.html) — the `-S cli` flag and the rest of the proxy linker's capability switches named directly in this chapter's gotcha.
- [wac — WebAssembly Composition tool](https://github.com/bytecodealliance/wac) — `wac plug`'s plug/socket reference, reused here unchanged from Chapter 8's command-component composition.
- Chapter 8, "Composing Components and WIT Worlds" — the socket/plug model this chapter extends from `wasi:cli/run` to `wasi:http/incoming-handler`.
- Chapter 7, "First Component in Go" — the TinyGo wasip1-reactor-plus-`wasm-tools` build pipeline `http-go/build.sh` reuses without modification.
- Chapter 10, "Error and Exception Handling" — the `cargo-error` variant `send_error` maps onto HTTP status codes in both languages here.
- [Designing Cloud-Native APIs: REST](https://github.com/patterncatalyst/api-patterns-and-practices-rest) (sibling site) — HTTP and REST protocol depth (status semantics, resource design, content negotiation) this chapter assumes throughout and does not re-teach.

# Part 3 — Interfaces: HTTP and gRPC (and networking)

Runnable examples for Part 3. Everything here **imports** the cargo domain from
the Part 2 provider components (`examples/part2-building-components/{rust,go}`)
by **composing** with them (`wac plug`) — the Part 2 tree and
`contracts/wit/` are reused as-is, never edited.

Run the whole thing:

```bash
bash examples/part3-interfaces/verify.sh
```

`verify.sh` builds the Part 2 providers with their own recipes, builds each
Part 3 artifact, composes, serves/curls/round-trips, and asserts.

## Layout

| Dir | Chapter | What it is |
| --- | --- | --- |
| `http-rust/` | ch11 | Rust `wasi:http/incoming-handler` component (cargo-component). Imports the cargo `booking` interface; serves `GET /cargo/{id}`. |
| `http-go/` | ch11 | The same in TinyGo (wit-bindgen-go + reactor pipeline). |
| `proto/cargo.proto` | ch12 | Shared protobuf contract (messages + `CargoService`). |
| `proto-component/proto-rust/` | ch12 | Component that uses **prost inside the sandbox** to decode/encode protobuf (`codec.get-cargo(list<u8>) -> list<u8>`). |
| `proto-component/proto-host/` | ch12 | Native host that drives the protobuf round trip and asserts the fields. Language-agnostic — drives both the Rust and the TinyGo codec. |
| `proto-go/` | ch12 | TinyGo codec component using a **reflection-free protobuf wire codec** (`wire.go`). |
| `grpc-bridge/` | ch12 | Native **tonic** gRPC server that terminates gRPC and dispatches each RPC to the unchanged Part 2 Rust provider over WIT. |
| `sockets-rust/` | ch13 | Rust `wasi:sockets` outbound TCP client with reconnect + exponential backoff with jitter; capability-scoped. |
| `sockets-go/` | ch13 | TinyGo `wasi:sockets` client (reactor). Builds + validates; runtime gap documented below. |

Vendored under each component's `wit/deps/` is a pinned **wasi 0.2.x** WIT set.
The Rust HTTP/sockets crates vendor the internally-consistent **0.2.8** set from
the `wasi-http` v0.2.8 release; the TinyGo sockets crate vendors the **0.2.12**
set (to match the TinyGo reactor adapter). wasmtime 50 satisfies any `0.2.x`
import through semver-compatible component linking, so the skew composes fine.

Vendored reactor adapter (`*/adapters/wasi_snapshot_preview1.reactor.wasm`,
SHA256 `73b01f85e42e99c890efbbf619cd765e04e5809da36d976b87fc64abd87f5812`) is the
same wasmtime v50 reactor adapter the Part 2 Go provider uses.

## Exact recipes

### ch11 — wasi-http (`wasmtime serve`)

```bash
# Rust
( cd http-rust && cargo component build --release )
wac plug --plug <part2 rust provider cargo_rust.wasm> \
         http-rust/target/wasm32-wasip1/release/cargo_http_rust.wasm \
         -o composed-http-rust.wasm
wasmtime serve -S cli composed-http-rust.wasm --addr 127.0.0.1:8080 &
curl http://127.0.0.1:8080/cargo/CARGO-USNYC-DEHAM
# {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/cargo/NOPE   # 404

# TinyGo
bash http-go/build.sh
wac plug --plug <part2 go provider cargo-go.wasm> http-go/cargo-http-go.wasm -o composed-http-go.wasm
wasmtime serve -S cli composed-http-go.wasm --addr 127.0.0.1:8081 &
# same JSON, same 404
```

Because `wasmtime serve` uses a restricted `wasi:http/proxy` linker and both the
Rust adapter/std and the provider import `wasi:cli/environment` +
`wasi:filesystem`, the composed component needs **`-S cli`** (enables the full
WASI CLI APIs in the serve linker). Without it `wasmtime serve` fails with
`instance export get-environment ... implementation is missing`.

The handler **books then reads** within one request: the Part 2 provider keeps
domain state in instance memory and `wasmtime serve` uses a fresh instance per
request, so a cold `get-cargo` always misses. Any id that is not a
`CARGO-{ORIGIN}-{DEST}` triple is never booked, so it maps to
`cargo-error::not-found` → HTTP 404.

### ch12 — protobuf-in-Wasm and the gRPC bridge

```bash
# prost inside the component (Rust), driven by the native host
( cd proto-component/proto-rust && cargo component build --release )
( cd proto-component/proto-host  && cargo build --release )
wac plug --plug <rust provider> \
  proto-component/proto-rust/target/wasm32-wasip1/release/cargo_proto_rust.wasm \
  -o composed-proto-rust.wasm
proto-component/proto-host/target/release/cargo-proto-host composed-proto-rust.wasm
# host: encoded GetCargoRequest (19 bytes) ...
# host: received 91 bytes of protobuf response
# host: ASSERT OK — prost round trip through Wasm: tracking_id=CARGO-USNYC-DEHAM ... price=1500.00 USD

# reflection-free protobuf inside the component (TinyGo), SAME host
bash proto-go/build.sh
wac plug --plug <go provider> proto-go/cargo-proto-go.wasm -o composed-proto-go.wasm
proto-component/proto-host/target/release/cargo-proto-host composed-proto-go.wasm   # byte-identical 91-byte response

# gRPC bridge (tonic) — in-process client round trip
( cd grpc-bridge && cargo test --release -- --nocapture )
# grpc-bridge: tonic client round trip OK (GetCargo + BookCargo through Wasm)
# run the server for manual use / grpcurl:
( cd grpc-bridge && cargo run --release )   # serves CargoService on 127.0.0.1:50051
```

`protoc` (libprotoc) must be on PATH: both the prost component and the tonic
bridge generate code from `proto/cargo.proto` at build time. Pinned versions:
**prost 0.14.4**, **tonic 0.14.6** (tonic 0.14 split the prost integration into
`tonic-prost` / `tonic-prost-build`). Cargo.lock is committed for every crate.

The split ch12 makes: **gRPC-the-transport** needs the host bridge (there is no
in-component gRPC server), but **Protobuf-the-serialization** runs fully
server-side inside a component.

### ch13 — wasi-sockets reconnect

```bash
( cd sockets-rust && cargo component build --release )
W=sockets-rust/target/wasm32-wasip1/release/sockets-client-rust.wasm

# capability WITHHELD -> denied
wasmtime run "$W" 34599 3 50
# ... attempt 1/3 failed: access-denied ... network access DENIED by the host capability boundary

# capability GRANTED + listener appears after a delay -> reconnects
( sleep 1.5; python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",34601));s.listen();s.accept()' ) &
wasmtime run -S inherit-network "$W" 34601 20 100
# ... attempt 1..4 connection-refused, backoff 126/299/511/1053ms ...
# sockets-rust: connected to 127.0.0.1:34601 on attempt 5
```

The component can only open a connection when the host **grants** network access
(`-S inherit-network`). Without it, `wasi:sockets` returns `access-denied` at the
capability boundary — the whole point of the demo.

## Gotchas worth a chapter callout

1. **cargo-component does not auto-scan `wit/deps`.** Unlike `wasm-tools`, it only
   resolves WIT packages declared in `[package.metadata.component.target.dependencies]`.
   Every vendored `wasi:*` package (and the `patterncatalyst:cargo` contract) is
   listed there as a path dependency; just dropping files under `wit/deps/` gives
   `package not found` at the `include wasi:http/proxy` line.
2. **`wasmtime serve` needs `-S cli`** for a Rust/Go component whose adapter+std
   (and the composed provider) import `wasi:cli/environment` and
   `wasi:filesystem`. The default proxy linker omits them.
3. **TinyGo 0.43 CAN export `wasi:http/incoming-handler`** via the explicit
   wasip1 reactor + `wasm-tools component embed` + `component new --adapt reactor`
   pipeline. No fallback was needed; the Go front door serves JSON byte-identical
   to the Rust one.
4. **TinyGo + `google.golang.org/protobuf` COMPILES but TRAPS at runtime.** The
   reflection-based library builds under TinyGo 0.43, but `proto.Marshal` reaches
   `reflect.Type.MethodByName` inside `impl.MessageInfo.makeStructInfo`, which
   TinyGo's partial `reflect` does not implement — a `wasm unreachable` trap. The
   working path is a **reflection-free** codec: `proto-go/wire.go` encodes/decodes
   the proto3 wire format directly (varints, length-delimited strings/messages,
   fixed64 doubles) and interoperates byte-for-byte with the Rust prost side
   (a vtprotobuf-generated marshaller is the production-grade reflection-free
   option; the hand-written codec keeps the example self-contained).
5. **TinyGo 0.43 `wasi:sockets` — no clean runtime path (documented gap).** The
   `sockets-go` component builds and validates, but:
   - As a **command** (`wasmtime run`), it traps at `_start` with
     `assertion failed at adapter line 2404` in `random_get`: TinyGo's runtime
     seeds randomness (`arc4random`) during startup, and the wasip1→wasip2
     **command** adapter's `random_get` asserts when invoked that early.
   - As a **reactor** driven by a custom native host, the connect dance hangs:
     TinyGo's asyncify-based `pollable.block()` does not resolve the
     `wasi:sockets` connect/timer pollables under a hand-rolled embedding (tried
     both the sync and the async wasmtime-wasi linker). The Rust client works
     because it runs under the `wasmtime run` CLI's own executor.

   So **Rust is the live sockets proof**; the TinyGo sockets component is kept as
   a build+validate artifact. (The Rust client imports `wasi:random` directly
   with no such issue; the Go client derives jitter from the monotonic clock to
   keep its import set minimal.)
6. **`wac plug` orientation.** `wac plug --plug <PROVIDER> <CONSUMER> -o out.wasm`:
   the provider (exports `cargo`) is the `--plug`; the HTTP/proto component (imports
   `cargo`) is the socket. Composed bytes are non-deterministic (wac#216); assert
   runtime behaviour, not bytes.

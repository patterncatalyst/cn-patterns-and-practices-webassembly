---
title: "gRPC with Wasm"
order: 12
part: "Interfaces: HTTP & gRPC"
description: "Protobuf runs inside a Wasm component, gRPC transport does not: encode and decode in the sandbox, and terminate gRPC in a native bridge in front of the unchanged provider."
duration: "20 min read"
---

## Learning objectives

By the end of this chapter you can:

- Separate Protobuf-the-encoding from gRPC-the-transport and say which one a component can do today.
- Build a Rust component that decodes a protobuf request and encodes a protobuf response with prost, over a `list<u8>` WIT boundary.
- Explain why `google.golang.org/protobuf` compiles under TinyGo but traps at runtime, and replace it with a reflection-free wire codec.
- Build a native tonic bridge that terminates gRPC and dispatches each RPC into an unchanged Wasm provider over WIT.
- Decide whether a service needs only protobuf in Wasm or also a gRPC bridge.

## Why this matters

A component behind `wasmtime serve` answers HTTP directly because `wasi:http/incoming-handler` does the work a reverse proxy usually does. That treats wire format and transport as one decision. gRPC splits them.

gRPC bundles a serialization format (Protobuf: varints, length-delimited fields, fixed-width numerics) and a transport contract (HTTP/2 framing, streaming, and trailers that carry the final status after the body). The sibling site [api-patterns-and-practices-grpc](https://github.com/patterncatalyst/api-patterns-and-practices-grpc) covers the four RPC shapes, framing, interceptors and deadlines. The question here is narrower: which half runs inside a component?

Protobuf does. Messages compile with prost inside a component, and a native host drives a complete encode, call, decode round trip. The transport does not. `wasi:http/incoming-handler` answers HTTP/1.1-shaped request/response pairs; it has no streaming and carries no trailers, so no component exports an HTTP/2 server today. gRPC terminates in a native **tonic** process that dispatches each RPC into the unchanged Rust provider over WIT: gRPC in front of Wasm, never inside it.

{% include excalidraw.html file="12-encoding-vs-transport-split" alt="Two side-by-side panels. Left panel, PROTOBUF the encoding: varints length-delimited fields fixed64 doubles, pure computation decode bytes build a struct encode bytes, runs fully INSIDE the sandbox with prost in Rust or a reflection-free codec in TinyGo, needs nothing the component model denies. Right panel, gRPC the transport: HTTP/2 framing trailers bidirectional streaming, needs a listening server socket and an HTTP/2 stack, no component HTTP/2 server surface today since wasi:http exports a request handler not this, terminated by a host-mediated bridge in front of the component. Caption: same proto/cargo.proto, two different verdicts: the message format runs in Wasm, the RPC transport does not, yet." caption="Figure 12.1: Protobuf-the-encoding and gRPC-the-transport are separable concerns with separate verdicts in today's component model." %}

## One contract, two generators

Both halves read one `.proto` file:

```proto
message GetCargoRequest {
  string tracking_id = 1;
}

message GetCargoResponse {
  // Populated on success.
  Cargo cargo = 1;
  Money price = 2;
  // Non-empty when the cargo could not be produced (for example a tracking id
  // that is not a CARGO-{ORIGIN}-{DEST} triple, mapping a domain
  // cargo-error::not-found onto a response-level error string).
  string error = 3;
}

message BookCargoRequest {
  Location origin = 1;
  Location destination = 2;
  string arrival_deadline = 3;
  double weight_kg = 4;
}

message BookCargoResponse {
  string booking_id = 1;
  string cargo_id = 2;
  Money price = 3;
  string status = 4;
  string error = 5;
}

service CargoService {
  rpc GetCargo(GetCargoRequest) returns (GetCargoResponse);
  rpc BookCargo(BookCargoRequest) returns (BookCargoResponse);
}
```

`prost-build` inside the component generates message structs only; a messages-only generator never sees the `service` block, so the component gets Protobuf's types with no awareness of `CargoService`. `tonic-prost-build` inside the bridge generates the messages plus the `CargoServiceServer` and `CargoServiceClient` stubs, because the bridge is the one artifact that must be a gRPC endpoint.

## Protobuf inside the sandbox

The `codec` interface moves `list<u8>` in both directions:

```wit
package patterncatalyst:cargo-proto@0.1.0;

/// Protobuf codec for the cargo domain, as a WebAssembly component.
///
/// The `codec` interface takes protobuf REQUEST bytes and returns protobuf
/// RESPONSE bytes. The encode/decode happens with prost entirely inside the
/// Wasm sandbox: this is Protobuf-the-serialization running server-side, as
/// distinct from gRPC-the-transport (which the grpc-bridge terminates natively).
interface codec {
    /// Decode a protobuf `GetCargoRequest`, dispatch to the imported cargo
    /// domain, and return a protobuf-encoded `GetCargoResponse`. Returns `err`
    /// only when the request bytes fail to decode; a domain miss is reported in
    /// the response's `error` field (still a valid protobuf message).
    get-cargo: func(request: list<u8>) -> result<list<u8>, string>;
}

/// The component: decodes/encodes protobuf with prost (export `codec`) and
/// calls the cargo domain across the component boundary (imports). Composed
/// with a `cargo` provider via `wac plug`, the imports are satisfied.
world cargo-proto {
    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;

    export codec;
}
```

WIT has no concept of a protobuf message. The Canonical ABI moves an opaque byte list, and the component decodes and re-encodes it with a library compiled into the `.wasm`. The world still imports `patterncatalyst:cargo/booking` and `types`, so the codec is a consumer of the cargo domain and composes with a provider through `wac plug` like any other.

The prost dependency is pinned exact and trimmed for Wasm:

```toml
[dependencies]
wit-bindgen-rt = { version = "0.44.0", features = ["bitflags"] }
# prost runs INSIDE the component (wasm32-wasip1). Pinned exact; Cargo.lock
# committed. `default-features = false` drops prost's `std`-only extras that are
# unnecessary here and keeps the wasm build lean; `prost-derive` is pulled in by
# the derive feature for #[derive(Message)].
prost = { version = "=0.14.4", default-features = false, features = ["derive"] }

[build-dependencies]
# prost-build invokes protoc at build time to turn proto/cargo.proto into Rust
# message structs. Messages only: the service in the .proto is ignored by this
# messages-only generator (the gRPC service is handled by the tonic bridge).
prost-build = "=0.14.4"
```

`build.rs` runs on the build host, not in the sandbox:

```rust
fn main() {
    let proto = "../../proto/cargo.proto";
    println!("cargo:rerun-if-changed={proto}");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    prost_build::Config::new()
        .out_dir(&out)
        .compile_protos(&[proto], &["../../proto"])
        .expect("compile cargo.proto with prost-build (is protoc on PATH?)");
}
```

`prost-build` shells out to `protoc`, which must be on `PATH`, to parse the grammar. By the time the component compiles for `wasm32-wasip1`, `pb::GetCargoRequest` and `pb::GetCargoResponse` are ordinary Rust types with `encode` and `decode`.

## Decode, dispatch, encode

The handler decodes on the outside of the WIT boundary and dispatches on the inside:

```rust
impl Guest for Component {
    fn get_cargo(request: Vec<u8>) -> Result<Vec<u8>, String> {
        // prost DECODE inside the sandbox.
        let req = pb::GetCargoRequest::decode(request.as_slice())
            .map_err(|e| format!("protobuf decode error: {e}"))?;

        let id = req.tracking_id;
        let parts: Vec<&str> = id.splitn(3, '-').collect();
        if !(parts.len() == 3 && parts[0] == "CARGO") {
            // Not a known id shape: dispatch anyway so a genuine domain miss is
            // encoded as a protobuf response-level error.
            return Ok(match booking::get_cargo(&id) {
                Ok(c) => encode_ok(&c, None),
                Err(e) => error_response(err_message(&e)),
            });
        }

        let spec = RouteSpec {
            origin: location_for(parts[1]),
            destination: location_for(parts[2]),
            arrival_deadline: ARRIVAL_DEADLINE.to_string(),
        };
        match booking::book_cargo(&spec, DEFAULT_WEIGHT_KG) {
            Ok(b) => match booking::get_cargo(&b.cargo_id) {
                Ok(cargo) => Ok(encode_ok(&cargo, Some(&b.price))),
                Err(e) => Ok(error_response(err_message(&e))),
            },
            Err(e) => Ok(error_response(err_message(&e))),
        }
    }
}
```

The WIT `result<list<u8>, string>` is reserved for a request that fails to decode. A cargo that can't be found is still a successful protobuf response with a non-empty `error` field, the convention of a REST API that returns `200 OK` with a problem payload. `encode_ok` copies the WIT `Cargo` and `Money` records into their `pb::` counterparts and calls `encode_to_vec()`.

Every step here is arithmetic and memory access: no socket, thread or clock. That is why Protobuf clears a bar the gRPC transport can't. A component is denied ambient access to the outside world, but never denied computation on bytes it already holds.

A native host drives the composed component: it prost-encodes a `GetCargoRequest`, calls `codec.get-cargo`, decodes the response and checks every field. Its WIT world only exports `codec`; `wac plug` satisfies the component's `booking` imports before the host sees the file. The run prints:

```
host: encoded GetCargoRequest (19 bytes) tracking_id=CARGO-USNYC-DEHAM
host: received 91 bytes of protobuf response
host: ASSERT OK, prost round trip through Wasm: tracking_id=CARGO-USNYC-DEHAM origin=USNYC dest=DEHAM weight_kg=1200.5 price=1500.00 USD
```

Nineteen bytes go in and 91 come back. The component booked the cargo, read it back and encoded the result; the host never touched the cargo domain.

## Protobuf in TinyGo: a reflection-free codec

`google.golang.org/protobuf`, the reflection-based runtime behind every Go gRPC service, compiles under TinyGo 0.43 for `wasip1` and traps at runtime. `proto.Marshal` builds its encoding from a descriptor derived by walking struct fields with `reflect`, and the call chain bottoms out at `reflect.Type.MethodByName` inside `impl.MessageInfo.makeStructInfo`. TinyGo's partial `reflect` doesn't implement it. The type-checker passes because the symbol exists; the component traps with `wasm unreachable` the first time the path runs.

Two replacements work. `vtprotobuf` generates `MarshalVT` and `UnmarshalVT` methods on each message, so no reflection is consulted; teams running Go gRPC at scale adopt it for speed alone. The self-contained option is a hand-written proto3 wire codec, which `proto-go/wire.go` ships for the four messages the service needs:

```go
func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func appendTag(b []byte, field int, wire int) []byte {
	return appendVarint(b, uint64(field)<<3|uint64(wire))
}

func appendString(b []byte, field int, s string) []byte {
	if s == "" {
		return b
	}
	b = appendTag(b, field, 2) // length-delimited
	b = appendVarint(b, uint64(len(s)))
	return append(b, s...)
}

func appendMessage(b []byte, field int, msg []byte) []byte {
	b = appendTag(b, field, 2)
	b = appendVarint(b, uint64(len(msg)))
	return append(b, msg...)
}

func appendDouble(b []byte, field int, f float64) []byte {
	if f == 0 {
		return b
	}
	b = appendTag(b, field, 1) // 64-bit
	var tmp [8]byte
	binary.LittleEndian.PutUint64(tmp[:], math.Float64bits(f))
	return append(b, tmp[:]...)
}
```

Decoding mirrors the encoder: a `readVarint` loop reads the tag, the field number and wire type come from `tag >> 3` and `tag & 0x7`, and `skipField` skips unknown fields instead of rejecting them, so the decoder tolerates additions as a real consumer should. The Go handler runs the same `CARGO-{ORIGIN}-{DEST}` parse, `book-cargo`, `get-cargo` and error-to-field mapping as the Rust one. Only the way bytes are made at the edges differs.

The identical `proto-host` binary drives the composed Go component, and its response is byte-for-byte the Rust component's 91 bytes. The proto3 wire format is precise enough that a hand-written encoder and a generated one agree without coordinating. A project that combines TinyGo and protobuf beyond a demo should plan for `vtprotobuf` or a hand-rolled codec.

{% include excalidraw.html file="12-protobuf-in-component" alt="A caller box on the left sends GetCargoRequest bytes, prost-encoded 19 bytes, into a large accent box labeled codec.get-cargo list u8 arrow result list u8 string. Inside that box, top to bottom: decode via prost in Rust or wire.go in TinyGo turning GetCargoRequest bytes into a tracking id, then dispatch over WIT calling booking.book-cargo and booking.get-cargo, then encode via prost or wire.go turning Cargo and Money into GetCargoResponse bytes. An amber arrow leaves the box to a caller-decodes-response box on the right showing 91 bytes, byte-identical between the Rust prost side and the TinyGo wire codec side. A bold caption reads INSIDE THE WASM SANDBOX, no network, no gRPC transport, just bytes in and bytes out. A second caption notes protobuf is varints, length-delimited fields, fixed64 doubles, pure computation, so it runs in a component with no transport capability at all." caption="Figure 12.2: Protobuf decode, WIT dispatch and protobuf encode all run inside the component. Rust (prost) and TinyGo (a reflection-free wire codec) produce byte-identical output." %}

## Why gRPC can't move into the component

A `CargoService` endpoint needs a server that accepts a TCP connection, negotiates HTTP/2, demultiplexes concurrent streams, reads a request spread over several DATA frames and writes the final status as a trailer after the body. None of that is Protobuf.

`wasi:http/incoming-handler` is called once per request by whatever wraps the component. It has no long-lived bidirectional stream, no trailer channel distinct from response headers and no multiplexing: one request, one response. No `wasi:*` interface exports the transport role a gRPC server needs. A component isn't at fault here; the component model's server-side interfaces don't expose that role yet.

## The bridge: gRPC in front of Wasm

`grpc-bridge` is a `tonic` server that terminates HTTP/2, trailers and the generated `CargoServiceServer` trait natively. For each RPC it instantiates the **unchanged** Rust provider with `wasmtime` and makes the same WIT calls any native host makes. The file header states the design:

```rust
// gRPC-in-FRONT-of-Wasm bridge.
//
// A native host terminates gRPC with tonic and, per RPC, instantiates the
// UNCHANGED part2 Rust provider with wasmtime and dispatches the call over WIT.
// There is no gRPC server inside any component: the bridge is the artifact. prost/tonic are pinned exact (Cargo.lock
// committed).
//
// Run:   cargo-grpc-bridge [ADDR]         (default 127.0.0.1:50051)
// Test:  cargo test --release             (in-process client round trip)
//
// The provider wasm path defaults to the part2 build output and can be
// overridden with CARGO_PROVIDER_WASM.
```

The dependencies, pinned exact:

```toml
tonic = "=0.14.6"
tonic-prost = "=0.14.6"
prost = "=0.14.4"
tokio = { version = "1", features = ["rt-multi-thread", "macros", "net"] }
wasmtime = "50"
wasmtime-wasi = "50"
anyhow = "1"

[dev-dependencies]
tokio-stream = { version = "0.1", features = ["net"] }

[build-dependencies]
tonic-prost-build = "=0.14.6"
```

tonic 0.14 moved its prost integration out of the core crate into `tonic-prost` (runtime) and `tonic-prost-build` (codegen), a breaking change from earlier releases. The build script names the new crate:

```rust
// Generate tonic gRPC server + client stubs and prost messages from the shared
// proto/cargo.proto (protoc required on PATH). tonic 0.14 moved the prost
// integration into tonic-prost-build.
fn main() {
    let proto = "../proto/cargo.proto";
    println!("cargo:rerun-if-changed={proto}");
    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&[proto], &["../proto"])
        .expect("compile cargo.proto with tonic-prost-build (is protoc on PATH?)");
}
```

`build_server(true)` is what the bridge depends on. The component's `prost-build` call generates messages only; this one also generates the server trait and client stub, since the bridge is the gRPC endpoint.

The bridge loads the provider once and gives every RPC its own fresh `Store`, so its own provider instance:

```rust
// Engine + preloaded component, shared across RPCs. Each RPC gets a FRESH Store
// (and therefore a fresh provider instance), which is why GetCargo books before
// it reads: the part2 provider keeps domain state in instance memory.
#[derive(Clone)]
struct Bridge {
    engine: Arc<Engine>,
    component: Arc<Component>,
    linker: Arc<Linker<HostState>>,
}
```

Because the provider keeps booked cargo in instance memory, a cold `GetCargo` would find nothing, so `do_get_cargo` books first and reads back in the same call, as the HTTP handler does. `tokio::task::spawn_blocking` moves the synchronous `wasmtime` WIT call onto a blocking pool and keeps tonic's async executor free:

```rust
#[tonic::async_trait]
impl CargoService for Bridge {
    async fn get_cargo(
        &self,
        request: Request<GetCargoRequest>,
    ) -> Result<Response<GetCargoResponse>, Status> {
        let this = self.clone();
        let tracking_id = request.into_inner().tracking_id;
        let resp = tokio::task::spawn_blocking(move || this.do_get_cargo(tracking_id))
            .await
            .map_err(|e| Status::internal(format!("join error: {e}")))?
            .map_err(Status::internal)?;
        Ok(Response::new(resp))
    }

    async fn book_cargo(
        &self,
        request: Request<BookCargoRequest>,
    ) -> Result<Response<BookCargoResponse>, Status> {
        let this = self.clone();
        let req = request.into_inner();
        let resp = tokio::task::spawn_blocking(move || this.do_book_cargo(req))
            .await
            .map_err(|e| Status::internal(format!("join error: {e}")))?
            .map_err(Status::internal)?;
        Ok(Response::new(resp))
    }
}
```

`do_get_cargo` itself is the plain dispatch a native host would do: instantiate the `cargo` world's bindings, call `booking.book_cargo` then `booking.get_cargo`, and map the WIT result onto the protobuf response. The provider `.wasm` the bridge loads is the same artifact `cargo component build --release` produced, composed against nothing and modified for nothing. The transport problem is solved entirely on the host side of the boundary.

{% include excalidraw.html file="12-grpc-bridge-in-front" alt="A grpcurl or tonic client box on the left sends GetCargo and BookCargo over HTTP/2 into a large user-styled box labeled cargo-grpc-bridge native host. Inside: a tonic transport Server box that terminates gRPC with HTTP/2 trailers and the CargoService trait, then a spawn_blocking box noting fresh Store per RPC and wasmtime component bindgen world cargo, then a dispatch-over-WIT box calling booking.book-cargo and get-cargo. An amber WIT-call arrow leaves the bridge box to an accent box on the right labeled part2 Rust provider component, UNCHANGED, no gRPC, no HTTP/2, no knowledge it is behind a bridge. A bold caption reads GRPC IN FRONT OF Wasm, the bridge is the gRPC server, the component is not and does not need to be. A second caption notes a component has no HTTP/2 server surface today so gRPC-the-transport is terminated natively, one host process in front of an unmodified provider." caption="Figure 12.3: The tonic bridge terminates gRPC and dispatches over WIT into the same unmodified Part 2 provider." %}

## Other shapes

| Shape | Direction | Notes |
| --- | --- | --- |
| tonic bridge (built here) | gRPC in, WIT calls out | One native process owns the transport in front of an unmodified provider |
| Component calling a gRPC service | gRPC out | A component importing `wasi:http/outgoing-handler` can issue the request from inside the sandbox; a different problem from being a server, and not built here |
| gRPC-aware reverse proxy (Envoy-style) | gRPC in, simpler interface out | The bridge idea scaled out: the proxy owns HTTP/2 and gRPC framing, and each component sees `wasi:http` pairs or direct WIT calls |

In every shape something outside the component terminates the gRPC transport.

> **Decision**
>
> Use protobuf in Wasm alone (`codec.get-cargo(list<u8>) -> result<list<u8>, string>`) when the requirement is a versioned, schema-driven binary format and the caller owns its transport: a queue consumer decoding a protobuf event, a pipeline stage, or any function call that happens to use protobuf. Add the tonic bridge as soon as a client you don't control speaks real gRPC: a generated stub in another language, a mesh's gRPC health check, any consumer that opens HTTP/2 and expects trailers. If a future `wasi:http` revision exposes bidirectional streaming with trailers inside a component, the bridge's transport role could move into the sandbox; the toolchain doesn't offer that today.

> **🤖 Explore with your agent**
>
> "In examples/part3-interfaces, add a `string status = 4;` field to `GetCargoResponse` in proto/cargo.proto. Populate it in the Rust codec (proto-component/proto-rust/src/lib.rs) and in the TinyGo wire codec (proto-go/wire.go), rebuild both, compose each with its Part 2 provider using `wac plug --plug`, and run proto-component/proto-host against both. Then apply the decision rule: say whether a consumer that needs this field over gRPC can use the codec alone or needs grpc-bridge, and why."
>
> Check: both composed components still return byte-identical responses from `cargo-proto-host`, and the response length changes by the same amount for each.

## Build, run, observe

```bash
cd examples/part3-interfaces && ./verify.sh
```

The script builds the `proto-rust` prost component and the `proto-go` wire-codec component, composes each with its Part 2 provider and drives both through the same native `proto-host`, which checks tracking ID, both UN/LOCODEs, weight, price amount and currency. It then runs `cargo test --release -- --nocapture` in `grpc-bridge`, which drives a real tonic client over HTTP/2 against the bridge for `GetCargo` and `BookCargo`. Expect `PASS`. `protoc` must be on `PATH` for both builds.

To run the bridge as a server for `grpcurl` or another gRPC client, use `cargo run --release` in `grpc-bridge`; it listens on `127.0.0.1:50051`. `CARGO_PROVIDER_WASM` overrides the provider path.

Experiments:

- Swap `proto-go/wire.go` for `google.golang.org/protobuf` and `proto.Marshal`. The build succeeds and the component traps with `wasm unreachable` on the first call.
- Run `cargo test --release` in `grpc-bridge` before the Part 2 Rust provider is built. `Bridge::new` fails to load the provider component.

## For deeper coverage

- [api-patterns-and-practices-grpc](https://github.com/patterncatalyst/api-patterns-and-practices-grpc): the four RPC shapes, HTTP/2 framing and trailers, interceptors and deadline propagation.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the canonical ABI and the `list<u8>` lowering and lifting behind the `codec.get-cargo` boundary.
- Kelsey Hightower, Brendan Burns, and Joe Beda, *Cloud Native Patterns and Practices*: sidecar and service-mesh framing for why a terminating proxy is the conventional home for a protocol a workload can't speak natively.
- [Protocol Buffers documentation](https://protobuf.dev/): the proto3 wire format the TinyGo codec implements by hand.
- [tonic](https://github.com/hyperium/tonic) and [prost](https://github.com/tokio-rs/prost): the crates pinned exact here; tonic's changelog documents the 0.14 `tonic-prost` split.

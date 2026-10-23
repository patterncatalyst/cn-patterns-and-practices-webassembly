---
title: "gRPC with Wasm"
order: 12
part: "Interfaces: HTTP & gRPC"
description: "Run Protobuf serialization server-side inside a Wasm component, and terminate gRPC itself from a host-mediated bridge in front of the unchanged provider."
duration: "30 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why Protobuf-the-encoding and gRPC-the-transport are separable concerns, and state which one a WebAssembly component can do today and which one it cannot.
- Build a Rust component that uses prost to decode a protobuf request and encode a protobuf response entirely inside the sandbox, over a `list<u8>` WIT boundary.
- Reproduce the TinyGo finding that `google.golang.org/protobuf` compiles under TinyGo 0.43 but traps at runtime, and explain the reflection-free wire codec that works around it.
- Verify cross-language wire interop: a Rust prost-encoded response and a TinyGo wire-codec-encoded response are byte-identical for the same request.
- Build a native tonic bridge that terminates gRPC and dispatches each RPC into an unchanged Wasm provider over WIT, and explain precisely why that shape is necessary rather than optional.
- Decide, for a given service, whether protobuf-in-Wasm is sufficient or whether a gRPC bridge is required, and what to watch as the component model's HTTP/2 story evolves.

## Why this matters

Chapter 11 put a Wasm component behind `wasmtime serve` and answered plain HTTP requests directly from the sandbox, with `wasi:http/incoming-handler` doing the work a reverse proxy usually does. That chapter's quiet assumption was that the wire format and the transport are the same decision: once a component can speak `wasi:http`, it can speak whatever sits on top of HTTP. gRPC breaks that assumption, and this chapter exists because of exactly where it breaks.

gRPC bundles two things that are logically independent: a serialization format (Protobuf: a schema-driven binary encoding of varints, length-delimited fields, and fixed-width numerics) and a transport contract (HTTP/2 framing, request/response or streaming semantics, trailers carrying the final status code after the body). The gRPC sibling site in this series, [api-patterns-and-practices-grpc](https://github.com/patterncatalyst/api-patterns-and-practices-grpc), covers both halves in full: the four RPC shapes, HTTP/2 framing details, interceptors, deadlines. This chapter does not re-teach any of that. It asks a narrower, component-model-specific question: which half of gRPC can run inside a Wasm component today, and which half can't?

The answer has two parts, and this chapter builds a runnable artifact for each one. First, the positive result: `proto/cargo.proto`'s messages compile with prost directly inside a Wasm component, a native host drives a complete encode-call-decode round trip across the component boundary, and the fields come back exactly as booked. That is Protobuf running server-side, inside the sandbox, with no asterisk. Second, the limit: no component in this toolchain exports anything resembling an HTTP/2 server. `wasi:http/incoming-handler` (Chapter 11's interface) answers HTTP/1.1-shaped request/response pairs; it is not a gRPC server, has no streaming semantics, and carries no trailers. gRPC-the-transport has nowhere to land inside a component today. The workaround this chapter builds and verifies is a native **tonic** process that terminates gRPC itself and dispatches each RPC into the unchanged Part 2 Rust provider over WIT: gRPC *in front of* Wasm, never gRPC *inside* Wasm.

{% include excalidraw.html file="12-encoding-vs-transport-split" alt="Two side-by-side panels. Left panel, PROTOBUF the encoding: varints length-delimited fields fixed64 doubles, pure computation decode bytes build a struct encode bytes, runs fully INSIDE the sandbox with prost in Rust or a reflection-free codec in TinyGo, needs nothing the component model denies. Right panel, gRPC the transport: HTTP/2 framing trailers bidirectional streaming, needs a listening server socket and an HTTP/2 stack, no component HTTP/2 server surface today since wasi:http exports a request handler not this, terminated by a host-mediated bridge in front of the component. Caption: same proto/cargo.proto, two different verdicts: the message format runs in Wasm, the RPC transport does not, yet." caption="Figure 12.1: Protobuf-the-encoding and gRPC-the-transport are separable concerns with separate verdicts in today's component model." %}

## One contract, two artifacts

Both halves of this chapter share one `.proto` file, `examples/part3-interfaces/proto/cargo.proto`. Its header states the split directly, because the same contract backs both the in-Wasm codec and the native gRPC bridge:

```proto
syntax = "proto3";

// Protobuf contract for the cargo domain, shared by the two ch12 artifacts:
//
//   1. proto-component (prost-in-Wasm): a WebAssembly component that uses prost
//      to DECODE a GetCargoRequest and ENCODE a GetCargoResponse entirely inside
//      the sandbox. Only the MESSAGES are used there (prost-build); the service
//      is ignored by a messages-only generator.
//
//   2. grpc-bridge (tonic): a native host that TERMINATES gRPC using this
//      CargoService and, per RPC, dispatches over WIT to the unchanged part2
//      Rust provider instantiated with wasmtime.
//
// The point ch12 makes: gRPC-the-transport needs the host bridge (no in-Wasm
// gRPC server is claimed), but Protobuf-the-serialization runs fully
// server-side inside a component.
package patterncatalyst.cargo.v1;

message Location {
  string unlocode = 1;
  string name = 2;
  string country = 3;
}

message Money {
  string amount = 1;
  string currency = 2;
}

message Cargo {
  string tracking_id = 1;
  Location origin = 2;
  Location destination = 3;
  double weight_kg = 4;
}

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

service CargoService {
  rpc GetCargo(GetCargoRequest) returns (GetCargoResponse);
  rpc BookCargo(BookCargoRequest) returns (BookCargoResponse);
}
```

(`BookCargoRequest` and `BookCargoResponse` are elided above; they carry the same origin/destination/weight shape the cargo domain has used since Chapter 5.) Two generators read this one file for two different purposes. `prost-build` inside the Wasm component generates message structs only: the `service` block is invisible to a messages-only generator, which is exactly the property this chapter needs: the component gets Protobuf's types with zero awareness that a `CargoService` even exists. `tonic-prost-build` inside the native bridge generates both the messages and the full `CargoServiceServer`/`CargoServiceClient` stubs, because the bridge is the one artifact that actually needs to be a gRPC endpoint.

## Protobuf inside the sandbox: the WIT boundary

The component that does the Rust-side protobuf work is `proto-component/proto-rust`, and its WIT world names the boundary precisely:

```wit
package patterncatalyst:cargo-proto@0.1.0;

/// Protobuf codec for the cargo domain, as a WebAssembly component (ch12).
///
/// The `codec` interface takes protobuf REQUEST bytes and returns protobuf
/// RESPONSE bytes. The encode/decode happens with prost entirely inside the
/// Wasm sandbox — this is Protobuf-the-serialization running server-side, as
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

Two things are worth stopping on before reading the implementation. First, `codec.get-cargo` moves `list<u8>` across the WIT boundary in both directions, not a WIT record shaped like `GetCargoRequest`. WIT has no concept of a protobuf message; as far as the Canonical ABI is concerned, this function moves an opaque byte list, the same primitive Chapter 11's `wasi:http` body used. Whatever structure those bytes carry is the component's business entirely, decoded and re-encoded with a library compiled straight into the `.wasm` binary. Second, this world still `import`s `patterncatalyst:cargo/booking` and `types`, the exact same cargo domain interfaces Chapters 6 and 7 built providers for. The protobuf codec is a *consumer* of the cargo domain in WIT terms, composed with a provider the same way Chapter 8's consumers were, via `wac plug`. Nothing about adding protobuf changes how composition works; it only changes what travels across the `codec` export once composition is done.

The Rust side's `Cargo.toml` pins prost exact and keeps the Wasm build lean:

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
# message structs. Messages only — the service in the .proto is ignored by this
# messages-only generator (the gRPC service is handled by the tonic bridge).
prost-build = "=0.14.4"
```

`build.rs` is three lines of real work, run on the host at compile time (not inside the sandbox):

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

This is the one place `protoc` (pinned to `36.2` in this toolchain) matters: `prost-build` shells out to it to parse the `.proto` grammar and emit a descriptor set, which `prost-build` then turns into ordinary `#[derive(Message)]` Rust structs. That code generation happens entirely on the build host, before `wasm32-wasip1` compilation even starts; nothing about running `protoc` happens inside the sandbox, and nothing needs to, because by the time the component is compiled, `pb::GetCargoRequest` and `pb::GetCargoResponse` are just Rust types with an `encode`/`decode` method each.

## The handler: decode, dispatch over WIT, encode

`src/lib.rs` is where the two boundaries meet: a protobuf boundary on the outside (`list<u8>` in, `list<u8>` out) and a WIT boundary on the inside (the imported `booking` interface, unchanged since Chapter 6). The `Guest` implementation reads top to bottom as decode, dispatch, encode:

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

`pb::GetCargoRequest::decode` runs prost's varint and length-delimited field parsing directly against the bytes handed across the WIT boundary; `booking::get_cargo` and `booking::book_cargo` are the same imported WIT functions Chapter 8's consumers called, resolved at composition time to whichever provider `wac plug` plugs in. The function's `Result` type is the WIT boundary's own error channel (`result<list<u8>, string>`), reserved for a request that fails to *decode* at all; a cargo that cannot be found is still a successful protobuf response, just one whose `error` field is non-empty, the same convention a REST API uses when it returns `200 OK` with a problem payload rather than failing the transport. `encode_ok` builds that response by copying the WIT-side `Cargo` and `Money` records into their `pb::` counterparts field by field, then calling `resp.encode_to_vec()`, prost's own encoder, one more time entirely inside the sandbox.

Every one of those steps (the varint decode, the string splitting, the struct construction, the length-delimited encode) is arithmetic and memory access. None of it asks for a socket, a thread, or a clock. That is the whole reason Protobuf clears a bar gRPC's transport cannot: a WebAssembly component is denied ambient access to the outside world by construction (Chapter 4's WASI preview 2 capability model), but it is never denied access to computation on the bytes it already has in hand.

## Proving the round trip: the native host

`proto-component/proto-host` is a small native program whose entire job is to prove the component did real protobuf work, not just pass bytes through unexamined. It encodes a request the same way any gRPC client would, calls across the component boundary, decodes the response, and asserts every field:

```rust
// --- prost ENCODE the request on the outside ---
let req = pb::GetCargoRequest {
    tracking_id: "CARGO-USNYC-DEHAM".to_string(),
};
let req_bytes = req.encode_to_vec();
println!(
    "host: encoded GetCargoRequest ({} bytes) tracking_id={}",
    req_bytes.len(),
    req.tracking_id
);

// --- call the component's codec.get-cargo over the component boundary ---
let resp_bytes = codec
    .call_get_cargo(&mut store, &req_bytes)
    .map_err(|e| anyhow::anyhow!("call codec.get-cargo: {e}"))?
    .map_err(|e| anyhow::anyhow!("codec.get-cargo returned err: {e}"))?;
println!("host: received {} bytes of protobuf response", resp_bytes.len());

// --- prost DECODE the response and assert fields ---
let resp = pb::GetCargoResponse::decode(resp_bytes.as_slice())
    .context("decoding GetCargoResponse")?;
```

The host's own WIT world is much thinner than the component's: it only needs to *call* `codec`, never to satisfy the component's `booking` imports itself (that is `wac plug`'s job, composing the proto component with the Part 2 Rust provider before the host ever sees the `.wasm` file):

```wit
package patterncatalyst:cargo-proto@0.1.0;

/// Host-side view of the proto component's export. The `codec` interface here is
/// structurally identical to proto-rust/wit (same package, version, interface,
/// and signature), so wasmtime links the host to the composed component's
/// exported `patterncatalyst:cargo-proto/codec@0.1.0`.
interface codec {
    get-cargo: func(request: list<u8>) -> result<list<u8>, string>;
}

/// The host only needs to CALL the codec export; it does not re-expose the cargo
/// imports (those are internal to the composed component).
world cargo-proto-codec {
    export codec;
}
```

Run end to end (`wac plug` composes the proto component against the Part 2 Rust provider, and the host drives the composed artifact), the real output is this, unedited:

```
host: encoded GetCargoRequest (19 bytes) tracking_id=CARGO-USNYC-DEHAM
host: received 91 bytes of protobuf response
host: ASSERT OK — prost round trip through Wasm: tracking_id=CARGO-USNYC-DEHAM origin=USNYC dest=DEHAM weight_kg=1200.5 price=1500.00 USD
```

Nineteen bytes went in, ninety-one came back, and every field the host asserts (tracking ID, both UN/LOCODEs, weight, price amount, price currency) matches what Chapter 6's provider would produce if called directly. The component booked the cargo, read it back, and encoded the result as a protobuf message, with the host never touching the cargo domain at all. That is the proof this chapter's first half exists to deliver: protobuf serialization, including the domain dispatch that produces the data being serialized, runs entirely server-side inside a Wasm component.

## The TinyGo wall: reflection does not exist at runtime

The same proof needs to hold in Go, because this series treats Rust and Go as first-class throughout, and `proto-go` is where it nearly didn't. The obvious approach is `google.golang.org/protobuf`, the standard reflection-based protobuf runtime every Go gRPC service uses. It **compiles** cleanly under TinyGo 0.43 targeting `wasip1`. It traps at runtime. `proto-go/wire.go`'s own header states the failure precisely, because tracking it down is exactly the kind of finding worth a chapter callout:

```go
// Reflection-free protobuf wire codec for the cargo messages (ch12, TinyGo).
//
// Why hand-written: TinyGo 0.43 COMPILES google.golang.org/protobuf but TRAPS at
// runtime — proto.Marshal reaches reflect.Type.MethodByName inside
// impl.MessageInfo.makeStructInfo, which TinyGo's partial reflect does not
// implement (see proto-go/README/notes). So the component cannot use the
// reflection-based library. This file encodes/decodes the proto3 wire format
// directly (varints, length-delimited strings/messages, fixed64 doubles) with no
// reflection, producing bytes that interoperate with the Rust prost side.
```

`google.golang.org/protobuf`'s `proto.Marshal` builds its wire encoding from a message descriptor it derives at runtime by walking the target struct's fields with Go's `reflect` package, specifically a call chain that bottoms out at `reflect.Type.MethodByName` inside `impl.MessageInfo.makeStructInfo`. TinyGo's `reflect` package covers only a limited, statically-analyzable subset of reflection that shows up in ordinary Go programs, not the dynamic method-table walking that a general-purpose protobuf runtime needs to build its descriptor the first time a message type is marshaled. The type-checker sees nothing wrong, because `reflect.Type.MethodByName` exists as a symbol; it just isn't implemented, and the component traps with `wasm unreachable` the first time that code path runs.

This is a compile-time-clean, runtime-broken failure, the worst kind to chase, because nothing in `tinygo build`'s output hints at it. There are two ways out. The production-grade one is `vtprotobuf`, a protoc plugin that generates a dedicated `MarshalVT`/`UnmarshalVT` method directly on each message type, so no runtime reflection is ever consulted; teams already running Go gRPC services at scale frequently adopt it purely for the performance win, independent of TinyGo. The example-scale one, and what `proto-go/wire.go` ships, is a hand-written reflection-free wire codec: the proto3 wire format implemented directly, field by field, against the four messages this chapter's service needs.

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

Decoding mirrors it: a `readVarint` loop reads the tag, the field number and wire type come out of `tag >> 3` and `tag & 0x7`, and an unrecognized field is skipped with `skipField` rather than rejected, so the decoder tolerates additions the way a real protobuf consumer should. `main.go`'s handler wires that codec to the identical cargo domain dispatch the Rust side runs:

```go
func getCargo(request cm.List[uint8]) cm.Result[cm.List[uint8], cm.List[uint8], string] {
	trackingID, err := decodeGetCargoRequest(request.Slice())
	if err != nil {
		return errResult("protobuf decode error: " + err.Error())
	}

	parts := strings.SplitN(trackingID, "-", 3)
	if !(len(parts) == 3 && parts[0] == "CARGO") {
		cargo, cErr, isErr := booking.GetCargo(trackingID).Result()
		if isErr {
			return okResult(encodeDomainError(cErr.String()))
		}
		return okResult(encodeCargoResponse(cargo, nil))
	}

	spec := cargotypes.RouteSpec{
		Origin:          locationFor(parts[1]),
		Destination:     locationFor(parts[2]),
		ArrivalDeadline: arrivalDeadline,
	}
	b, bErr, isErr := booking.BookCargo(spec, defaultWeightKg).Result()
	if isErr {
		return okResult(encodeDomainError(bErr.String()))
	}
	cargo, cErr, isErr := booking.GetCargo(b.CargoID).Result()
	if isErr {
		return okResult(encodeDomainError(cErr.String()))
	}
	price := &money{amount: b.Price.Amount, currency: b.Price.Currency}
	return okResult(encodeCargoResponse(cargo, price))
}
```

Same `CARGO-{ORIGIN}-{DEST}` parsing, same `book-cargo` then `get-cargo` sequence over WIT, same error-to-response-field mapping: a line-for-line structural match with the Rust handler, which is exactly the point: the reflection-free codec changes nothing about the *domain* logic, only how the bytes at the edges get made.

The result is driven by the identical `proto-component/proto-host` binary used for the Rust side, with no code change at all; only the composed `.wasm` path differs:

```
proto-component/proto-host/target/release/cargo-proto-host composed-proto-go.wasm   # byte-identical 91-byte response
```

The TinyGo component's response is byte-for-byte identical to the Rust prost component's response for the same request: same 91 bytes, same field layout, same values. That interop is not an accident of both sides agreeing informally; it's the proto3 wire format itself being a precise specification that a hand-written encoder and a generated prost encoder both implement correctly, which is exactly what makes cross-language protobuf interop a reasonable thing to rely on in the first place. The lesson for anyone reaching for TinyGo and protobuf together is not "TinyGo can't do protobuf" (it demonstrably can, including inside a Wasm sandbox), but that the reflection-based mainstream library cannot be assumed to work merely because it compiles, and a project should plan for either `vtprotobuf` generation or a hand-rolled codec before committing to the combination in anything beyond a demo.

{% include excalidraw.html file="12-protobuf-in-component" alt="A caller box on the left sends GetCargoRequest bytes, prost-encoded 19 bytes, into a large accent box labeled codec.get-cargo list u8 arrow result list u8 string. Inside that box, top to bottom: decode via prost in Rust or wire.go in TinyGo turning GetCargoRequest bytes into a tracking id, then dispatch over WIT calling booking.book-cargo and booking.get-cargo, then encode via prost or wire.go turning Cargo and Money into GetCargoResponse bytes. An amber arrow leaves the box to a caller-decodes-response box on the right showing 91 bytes, byte-identical between the Rust prost side and the TinyGo wire codec side. A bold caption reads INSIDE THE WASM SANDBOX, no network, no gRPC transport, just bytes in and bytes out. A second caption notes protobuf is varints, length-delimited fields, fixed64 doubles, pure computation, so it runs in a component with no transport capability at all." caption="Figure 12.2: Protobuf decode, WIT dispatch, and protobuf encode all run inside the component; the identical shape in Rust (prost) and TinyGo (a reflection-free wire codec) produces byte-identical output." %}

## Why gRPC itself cannot move into the component

Everything so far happened without gRPC ever entering the picture: `codec.get-cargo` moves bytes across a WIT function call, not an HTTP/2 stream. Standing up an actual `CargoService` gRPC endpoint needs more than an encoding; it needs a server that can accept a TCP connection, negotiate HTTP/2, demultiplex concurrent streams on that connection, read a request that may arrive as more than one HTTP/2 DATA frame, and write a response whose final status arrives as an HTTP/2 trailer after the body, all per the transport rules the gRPC sibling site's chapters document in depth. None of that is Protobuf; all of it is the HTTP/2 semantics gRPC is built on top of.

Chapter 11 showed the closest thing a component gets to a server role: `wasi:http/incoming-handler`, called once per inbound request by whatever wraps the component (`wasmtime serve`, or in principle a hosting environment implementing the same interface). That interface has no concept of a long-lived bidirectional stream, no trailer channel distinct from a response's own headers, and no multiplexing of several logical calls over one connection; it answers one request with one response and is done. It is, structurally, an HTTP/1.1-shaped request/response contract wearing an HTTP/2-capable host's clothes. A gRPC server needs a transport role no `wasi:*` interface exports today, because the standard as it exists was never designed with "a component is itself an HTTP/2 server" as a target shape. That is not a bug in any one component's code to fix; it is a gap in what the component model's server-side interfaces currently expose, and this chapter builds the workaround that exists rather than claiming a server role no component has.

## The bridge: gRPC in front of Wasm

The workaround is not to pretend the gap doesn't exist, but to put a native process in front of the component that owns the transport the component cannot own, and have that process do nothing but dispatch. `examples/part3-interfaces/grpc-bridge` is that process: a `tonic` gRPC server that terminates every transport concern (HTTP/2, trailers, the generated `CargoServiceServer` trait) natively, and for each RPC, instantiates the **unchanged** Part 2 Rust provider component with `wasmtime` and makes the same WIT calls Chapter 6's native host always made. The file's own header is the chapter's thesis compressed to four lines:

```rust
// gRPC-in-FRONT-of-Wasm bridge (ch12).
//
// A native host terminates gRPC with tonic and, per RPC, instantiates the
// UNCHANGED part2 Rust provider with wasmtime and dispatches the call over WIT.
// There is no gRPC server inside any component — the bridge is the artifact, and
// the chapter states this plainly. prost/tonic are pinned exact (Cargo.lock
// committed).
```

`Cargo.toml` pins the two libraries doing the transport-splitting work, exact, with the version note that matters most for anyone reaching for tonic fresh:

```toml
[dependencies]
tonic = "=0.14.6"
tonic-prost = "=0.14.6"
prost = "=0.14.4"
tokio = { version = "1", features = ["rt-multi-thread", "macros", "net"] }
wasmtime = "50"
wasmtime-wasi = "50"
anyhow = "1"

[build-dependencies]
tonic-prost-build = "=0.14.6"
```

tonic 0.14 split its prost integration out of the core crate into `tonic-prost` (runtime) and `tonic-prost-build` (codegen), a breaking change from earlier tonic releases that bundled prost support directly, so `build.rs` names the new crate explicitly:

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

`build_server(true)` is the line this chapter's entire second half depends on: unlike the component's `prost-build` call (messages only), this one generates the full `CargoServiceServer` trait and `CargoServiceClient` stub from the same `.proto` file's `service` block, because the bridge, not any component, is the thing that has to be a gRPC endpoint.

The bridge loads the Part 2 Rust provider once and keeps it around as a `Component` handle shared across RPCs, but gives every RPC its **own fresh `Store`**, meaning its own fresh provider instance:

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

That comment calls out a consequence worth sitting with: because the provider keeps its booked cargo in instance memory (the same in-memory state Chapter 6 built and Chapter 11's `wasmtime serve` handler already had to account for, one fresh instance per HTTP request), a fresh `Store` per gRPC call means a cold `GetCargo` call would find nothing, so `do_get_cargo` books the cargo first and reads it back within the same call, exactly mirroring Chapter 11's HTTP handler. Where the two differ is what runs the dispatch: `tokio::task::spawn_blocking` moves the synchronous, `wasmtime`-driven WIT call onto a blocking thread pool, keeping tonic's async executor free while a component's instantiation and execution (synchronous throughout, no `async` anywhere near a WIT call in this toolchain) run elsewhere:

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
    // book_cargo follows the identical spawn_blocking shape
}
```

`do_get_cargo` itself is the same WIT dispatch Chapter 6's native host always did: instantiate the `cargo` world's bindings, call `booking.book_cargo`, then `booking.get_cargo`, map the WIT result onto the protobuf response type, with nothing about it aware that a gRPC request triggered it:

```rust
fn do_get_cargo(&self, tracking_id: String) -> Result<GetCargoResponse, String> {
    let parts: Vec<&str> = tracking_id.splitn(3, '-').collect();
    if !(parts.len() == 3 && parts[0] == "CARGO") {
        return Ok(GetCargoResponse {
            cargo: None,
            price: None,
            error: format!("not-found: {tracking_id} is not a CARGO-O-D id"),
        });
    }
    let mut store = self.new_store();
    let cargo_world = self.instantiate(&mut store).map_err(|e| e.to_string())?;
    let booking_api = cargo_world.patterncatalyst_cargo_booking();

    let spec = RouteSpec {
        origin: location_for(parts[1]),
        destination: location_for(parts[2]),
        arrival_deadline: ARRIVAL_DEADLINE.to_string(),
    };
    let booking = match booking_api
        .call_book_cargo(&mut store, &spec, DEFAULT_WEIGHT_KG)
        .map_err(|e| e.to_string())?
    {
        Ok(b) => b,
        Err(e) => return Ok(domain_err_get(format!("{e:?}"))),
    };
    // ... call_get_cargo on the freshly booked cargo-id, map to GetCargoResponse
}
```

Nothing in the provider component itself changed to make this work. The `.wasm` file `wasmtime::component::Component::from_file` loads is the identical artifact `cargo component build --release` produced back in Chapter 6, composed against nothing, modified for nothing: "unchanged" is the whole proof here, because it shows gRPC's transport problem was solved entirely on the host side of the boundary, never by teaching the component anything new.

A `#[tokio::test]` baked directly into `main.rs` proves the whole chain by driving a real tonic client against a real server bound to an ephemeral port:

```rust
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tonic_client_roundtrip() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let incoming = tokio_stream::wrappers::TcpListenerStream::new(listener);

    let bridge = Bridge::new().expect("build bridge (is the part2 provider built?)");
    tokio::spawn(async move {
        Server::builder()
            .add_service(CargoServiceServer::new(bridge))
            .serve_with_incoming(incoming)
            .await
            .unwrap();
    });

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let mut client = CargoServiceClient::connect(format!("http://{addr}"))
        .await
        .expect("client connect");

    let resp = client
        .get_cargo(GetCargoRequest {
            tracking_id: "CARGO-USNYC-DEHAM".to_string(),
        })
        .await
        .expect("GetCargo rpc")
        .into_inner();
    assert!(resp.error.is_empty(), "unexpected error: {}", resp.error);
    let cargo = resp.cargo.expect("cargo");
    let price = resp.price.expect("price");
    assert_eq!(cargo.tracking_id, "CARGO-USNYC-DEHAM");
    assert_eq!(cargo.origin.unwrap().unlocode, "USNYC");
    assert_eq!(cargo.destination.unwrap().unlocode, "DEHAM");
    assert_eq!(cargo.weight_kg, 1200.5);
    assert_eq!(price.amount, "1500.00");
    assert_eq!(price.currency, "USD");

    // BookCargo follows, asserting booking_id, cargo_id, status, price

    println!("grpc-bridge: tonic client round trip OK (GetCargo + BookCargo through Wasm)");
}
```

That test is a complete gRPC client talking HTTP/2 to a tonic server over a TCP socket: nothing mocked, nothing stubbed. Run it, and the output is this:

```
grpc-bridge: tonic client round trip OK (GetCargo + BookCargo through Wasm)
test tonic_client_roundtrip ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

`GetCargo` and `BookCargo` both complete as real gRPC RPCs over real HTTP/2, and both payloads trace back to the same Wasm provider's domain logic a native Rust host has called since Chapter 6. The bridge can also run as a standalone server (`cargo run --release`, defaulting to `127.0.0.1:50051`) and answer `grpcurl` the same way, which is the shape anyone deploying this in front of real traffic would actually run.

{% include excalidraw.html file="12-grpc-bridge-in-front" alt="A grpcurl or tonic client box on the left sends GetCargo and BookCargo over HTTP/2 into a large user-styled box labeled cargo-grpc-bridge native host. Inside: a tonic transport Server box that terminates gRPC with HTTP/2 trailers and the CargoService trait, then a spawn_blocking box noting fresh Store per RPC and wasmtime component bindgen world cargo, then a dispatch-over-WIT box calling booking.book-cargo and get-cargo. An amber WIT-call arrow leaves the bridge box to an accent box on the right labeled part2 Rust provider component, UNCHANGED, no gRPC, no HTTP/2, no knowledge it is behind a bridge. A bold caption reads GRPC IN FRONT OF Wasm, the bridge is the gRPC server, the component is not and does not need to be. A second caption notes a component has no HTTP/2 server surface today so gRPC-the-transport is terminated natively, one host process in front of an unmodified provider." caption="Figure 12.3: the tonic bridge terminates gRPC and dispatches over WIT into the same unmodified Part 2 provider Chapter 6 built." %}

## Other shapes to consider

The tonic bridge is the shape this chapter builds and verifies, but it is not the only way to sit gRPC and Wasm near each other, and naming the others matters for anyone deciding which one fits a given deployment. A **grpc-web** client talking unary RPCs could, in principle, be served by a component acting as an *outbound* caller rather than an inbound server: a component importing `wasi:http/outgoing-handler` can issue an HTTP/2 request to some other gRPC endpoint entirely from inside the sandbox, which is a legitimate shape for a component that needs to *call* a gRPC service rather than *be* one, not built in this chapter's examples, but a different problem than the one solved here. A **terminating reverse proxy** (an Envoy-style gRPC-aware proxy, or a bespoke one) in front of a fleet of components is architecturally the same idea as the tonic bridge scaled out: the proxy owns HTTP/2 and gRPC framing, and each component behind it only ever sees whatever simpler interface the proxy translates into, which could be `wasi:http` request/response pairs rather than direct WIT calls. Neither alternative changes this chapter's core finding: in every shape, something outside the component terminates gRPC's transport, because nothing inside a component does, today.

## Pinned versions

| Component | Version | Why pinned |
| --- | --- | --- |
| `prost` / `prost-build` | `=0.14.4` | Exact pin; Cargo.lock committed for every crate that generates or links against protobuf messages. |
| `tonic` / `tonic-prost` / `tonic-prost-build` | `=0.14.6` | tonic 0.14 split the prost integration out of the core crate; the `tonic-prost*` crates are the current home for it. |
| `protoc` (libprotoc) | `36.2` | Invoked by both `prost-build` and `tonic-prost-build` at compile time; must be on `PATH` for either build to succeed. |
| `wasmtime` / `wasmtime-wasi` | `50` | Hosts both the protobuf-in-Wasm round trip and the gRPC bridge's per-RPC component instantiation. |

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for protobuf-in-Wasm alone (the <code>codec.get-cargo(list&lt;u8&gt;) -&gt; result&lt;list&lt;u8&gt;, string&gt;</code> shape this chapter builds) whenever the actual requirement is a stable, versioned, schema-driven binary message format, and the caller already owns its own transport: a message queue consumer decoding a protobuf-encoded event, a component embedded inside a larger pipeline that already moves bytes between stages some other way, or any case where the "service" is a function call that happens to use protobuf's encoding for its arguments. Reach for the tonic bridge (a native process terminating gRPC and dispatching into an otherwise-unchanged Wasm provider over WIT) the moment a client outside your control needs to speak actual gRPC: a generated client stub in another language, a service mesh's gRPC health-checking convention, or any consumer that will open an HTTP/2 connection and expect trailers back. Watch the component model's own HTTP/2 and streaming story as it develops: if a future <code>wasi:http</code> revision (or a sibling interface) ever exposes real bidirectional streaming with trailer support from inside a component, the bridge's <em>transport-termination</em> role could migrate into the sandbox the same way this chapter's protobuf codec already has, but that is a capability this toolchain does not have today, and this chapter builds against what runs now, not what might run later.</p></div>

## For deeper coverage

- [api-patterns-and-practices-grpc](https://github.com/patterncatalyst/api-patterns-and-practices-grpc): the full gRPC protocol treatment, outside the scope of this chapter: the four RPC shapes, HTTP/2 framing and trailers in depth, interceptors, and deadline propagation.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model's canonical ABI and `list<u8>` lowering/lifting mechanics underlying the `codec.get-cargo` boundary this chapter's examples cross.
- Kelsey Hightower, Brendan Burns, and Joe Beda, *Cloud Native Patterns and Practices*: service-mesh and sidecar framing for why a terminating proxy, not an in-process server, is the conventional place to put a protocol a workload cannot speak natively.
- [Protocol Buffers documentation](https://protobuf.dev/): the proto3 wire format (varints, length-delimited fields, fixed64 encoding) this chapter's TinyGo wire codec implements by hand.
- [tonic](https://github.com/hyperium/tonic) and [prost](https://github.com/tokio-rs/prost): the gRPC and Protobuf crates this chapter pins exact; `tonic`'s own changelog documents the 0.14 `tonic-prost` split referenced above.

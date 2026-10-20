# Part 2 — Building Components (two languages, one contract)

Two WebAssembly components — one written in **Rust**, one in **Go** — that both
implement the SAME cargo-shipping domain and both **export `world cargo`** from
the repository contract at [`contracts/wit/`](../../contracts/wit). A single
native **host** instantiates each component in turn and drives an identical
scenario across the component boundary, proving the two independently built
components are observably interchangeable.

```
contracts/wit  ──►  rust/   (cargo-component)   ─┐
   (unchanged)  └►  go/      (TinyGo + wasm-tools) ┤──►  host/  ──►  identical results
                                                   │   (wasmtime)
                              fixtures/scenario.json ─┘
```

Nothing here modifies `contracts/wit/`; both languages build against it as-is.

## Layout

| Path | What it is |
|------|------------|
| `rust/` | Rust provider, built with `cargo component` into a component. |
| `go/` | Go provider (`main.go` + `cabi_realloc.go`), bindings in `internal/cargo`, built with TinyGo + `wasm-tools`. |
| `go/adapters/` | Vendored wasip1→wasip2 reactor adapter (see SHA below). |
| `host/` | Native Rust host (wasmtime `component::bindgen!`) that calls the exports. |
| `fixtures/scenario.json` | Shared input + expected results consumed by the host for BOTH components. |
| `verify.sh` | Builds everything, runs the host against both, asserts equality + contract conformance. |

## Prerequisites (all on PATH)

```
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"
```

- Rust 1.99 with the `wasm32-wasip2` target, `cargo-component` 0.21
- Go 1.26, `wit-bindgen-go` v0.7.0, **TinyGo 0.43** (see the Go gotcha below)
- `wasm-tools` 1.262, `wasmtime` 50 (the host pulls the `wasmtime` crate v50)

## Build and run

One command does everything and asserts the result:

```
./verify.sh
```

Or step by step:

### Rust component

```
cd rust
cargo component build --release
wasm-tools component wit target/wasm32-wasip1/release/cargo_rust.wasm   # shows `export ...cargo/{types,booking,handling}`
```

`Cargo.toml`'s `[package.metadata.component.target]` points `path` at
`../../../contracts/wit` with `world = "cargo"`, so the crate generates its
bindings from the shared contract (it does not copy the WIT). The output is at
`target/wasm32-wasip1/release/cargo_rust.wasm` — cargo-component builds a
`wasm32-wasip1` core module and adapts it to a component internally, so the
artifact lives under `wasm32-wasip1/`, not `wasm32-wasip2/`.

### Go component

```
cd go
./build.sh
wasm-tools component wit cargo-go.wasm   # shows `export ...cargo/{types,booking,handling}`
```

`build.sh` runs:

```
wit-bindgen-go generate -o internal/cargo -p example.com/cargo-go/internal/cargo --world cargo ../../../contracts/wit
tinygo build -target=wasip1 -buildmode=c-shared -o core.wasm .
wasm-tools component embed ../../../contracts/wit --world cargo core.wasm -o embedded.wasm
wasm-tools component new embedded.wasm --adapt wasi_snapshot_preview1=adapters/wasi_snapshot_preview1.reactor.wasm -o cargo-go.wasm
```

### Host (runs against both)

```
cd host
cargo build --release
./target/release/cargo-host ../rust/target/wasm32-wasip1/release/cargo_rust.wasm ../fixtures/scenario.json rust
./target/release/cargo-host ../go/cargo-go.wasm                                 ../fixtures/scenario.json go
```

The host uses `wasmtime::component::bindgen!({ world: "cargo" })` to get typed
accessors for the exported interfaces, loads a component by path, provides WASI
through the linker, then calls `book-cargo → get-cargo →
request-possible-routes → assign-route → register-handling-event ×3 →
list-handling-events`, constructs a `cargo-tracker` resource and reads its
`tracking-id` / `current-status` / `history`. It asserts every result against
`fixtures/scenario.json` and prints a normalized JSON summary. `verify.sh` then
diffs the Rust summary against the Go summary — they are byte-identical.

## The scenario

Book `USNYC → DEHAM`, 1200.5 kg. Both components derive a deterministic
`tracking-id` (`CARGO-USNYC-DEHAM`) and `booking-id` (`BOOKING-USNYC-DEHAM`),
quote a fixed price (`1500.00 USD`), return one candidate itinerary with a
single planned leg on voyage `VOY-001`, then record three handling events
(`received`, `loaded`, `unloaded`). After the third event the `cargo-tracker`
reports `in-transit` with a 3-event history.

## Vendored adapter

`go/adapters/wasi_snapshot_preview1.reactor.wasm`

- Source: <https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasi_snapshot_preview1.reactor.wasm>
- SHA-256: `73b01f85e42e99c890efbbf619cd765e04e5809da36d976b87fc64abd87f5812`

This is the **reactor** adapter (not the command adapter) because the Go core
module is a reactor (exports `_initialize`, not `_start`).

## Gotchas worth a chapter callout

1. **Go toolchain: TinyGo, not `go build`.** The installed Go 1.26 `GOOS=wasip1
   GOARCH=wasm` toolchain **cannot** compile the `wit-bindgen-go` output: its
   `//go:wasmexport` restriction forbids returning pointers to pointerful types
   (`*cm.Result[...]`, `*string`, `*types.Leg`), because Go uses 64-bit pointers
   on `GOARCH=wasm` while the host is 32-bit. The compiler itself says those are
   "allowed on `GOARCH=wasm32`" — but `wasip1/wasm32` has no buildable buildmode
   on this Go (`c-shared`/`c-archive`/`pie`/default all refused), and there is
   no `wasm32` GOEXPERIMENT. TinyGo targets 32-bit wasm natively and has no such
   restriction, so it is the working compiler for the standard-Go **source**
   here. (This is a deviation from the "standard `go build`" recipe; the source,
   the `wit-bindgen-go` bindings and the `cm` module are all unchanged.)
2. **`cm` version pin: v0.3.0.** `go.bytecodealliance.org/cm` only resolves to
   **v0.3.0** — the `v0.4.0`…`v0.7.0` tags were cut on the monorepo *root*
   module (their `go.mod` declares `module go.bytecodealliance.org`), so Go
   rejects them for the `/cm` import path. Pin `cm v0.3.0`.
3. **`cabi_realloc`.** `wasm-tools component new` fails with "module does not
   export a function named `cabi_realloc`" unless the core module exports it.
   The upstream `go.bytecodealliance.org/x/cabi` package ships no export
   directive, so `go/cabi_realloc.go` provides the Canonical ABI realloc with an
   `//export cabi_realloc` directive (TinyGo).
4. **Reactor, not command.** Build the Go core with `-buildmode=c-shared` so it
   exports `_initialize` (reactor). A plain `tinygo build` produces a command
   (`_start`); paired with the reactor adapter the runtime never initializes and
   the first export call panics in `runtime.wasmExportCheckRun`.
5. **Sandboxed paths.** `wit-bindgen-go` and `wasm-tools component embed` read
   the contract directory through a wasmtime filesystem sandbox that only
   reaches paths relative to the current directory — pass a **relative** path
   (`../../../contracts/wit`), not an absolute one, or they fail with "failed to
   find a pre-opened file descriptor". (`wasm-tools component wit` tolerates
   absolute paths.)
6. **cargo-component output path.** The Rust component lands under
   `target/wasm32-wasip1/release/`, not `wasm32-wasip2/`.

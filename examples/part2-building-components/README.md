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

Two **consumer** components (`consumer-rust/`, `consumer-go/`) then IMPORT the
same interfaces and export `wasi:cli/run`; `wac plug` composes each consumer with
each provider into four self-contained CLIs that `wasmtime run` executes with no
native host. Nothing here modifies `contracts/wit/`; everything builds against it
as-is.

## Layout

| Path | What it is |
|------|------------|
| `rust/` | Rust PROVIDER, built with `cargo component` into a component that exports `world cargo`. |
| `go/` | Go PROVIDER (`main.go` + `cabi_realloc.go`), bindings in `internal/cargo`, built with TinyGo + `wasm-tools`. |
| `go/adapters/` | Vendored wasip1→wasip2 **reactor** adapter (see SHA below). |
| `consumer-rust/` | Rust CONSUMER — a `cargo component` **command** that imports the cargo interfaces and exports `wasi:cli/run`. |
| `consumer-go/` | Go CONSUMER — a TinyGo **command** (`main.go` + bump-allocator `cabi_realloc.go`) that imports the cargo interfaces. |
| `consumer-go/adapters/` | Vendored wasip1→wasip2 **command** adapter (see SHA below). |
| `host/` | Native Rust host (wasmtime `component::bindgen!`) that calls the provider exports and demonstrates the error-vs-trap taxonomy. |
| `fixtures/scenario.json` | Shared input + expected results consumed by the host for BOTH components. |
| `verify.sh` | Builds everything, runs the host against both providers, composes all four consumer×provider combos, asserts equality + contract conformance. |

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

## Consumers and composition (no native host)

The host above calls the providers from NATIVE code. The two **consumer**
components call them from INSIDE WebAssembly: each imports the cargo interfaces
and exports `wasi:cli/run`, so once it is *plugged* to a provider the composed
component is a self-contained CLI that `wasmtime run` executes directly — no
native host.

### Rust consumer (`cargo component` command)

```
cd consumer-rust
cargo component build --release
# -> target/wasm32-wasip1/release/cargo-consumer-rust.wasm
```

It is a `--command` crate (a `[[bin]]` with `fn main`), so cargo-component
synthesizes the `wasi:cli/run` export that wraps `main`. Its imports come from a
LOCAL world, `consumer-rust/wit/world.wit`:

```wit
world cargo-cli {
    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;
}
```

The `patterncatalyst:cargo` package those interfaces live in is supplied as a
**path dependency to the pristine contract** (`Cargo.toml`):

```toml
[package.metadata.component.target]
path = "wit"
world = "cargo-cli"

[package.metadata.component.target.dependencies]
"patterncatalyst:cargo" = { path = "../../../contracts/wit" }
```

So the contract is never copied or edited. (The contract's own `cargo-consumer`
world would also work, but routing through a local world is the cleaner recipe
for a real consumer that may add its own types.)

### Go consumer (TinyGo command)

```
cd consumer-go
./build.sh
# -> cargo-consumer-go.wasm
```

`build.sh` targets the contract's existing `cargo-consumer` world (imports the
three interfaces — no contract change) and runs:

```
wit-bindgen-go generate -o internal/cargo -p example.com/cargo-consumer-go/internal/cargo --world cargo-consumer ../../../contracts/wit
tinygo build -target=wasip1 -o core.wasm .                       # command: exports _start
wasm-tools component embed ../../../contracts/wit --world cargo-consumer core.wasm -o embedded.wasm
wasm-tools component new embedded.wasm --adapt wasi_snapshot_preview1=adapters/wasi_snapshot_preview1.command.wasm -o cargo-consumer-go.wasm
```

Note the **command** adapter here, not the reactor adapter the provider uses:
the command adapter synthesizes `wasi:cli/run` from the core module's `_start`.

### Compose the four combinations with `wac`

`wac plug` wires a provider's exports into a consumer's imports. The **provider
is the `--plug`** (it provides `cargo`); the **consumer is the socket** (it
imports `cargo`). Composed component bytes are non-deterministic
([wac#216](https://github.com/bytecodealliance/wac/issues/216)), so assert the
RUNTIME output, never the artifact bytes.

```
RUSTP=rust/target/wasm32-wasip1/release/cargo_rust.wasm
GOP=go/cargo-go.wasm
RUSTC=consumer-rust/target/wasm32-wasip1/release/cargo-consumer-rust.wasm
GOC=consumer-go/cargo-consumer-go.wasm

wac plug --plug "$RUSTP" "$RUSTC" -o /tmp/rustC-rustP.wasm && wasmtime run /tmp/rustC-rustP.wasm
wac plug --plug "$GOP"   "$RUSTC" -o /tmp/rustC-goP.wasm   && wasmtime run /tmp/rustC-goP.wasm
wac plug --plug "$RUSTP" "$GOC"   -o /tmp/goC-rustP.wasm   && wasmtime run /tmp/goC-rustP.wasm
wac plug --plug "$GOP"   "$GOC"   -o /tmp/goC-goP.wasm     && wasmtime run /tmp/goC-goP.wasm
```

All four print the identical normalized summary line:

```
booking=BOOKING-USNYC-DEHAM|cargo=CARGO-USNYC-DEHAM|weight=1200.5|price=1500.00 USD|status=not-routed|itinerary=BOOKING-USNYC-DEHAM VOY-001 planned|assigned=routed|events=3|tracker=CARGO-USNYC-DEHAM in-transit 3|history=received@USNYC,loaded@USNYC,unloaded@DEHAM
```

A cross-language consumer×provider pair (Rust consumer ↔ Go provider, or Go
consumer ↔ Rust provider) composing to the same bytes-of-behavior as the
same-language pairs is the headline: the WIT contract is the only coupling.

## Error taxonomy: recoverable error vs. unrecoverable trap

The contract's `cargo-error` variant models RECOVERABLE failures; a Rust
`panic!` / Go `panic()` at the component boundary is an UNRECOVERABLE trap. The
host (`host/src/main.rs`) demonstrates both against BOTH providers:

- **Recoverable:** `get-cargo("NO-SUCH-CARGO")` returns `Ok(Err(cargo-error::not-found))`
  — the wasmtime CALL succeeds, the domain result is an error, the instance
  lives on.
- **Unrecoverable trap:** a documented sentinel tracking id, `__TRAP__`, makes
  `get-cargo` panic. The wasmtime CALL itself returns `Err` (a trap) and the
  instance is poisoned. The host asserts this is a trap, NOT an `Ok(Err(..))`.
  The sentinel is kept in LOCKSTEP across `rust/src/lib.rs` and `go/main.go` and
  is kept out of the main scenario, so the byte-identical
  cross-language summary is unaffected. Because a trap poisons the instance, the
  host runs the trap call LAST.

## Vendored adapters

`go/adapters/wasi_snapshot_preview1.reactor.wasm`

- Source: <https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasi_snapshot_preview1.reactor.wasm>
- SHA-256: `73b01f85e42e99c890efbbf619cd765e04e5809da36d976b87fc64abd87f5812`

The **reactor** adapter — the Go PROVIDER core module is a reactor (exports
`_initialize`, not `_start`).

`consumer-go/adapters/wasi_snapshot_preview1.command.wasm`

- Source: <https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasi_snapshot_preview1.command.wasm>
- SHA-256: `b3de00ac47528237211c6404b4a7e4235a67878665dc3e8853071908c3127a85`

The **command** adapter — the Go CONSUMER core module is a command (exports
`_start`). The command adapter synthesizes the `wasi:cli/run` export.

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
   `target/wasm32-wasip1/release/`, not `wasm32-wasip2/`. The Rust CONSUMER
   command lands at `target/wasm32-wasip1/release/cargo-consumer-rust.wasm`.
7. **Command adapter + heap `cabi_realloc` = trap at `args_sizes_get`.** The Go
   CONSUMER is a command, so its `cabi_realloc` must differ from the provider's.
   The wasip1→wasip2 **command** adapter fetches the process arguments by calling
   the module's exported `cabi_realloc` from INSIDE `_start`, while the TinyGo
   runtime is still coming up (`runtime.run` → `os.Args` → `args_sizes_get` →
   adapter → back into `cabi_realloc`). A Go-heap-backed realloc reenters
   `make([]...)` before the GC is ready and the adapter aborts with
   `assertion failed at adapter line 2857`. The fix in
   `consumer-go/cabi_realloc.go` is a **static bump-arena** `cabi_realloc` (a
   fixed `[1 MiB]byte` global, monotonic offset, no frees): it touches no Go
   heap, is safe during early init, and the non-moving GC keeps the arena in
   place while the host reads lifted strings/lists. (A reactor never hits this —
   `_initialize` finishes before any export runs — which is why `go/` can use a
   heap realloc.)
8. **TinyGo's one-shot `-target=wasip2` WIT embedding is unusable here (0.43).**
   `tinygo build -target=wasip2 -wit-package ../../../contracts/wit -wit-world
   cargo-consumer` would skip the manual embed/adapter dance, but on TinyGo 0.43
   its bundled component step fails: `failed to resolve import
   wasi:cli/environment@0.2.0` — its embedded adapter pins wasi `0.2.0` and does
   not reconcile with the toolchain's `0.2.12` WASI imports. Use the explicit
   `tinygo build -target=wasip1` + `wasm-tools component embed` + `component new
   --adapt …=command.wasm` pipeline instead (what `consumer-go/build.sh` does).
9. **`wac plug` orientation + non-deterministic bytes.** `wac plug --plug
   <PROVIDER> <CONSUMER> -o composed.wasm`: the PROVIDER (exports `cargo`) is the
   `--plug`; the CONSUMER (imports `cargo`) is the socket argument. Composed
   bytes are non-deterministic ([wac#216](https://github.com/bytecodealliance/wac/issues/216)),
   so verification asserts the RUNTIME stdout of `wasmtime run`, never the
   artifact bytes.
10. **WASI minor-version skew composes fine.** The Rust provider imports WASI
    `0.2.3`, the Go components import `0.2.12`. `wac plug` leaves both as imports
    on the composed component, and `wasmtime run` satisfies any `0.2.x` import
    with its implementation via semver-compatible component linking, so
    cross-language compositions run without a version shim.
11. **Trap poisons the instance.** In the host, the `__TRAP__` sentinel call must
    be LAST: once a component panics/traps, its instance in that `Store` is
    poisoned and no further export call will succeed. The recoverable
    `not-found` check runs before it.

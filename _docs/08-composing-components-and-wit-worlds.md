---
title: "Composing Components and WIT Worlds"
order: 8
part: "Building Components in Rust & Go"
description: "Plug a Rust or Go consumer component into a Rust or Go provider with wac, and run the result under wasmtime with no native host."
duration: "26 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain the socket and plug model of `wac plug`: the consumer (imports) is the socket, the provider (exports) is the plug, and matching is by WIT identifier, never by source language.
- Build a `cargo-component` command component (Rust) and a TinyGo command component (Go), each importing the cargo interfaces and exporting `wasi:cli/run`, so the composed result needs no native host.
- Fix the trap that aborts a Go command component during startup when `cabi_realloc` allocates from the heap, using a static bump arena.
- Run all four consumer and provider compositions with `wac plug` and `wasmtime run`, and explain why composed bytes are non-deterministic while runtime output is not.
- Choose between `wac plug` for one pair and `wac compose` with a `.wac` script for a larger graph.

## Why this matters

A native host that calls a component proves the component works. It doesn't show what happens when the caller is itself a component. Two consumer components close that gap. They import `patterncatalyst:cargo/{types,booking,handling}` instead of exporting them and run one deterministic scenario as the caller. Composed with either provider by `wac plug`, each becomes a single `.wasm` file that `wasmtime run` executes directly, with no host binary.

That gives four consumer and provider pairs: Rust with Rust, Rust with Go, Go with Rust and Go with Go. Two of them cross a language boundary at composition time, and all four print the same summary line. A WIT world is a boundary that two independently built pieces of code agree on without reading each other's source.

{% include excalidraw.html file="08-wac-plug-socket-and-plug" alt="A consumer-rust.wasm or consumer-go.wasm box, labeled SOCKET, imports patterncatalyst:cargo types, booking, and handling and exports wasi:cli/run. A rust or go provider box, labeled PLUG, exports the same three interfaces. Both feed into a wac plug --plug provider consumer -o composed.wasm command box, which produces a composed.wasm box described as self-contained, run directly by wasmtime run composed.wasm with no native host required. A dashed arrow from composed.wasm points to a ghost box listing wasi:cli, wasi:io, and wasi:clocks imports left unresolved, satisfied by wasmtime's own WASI implementation at instantiation. A caption states composition matches by WIT identifier, not by source language." caption="Figure 8.1: wac plug. The consumer is the socket, the provider is the plug, and WASI stays the runtime's job." %}

## The socket and the plug

`wac plug` takes exactly two components. The provider, whose exports satisfy someone else's unmet imports, is the `--plug`. The consumer, which has an unresolved import for `patterncatalyst:cargo/booking@0.1.0` and its siblings, is the socket and is the positional argument.

```bash
RUSTP=rust/target/wasm32-wasip1/release/cargo_rust.wasm
RUSTC=consumer-rust/target/wasm32-wasip1/release/cargo-consumer-rust.wasm
wac plug --plug "$RUSTP" "$RUSTC" -o /tmp/rustC-rustP.wasm && wasmtime run /tmp/rustC-rustP.wasm
```

`wac` matches the interface identifiers `patterncatalyst:cargo/types@0.1.0`, `booking@0.1.0` and `handling@0.1.0` between what the consumer imports and what the provider exports. By then both files are Component Model binaries whose only visible shape is their WIT, so the matching never sees a source language. A Rust consumer has no opinion about whether its provider was built in Rust or Go. Its import names an interface, not a language.

## Two consumers, two homes for the world

Both consumers run the same scenario: book `USNYC` to `DEHAM` at 1200.5 kg, fetch the cargo, request routes, assign one, register three handling events, list them, then construct a `cargo-tracker` and read its ID, status and history. They differ in where the world that names their imports lives, and both choices are valid.

The Rust consumer declares a local world in its own crate:

```wit
world cargo-cli {
    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;
}
```

The `patterncatalyst:cargo` package those imports reference comes from `Cargo.toml` as a path dependency on the shared contract:

```toml
[package.metadata.component.target]
path = "wit"
world = "cargo-cli"

[package.metadata.component.target.dependencies]
"patterncatalyst:cargo" = { path = "../../../contracts/wit" }
```

The contract directory is never copied or edited. A local world leaves room for a consumer to add an import or a type of its own without touching `contracts/wit/`.

The Go consumer reuses `cargo-consumer`, a world the contract already defines, and names it in the `wit-bindgen-go` invocation:

```bash
wit-bindgen-go generate -o internal/cargo \
  -p example.com/cargo-consumer-go/internal/cargo \
  --world cargo-consumer "$CONTRACT_DIR"
```

| World | Use it when |
| --- | --- |
| Local to the consumer | The consumer may grow imports or types the contract doesn't define |
| `cargo-consumer` from the contract | The consumer wants exactly what the contract promises an importer |

Neither language is tied to one choice.

## Building a command component

The providers are **reactor** components: no `main`, instantiated once and called repeatedly by a host. A consumer that `wasmtime run` can execute must be a **command**, which exports `wasi:cli/run`.

In Rust that means a `[[bin]]` crate with an ordinary `fn main`. `cargo-component` synthesizes the `wasi:cli/run` export around it, the export `wasmtime run` looks for when handed a `.wasm` file with no other instructions. Inside `run()`, calls to the imports read like local calls because the generated bindings hide the Canonical ABI; they are the mirror image of the provider's `impl BookingGuest for Component`:

```rust
    // book-cargo
    let b = booking::book_cargo(&spec, WEIGHT_KG).map_err(|e| cargo_error_str(&e))?;

    // get-cargo
    let cargo = booking::get_cargo(&b.cargo_id).map_err(|e| cargo_error_str(&e))?;

    // request-possible-routes -> assign-route
    let routes =
        booking::request_possible_routes(&b.booking_id).map_err(|e| cargo_error_str(&e))?;
    let itinerary = routes
        .into_iter()
        .next()
        .ok_or_else(|| "no candidate itineraries".to_string())?;
    let leg = itinerary
        .legs
        .first()
        .cloned()
        .ok_or_else(|| "itinerary has no legs".to_string())?;
    let assigned =
        booking::assign_route(&b.booking_id, &itinerary).map_err(|e| cargo_error_str(&e))?;
```

`main` is an ordinary CLI entry point that prints the one summary line or exits non-zero:

```rust
fn main() {
    match run() {
        Ok(line) => println!("{line}"),
        Err(e) => {
            eprintln!("cargo-consumer-rust: scenario failed: {e}");
            std::process::exit(1);
        }
    }
}
```

It builds with the command the provider used:

```bash
cd consumer-rust
cargo component build --release
# -> target/wasm32-wasip1/release/cargo-consumer-rust.wasm
```

In Go, dropping `-buildmode=c-shared` makes `tinygo build` produce a command core module that exports `_start`. The wasip1 to wasip2 translation then needs the **command** adapter, not the reactor adapter the Go provider used. The two are not interchangeable: a reactor core given the wrong adapter panics the first time an export is called, and the same mismatch fails in the other direction.

```bash
tinygo build -target=wasip1 -o core.wasm .

echo "build.sh: [3/4] embedding the cargo-consumer world ..."
wasm-tools component embed "$CONTRACT_DIR" --world cargo-consumer core.wasm -o embedded.wasm

echo "build.sh: [4/4] creating the command component (wasip1 -> wasip2 via command adapter) ..."
wasm-tools component new embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" \
  -o "$OUT"
```

### The startup trap and the bump arena

The right adapter isn't enough. The command adapter fetches the process arguments by calling the module's exported `cabi_realloc` from inside `_start`, before the TinyGo runtime has finished starting. The call chain is `runtime.run`, `os.Args`, `args_sizes_get`, the adapter, and back into `cabi_realloc`. The provider's `cabi_realloc` allocates from the Go heap with `make`. That is correct for a reactor, where `_initialize` finishes before any export runs. In a command, a heap allocation re-enters `make` before the collector is ready, and the adapter aborts with `assertion failed at adapter line 2857`.

The consumer's `cabi_realloc.go` replaces the heap allocator with a static arena:

```go
const cabiArenaSize = 1 << 20

var cabiArena [cabiArenaSize]byte
var cabiOffset uintptr

//export cabi_realloc
func cabiRealloc(ptr unsafe.Pointer, size, align, newsize uintptr) unsafe.Pointer {
	if newsize == 0 {
		// Free / shrink-to-zero: the return value is ignored by the ABI.
		return unsafe.Pointer(&cabiArena[0])
	}
	if align == 0 {
		align = 1
	}
	off := (cabiOffset + align - 1) &^ (align - 1)
	if off+newsize > cabiArenaSize {
		// Out of arena: returning nil signals allocation failure to the ABI
		// rather than silently corrupting memory.
		return nil
	}
	newptr := unsafe.Pointer(&cabiArena[off])
	cabiOffset = off + newsize
	if ptr != nil && size > 0 {
		copy(unsafe.Slice((*byte)(newptr), newsize), unsafe.Slice((*byte)(ptr), size))
	}
	return newptr
}
```

The arena never touches the Go heap, so it's safe during early init, and TinyGo's non-moving collector keeps the array in place while the host reads lifted strings and lists out of it. Nothing is ever freed. That costs nothing here because the component runs the scenario once and exits, and 1 MiB is far more than the few kilobytes it lifts. A reactor never hits this failure, which is why the provider keeps the simpler heap version.

TinyGo 0.43 can skip the manual embed and adapt steps with `tinygo build -target=wasip2 -wit-package ... -wit-world cargo-consumer`. Its bundled adapter pins WASI `0.2.0` while the rest of the toolchain produces `0.2.12` imports, and the build fails with `failed to resolve import wasi:cli/environment@0.2.0`. The explicit `wasip1`, `component embed`, `component new --adapt` pipeline matches the WASI minor version in use.

## WASI version skew composes

The Rust provider imports `wasi:cli/environment@0.2.3`. The Go provider and both consumers resolve against `0.2.12`. That doesn't block a cross-language composition. `wac plug` resolves only the `patterncatalyst:cargo/*` imports it was asked to satisfy and leaves every WASI import unresolved on the composed component. `wasmtime run` satisfies them at instantiation through semver-compatible linking: any `0.2.x` import is served by the runtime's single built-in `0.2.x` implementation. `wasm-tools component wit composed.wasm` shows the WASI imports still present, exactly as they were before composition.

## Composing and running all four pairs

`verify.sh` runs the full two-by-two matrix with one function called four times:

```bash
# wac plug: the PROVIDER (exports cargo) is the --plug; the CONSUMER (imports
# cargo, exports wasi:cli/run) is the socket. The composed component needs no
# native host: wasmtime runs it directly. Assert RUNTIME stdout, never bytes.
compose_run_assert() {
  local name="$1" consumer="$2" provider="$3"
  local composed="$COMPOSE_DIR/composed-$name.wasm"
  wac plug --plug "$provider" "$consumer" -o "$composed"
  local actual
  actual="$(wasmtime run "$composed")"
  assert_eq "$EXPECTED_LINE" "$actual" "composed[$name] runtime output"
}
compose_run_assert "rustC-rustP" "$RUST_CONSUMER" "$RUST_WASM"
compose_run_assert "rustC-goP"   "$RUST_CONSUMER" "$GO_WASM"
compose_run_assert "goC-rustP"   "$GO_CONSUMER"   "$RUST_WASM"
compose_run_assert "goC-goP"     "$GO_CONSUMER"   "$GO_WASM"
```

All four print this line, character for character:

```
booking=BOOKING-USNYC-DEHAM|cargo=CARGO-USNYC-DEHAM|weight=1200.5|price=1500.00 USD|status=not-routed|itinerary=BOOKING-USNYC-DEHAM VOY-001 planned|assigned=routed|events=3|tracker=CARGO-USNYC-DEHAM in-transit 3|history=received@USNYC,loaded@USNYC,unloaded@DEHAM
```

{% include excalidraw.html file="08-polyglot-composition-matrix" alt="A grid with two provider columns, rust and go, each labeled exports cargo, and two consumer rows, rust and go, each labeled imports cargo exports wasi:cli/run. The four intersection cells read rustC x rustP, rustC x goP, goC x rustP, and goC x goP, each annotated wac plug --plug provider consumer. All four cells feed down into one shared banner: wasmtime run composed wasm, identical normalized summary across all four combos, booking equals cargo equals weight 1200.5 events 3 tracker in-transit 3. A caption notes that matching happens by WIT identifier, not by source language, so the two cross-language cells behave exactly like the two same-language cells." caption="Figure 8.2: Four compositions, two of them crossing a language boundary, one identical runtime output." %}

Compare runtime output, not the composed files. [wac#216](https://github.com/bytecodealliance/wac/issues/216) documents that the same `wac plug` command on the same inputs can produce two different, equally valid `.wasm` files, so a byte comparison of artifacts is flaky for a reason unrelated to whether the composition works.

## wac plug or wac compose

| Tool | Graph it handles |
| --- | --- |
| `wac plug` | One consumer, one provider, one import set satisfied by one export set |
| `wac compose` with a `.wac` script | Three or more components, imports split across several providers, or imports left for the host to supply |

A pipeline of an HTTP front end, a transform and a cargo provider is where a `.wac` script pays for itself over chained `wac plug` calls.

> **Decision**
>
> Compose with a native host when the caller needs capabilities a sandboxed component can't have, such as arbitrary filesystem access, a long-running server loop, or conditional orchestration across unrelated components, or when the caller isn't distributed as WebAssembly. Compose with `wac plug` when the caller is a component whose imports are exactly one provider's exports: the result is one self-contained file that runs with `wasmtime run`, the right shape for a CLI or a plugin. Move to `wac compose` and a `.wac` script at three components, or when one `--plug` can't express the connections.

> **🤖 Explore with your agent**
>
> "In examples/part2-building-components, compose consumer-go with the Rust provider using `wac plug --plug`, run it with `wasmtime run`, and compare the output to the line in verify.sh. Then explain, using `wasm-tools component wit` on the composed file, which imports `wac plug` resolved (the patterncatalyst:cargo interfaces) and which it left for wasmtime (the wasi:cli imports), and say whether this pair needs `wac compose` instead."
>
> Check: the printed line matches the expected summary exactly, and the composed component still lists `wasi:cli` imports.

## Build, run, observe

```bash
cd examples/part2-building-components && ./verify.sh
```

The script builds both consumers next to the providers, composes the four pairs with `wac plug` (provider as `--plug`, consumer as the socket), runs each under `wasmtime run`, and ends with `PASS` when all four print the identical line, including the two cross-language pairs. The README in that directory has the step-by-step build.

- Swap the Go consumer's `cabi_realloc.go` for the provider's heap version and rebuild: the component aborts at startup with `assertion failed at adapter line 2857`.
- Run `wac plug` twice on the same inputs and compare the files: the bytes may differ, the `wasmtime run` output does not.
- Replace the Go consumer's explicit pipeline with `tinygo build -target=wasip2 -wit-package ../../../contracts/wit -wit-world cargo-consumer`: the bundled component step fails with `failed to resolve import wasi:cli/environment@0.2.0`.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): component composition and the Canonical ABI mechanics underlying `wac plug`'s import and export matching.
- Shashank Jain, *WebAssembly for Cloud* (Apress): cross-language composition patterns and the trade-offs between a native host and a composed, self-contained component.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): composition, worlds, and the plug and socket terminology.
- [wac: WebAssembly Composition tool](https://github.com/bytecodealliance/wac): `wac plug` and `wac compose` reference, including the `.wac` language for multi-component graphs.

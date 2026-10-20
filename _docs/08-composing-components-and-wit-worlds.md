---
title: "Composing Components and WIT Worlds"
order: 8
part: "Building Components in Rust & Go"
description: "Compose a Rust or Go consumer component with a Rust or Go provider component using wac, and run the result directly under wasmtime with no native host."
duration: "26 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain the socket/plug model `wac plug` uses: the consumer (imports) is the socket, the provider (exports) is the plug, and matching happens by WIT identifier, never by source language.
- Build a `cargo-component` **command** component (Rust) and a TinyGo **command** component (Go), each importing the cargo interfaces and exporting `wasi:cli/run`, so the composed result needs no native host.
- Diagnose and fix the command-adapter-plus-heap-`cabi_realloc` trap that makes a Go command component abort during its own startup, with a static bump-arena allocator.
- Run all four consumer x provider compositions (`wac plug` then `wasmtime run`) and explain why composed bytes are non-deterministic while runtime output is not.
- State when `wac plug`'s single-pair recipe is enough and when a multi-component graph calls for `wac compose` and a `.wac` script instead.

## Why this matters

Chapter 6 built a cargo provider in Rust. Chapter 7 built the identical provider in Go, against the identical WIT contract, and ran into a working compiler that `go build` couldn't be today. Both chapters ended the same way: a native Rust host, built once against `world cargo`, calling either component and getting byte-identical results. That proved the two providers are interchangeable from a caller's point of view. It did not prove anything about what happens when the caller itself is a WebAssembly component rather than native code, and that is exactly the gap `examples/part2-building-components/consumer-rust/` and `consumer-go/` close.

This chapter builds two new components that do the opposite job: instead of exporting `patterncatalyst:cargo/{types,booking,handling}`, they import those three interfaces and run the same deterministic scenario as callers. Composed with either provider using `wac plug`, each becomes a single, self-contained `.wasm` file that `wasmtime run` executes directly, with no host binary at all. Four consumer x provider combinations exist (Rust consumer with Rust provider, Rust consumer with Go provider, Go consumer with Rust provider, Go consumer with Go provider), and `verify.sh`'s Step 8 runs all four and asserts they print the identical normalized summary line. Two of those four pairs cross a language boundary at composition time, which is the payoff Chapter 3 promised when it first described a WIT world as a boundary two independently built pieces of code can agree on without either one reading the other's source: composition matches by WIT identifier, not by source language, and this chapter is where that claim stops being a sentence in a contract chapter and starts being four binaries on disk that actually run.

{% include excalidraw.html file="08-wac-plug-socket-and-plug" alt="A consumer-rust.wasm or consumer-go.wasm box, labeled SOCKET, imports patterncatalyst:cargo types, booking, and handling and exports wasi:cli/run. A rust or go provider box, labeled PLUG, exports the same three interfaces. Both feed into a wac plug --plug provider consumer -o composed.wasm command box, which produces a composed.wasm box described as self-contained, run directly by wasmtime run composed.wasm with no native host required. A dashed arrow from composed.wasm points to a ghost box listing wasi:cli, wasi:io, and wasi:clocks imports left unresolved, satisfied by wasmtime's own WASI implementation at instantiation. A caption states composition matches by WIT identifier, not by source language." caption="Figure 8.1 — wac plug: the consumer is the socket, the provider is the plug, and WASI stays the runtime's job." %}

## The socket and the plug

`wac plug` takes exactly two components and one piece of vocabulary worth getting right before touching either consumer's source: which one is the **plug** and which one is the **socket**. `verify.sh`'s own comment states it directly:

```bash
# wac plug: the PROVIDER (exports cargo) is the --plug; the CONSUMER (imports
# cargo, exports wasi:cli/run) is the socket. The composed component needs no
# native host — wasmtime runs it directly. Assert RUNTIME stdout, never bytes.
```

The provider is the `--plug` argument because it is the thing being plugged *into* something else: it supplies exports that satisfy someone else's unmet imports. The consumer is the positional socket argument because it is the thing with a socket-shaped hole in it: an unresolved import for `patterncatalyst:cargo/booking@0.1.0` and friends, which the WIT package identifier alone would describe without naming who happens to fill it. The recipe end to end, for one pairing out of the four:

```bash
wac plug --plug "$RUST_WASM" "$RUST_CONSUMER" -o /tmp/rustC-rustP.wasm
wasmtime run /tmp/rustC-rustP.wasm
```

`wac` resolves that plug entirely by matching WIT interface identifiers (`patterncatalyst:cargo/types@0.1.0`, `patterncatalyst:cargo/booking@0.1.0`, `patterncatalyst:cargo/handling@0.1.0`) between what the consumer imports and what the provider exports. Nothing in that matching step inspects which language either binary was compiled from, because by the time `wac` sees either `.wasm` file, the language is already gone: both are Component Model binaries whose only externally visible shape is their WIT interface, the identical constraint Chapter 3 described for composition in the abstract and Chapters 6 and 7 proved for the provider side specifically. A consumer built in Rust has no opinion about whether the provider satisfying its import was built in Rust or Go, because its import statement never named a language in the first place. It named `patterncatalyst:cargo/booking@0.1.0`, and that is the only thing `wac` has to find a match for.

## Two consumers, one contract, two WIT homes

Both consumers run the identical scenario: book `USNYC → DEHAM` at 1200.5 kg, fetch the cargo, request routes, assign one, register three handling events, list them, construct a `cargo-tracker`, and read back its tracking ID, current status, and history. Both print the identical normalized summary line. Where they differ is where each one gets its WIT imports from, and both answers are legitimate.

The Rust consumer defines its own local world, `consumer-rust/wit/world.wit`, rather than reusing anything the contract already ships:

```wit
package patterncatalyst:cargo-consumer-rust@0.1.0;

world cargo-cli {
    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;
}
```

This world lives inside the consumer's own crate, not inside `contracts/wit/`, and `Cargo.toml` supplies the `patterncatalyst:cargo` package those three `import` lines reference as a **path dependency** pointing straight at the shared contract:

```toml
[package.metadata.component.target]
path = "wit"
world = "cargo-cli"

[package.metadata.component.target.dependencies]
"patterncatalyst:cargo" = { path = "../../../contracts/wit" }
```

The contract directory itself is never copied and never edited, the same discipline Chapter 6 built its Rust provider around, but the world that names the shape of *this particular consumer's* imports belongs to the consumer, not to the shared contract. That separation matters once a consumer wants to add anything of its own: a real client might eventually want a fourth import, or a local type the contract doesn't define, and a local world absorbs that without touching `contracts/wit/` at all.

The Go consumer takes the other legitimate path: it reuses a world the contract already defines, `cargo-consumer`, rather than declaring its own. `build.sh` names it directly in the `wit-bindgen-go generate` invocation:

```bash
wit-bindgen-go generate -o internal/cargo \
  -p example.com/cargo-consumer-go/internal/cargo \
  --world cargo-consumer "$CONTRACT_DIR"
```

Both are correct, and the choice is about ownership, not capability: a local world keeps the contract pristine while giving a consumer room to grow its own vocabulary later; reusing the contract's own consumer-side world is the cleaner recipe when a consumer wants nothing beyond exactly what the contract already promises an importer. Neither Rust nor Go is tied to one approach: the Rust consumer could have targeted `cargo-consumer` directly, and the Go consumer could have carried its own local world. The two examples simply demonstrate both options once each.

## Building the Rust consumer: a command, not a library

Chapters 6 and 7 both built **reactor** components: no `main`, instantiated once, called repeatedly by a host across the life of a process. `consumer-rust` is built as the opposite shape: a `[[bin]]` crate with an ordinary `fn main`, which makes it a cargo-component **command** rather than a reactor. That distinction is what makes `wac plug`'s output directly runnable:

```rust
// Composed with ANY component that exports `cargo` (the Rust or the Go
// provider in ../rust and ../go) via `wac plug`, the result is directly
// `wasmtime run`-able — no native host required.
```

Because the crate has a real `fn main`, `cargo-component` synthesizes the `wasi:cli/run` export that wraps it, the same export a WASI command-line program exports, and the same export `wasmtime run` looks for when it is handed a `.wasm` file with no other instructions. `main` itself reads like an ordinary CLI program that happens to call imported functions instead of local ones:

```rust
fn run() -> Result<String, String> {
    let spec = RouteSpec { origin, destination, arrival_deadline: ARRIVAL_DEADLINE.to_string() };

    // book-cargo
    let b = booking::book_cargo(&spec, WEIGHT_KG).map_err(|e| cargo_error_str(&e))?;

    // get-cargo
    let cargo = booking::get_cargo(&b.cargo_id).map_err(|e| cargo_error_str(&e))?;

    // request-possible-routes -> assign-route
    let routes = booking::request_possible_routes(&b.booking_id).map_err(|e| cargo_error_str(&e))?;
    let itinerary = routes.into_iter().next().ok_or_else(|| "no candidate itineraries".to_string())?;
    let leg = itinerary.legs.first().cloned().ok_or_else(|| "itinerary has no legs".to_string())?;
    let assigned = booking::assign_route(&b.booking_id, &itinerary).map_err(|e| cargo_error_str(&e))?;

    // register-handling-event x3, then list-handling-events, then the cargo-tracker resource
    // ...

    Ok(format!(
        "booking={}|cargo={}|weight={}|price={} {}|status={}|itinerary={} {} {}|assigned={}|events={}|tracker={} {} {}|history={}",
        b.booking_id, cargo.tracking_id, cargo.weight_kg, b.price.amount, b.price.currency,
        routing_status_str(b.status), itinerary.booking_id, leg.voyage_id, transport_status_str(leg.status),
        routing_status_str(assigned.status), events.len(), t_id, transport_status_str(t_status),
        t_history.len(), history_str(&t_history),
    ))
}

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

`booking::book_cargo`, `booking::get_cargo`, and the rest resolve to generated bindings for *imported* functions rather than `Guest` trait methods implemented over local state, the mirror image of Chapter 6's `impl BookingGuest for Component`. Calling an import reads exactly like calling a local function because the generated bindings make it look that way; the Canonical ABI call across the eventual component boundary is invisible from this file, the same way it was invisible from `host/src/main.rs` in Chapter 6, except here the caller is itself a `.wasm` binary rather than native code. Building it is the same one command Chapter 6 used for the provider:

```bash
cd consumer-rust
cargo component build --release
# -> target/wasm32-wasip1/release/cargo-consumer-rust.wasm
```

## Building the Go consumer: the command adapter, and a trap at startup

The Go consumer's `main.go` is just as unremarkable as the Rust one: plain calls against generated bindings, the identical scenario, the identical normalized line, byte-for-byte, printed with `fmt.Println`:

```go
return fmt.Sprintf(
    "booking=%s|cargo=%s|weight=%s|price=%s %s|status=%s|itinerary=%s %s %s|assigned=%s|events=%d|tracker=%s %s %d|history=%s",
    b.BookingID, cargo.TrackingID, weight, b.Price.Amount, b.Price.Currency, b.Status.String(),
    itinerary.BookingID, leg.VoyageID, leg.Status.String(), assigned.Status.String(),
    len(events.Slice()), tID, tStatus.String(), len(tHistory), strings.Join(history, ","),
), nil
```

The build recipe looks almost identical to Chapter 7's provider build, with one flag changed and one adapter swapped:

```bash
tinygo build -target=wasip1 -o core.wasm .
wasm-tools component embed "$CONTRACT_DIR" --world cargo-consumer core.wasm -o embedded.wasm
wasm-tools component new embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" \
  -o "$OUT"
```

Dropping `-buildmode=c-shared` here is not an oversight: a plain `tinygo build` produces a **command** core module (it exports `_start`, runs `main()` once), which is exactly what a `wasi:cli/run`-exporting consumer needs to be, the mirror of the Rust consumer's `cargo-component` command. That also means a different adapter has to do the wasip1-to-wasip2 translation: `consumer-go/adapters/wasi_snapshot_preview1.command.wasm`, not the reactor adapter Chapter 7's provider used. The two adapters are not interchangeable, and mismatching them doesn't fail cleanly: Chapter 7 already showed what happens when a reactor core gets the wrong adapter (a panic the first time an export is called); the consumer's own mismatch would be the same class of failure in the opposite direction.

The single most important new finding in this chapter is what happens next, because getting the adapter and the build mode right is not sufficient on its own. The command adapter does something a reactor adapter never has to do: it fetches the process's own argv by calling the module's exported `cabi_realloc` function **from inside `_start`**, before the TinyGo runtime has finished its own startup sequence. The provider's `cabi_realloc` (Chapter 7's `go/cabi_realloc.go`) allocates from the Go heap via `make`, which is correct for a reactor — `_initialize` always finishes running before any exported function is ever called, so the heap and the garbage collector are fully up by the time anything touches `cabi_realloc`. A command has no such guarantee: its `_start` *is* the first thing that runs, and the call chain the adapter triggers goes `runtime.run` → `os.Args` → `args_sizes_get` → back into the adapter → back into `cabi_realloc`, all before TinyGo's own runtime init has necessarily settled. A heap-backed realloc re-enters `make([]...)` partway through that sequence, and the adapter aborts with `assertion failed at adapter line 2857` rather than running at all.

The fix, in `consumer-go/cabi_realloc.go`, replaces the heap allocator with a static bump-arena that never touches the Go heap:

```go
const cabiArenaSize = 1 << 20

var cabiArena [cabiArenaSize]byte
var cabiOffset uintptr

//export cabi_realloc
func cabiRealloc(ptr unsafe.Pointer, size, align, newsize uintptr) unsafe.Pointer {
	if newsize == 0 {
		return unsafe.Pointer(&cabiArena[0])
	}
	if align == 0 {
		align = 1
	}
	off := (cabiOffset + align - 1) &^ (align - 1)
	if off+newsize > cabiArenaSize {
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

A fixed `[1 MiB]byte` global and a monotonically advancing offset, no frees, ever. It touches no Go heap, so it is safe to call before the GC is ready, and TinyGo's non-moving collector keeps that global array exactly where it is while the host reads lifted strings and lists back out of it after the call returns. The component runs the scenario once and exits, so never freeing the arena costs nothing: 1 MiB is far larger than the few kilobytes of data this scenario ever lifts across the boundary in one run. A reactor never hits this failure at all, which is precisely why the provider in `go/` gets to keep the simpler heap-backed version and the consumer in `consumer-go/` cannot.

One more TinyGo-specific dead end costs anyone an afternoon who doesn't see it coming: TinyGo 0.43's one-shot `tinygo build -target=wasip2 -wit-package ... -wit-world cargo-consumer` flag combination would, in principle, skip the manual embed-then-adapt dance entirely. On this version it doesn't work: its bundled component step fails with `failed to resolve import wasi:cli/environment@0.2.0`, because its embedded adapter pins WASI `0.2.0` and does not reconcile against the `0.2.12` WASI imports the rest of this toolchain produces. The explicit `-target=wasip1` plus `wasm-tools component embed` plus `component new --adapt ...=command.wasm` pipeline `consumer-go/build.sh` actually runs is the working path today; the one-shot flag is a toolchain-maturity gap, not a design decision a consumer author has control over.

## WASI version skew composes fine

The Rust provider and the Go components import different minor versions of WASI: `wasm-tools component wit` against the Rust provider shows `wasi:cli/environment@0.2.3`, while the Go provider and both Go/Rust consumers resolve against `0.2.12` (TinyGo's bundled adapters and `wit-bindgen-go`'s current release both track the newer minor). That skew sounds like exactly the kind of mismatch that should block a cross-language composition, and it doesn't. `wac plug` only resolves the `patterncatalyst:cargo/*` imports it was asked to satisfy; it leaves every WASI import on the composed component exactly as it found it, unresolved, regardless of which minor version each side names. `wasmtime run` is the thing that actually satisfies those imports at instantiation, and it does so through semver-compatible component linking: any `0.2.x` WASI import is satisfied by wasmtime's single built-in `0.2.x` implementation, so a Rust consumer naming `0.2.3` and a Go provider naming `0.2.12` link against the identical runtime surface with no version shim anywhere in the pipeline. The same tool Chapters 6 and 7 used to prove the export surface confirms it directly: `wasm-tools component wit composed.wasm` against any of the four composed artifacts shows the WASI imports still present, unresolved, exactly as they were on each half before composition; `wac plug` touched only the `patterncatalyst:cargo/*` identifiers it was told to connect.

## Composing and running all four combinations

With both consumers and both providers built, `verify.sh`'s Step 8 runs the full 2x2 matrix in one function, called four times with each pairing:

```bash
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

Two of those four pairs (`rustC-goP` and `goC-rustP`) cross the language boundary at the moment of composition, and both print exactly what the two same-language pairs print. That cross-language agreement, not the same-language pairs, is the headline: `wac` never asked which language built either half, because the only thing it had to match was a WIT identifier shared by all four binaries from the start.

{% include excalidraw.html file="08-polyglot-composition-matrix" alt="A grid with two provider columns, rust and go, each labeled exports cargo, and two consumer rows, rust and go, each labeled imports cargo exports wasi:cli/run. The four intersection cells read rustC x rustP, rustC x goP, goC x rustP, and goC x goP, each annotated wac plug --plug provider consumer. All four cells feed down into one shared banner: wasmtime run composed wasm, identical normalized summary across all four combos, booking equals cargo equals weight 1200.5 events 3 tracker in-transit 3. A caption notes that matching happens by WIT identifier, not by source language, so the two cross-language cells behave exactly like the two same-language cells." caption="Figure 8.2 — the 2x2 polyglot matrix: four compositions, two of them crossing a language boundary, one identical runtime output." %}

Why does `verify.sh` diff `wasmtime run`'s stdout rather than comparing the four `composed-*.wasm` files byte for byte? Because the composed artifact's bytes are not deterministic: [wac#216](https://github.com/bytecodealliance/wac/issues/216) documents that running the identical `wac plug` command twice against the identical inputs can produce two different, equally valid `.wasm` files. Asserting on artifact bytes would make this test flaky for a reason that has nothing to do with whether the composition actually works; asserting on `wasmtime run`'s observable output is the check that actually answers the question Step 8 is asking.

## wac plug versus wac compose and a .wac script

`wac plug` is the right tool for exactly the shape this chapter builds: one consumer, one provider, one import set satisfied by one export set. It is not the only tool in `wac`'s toolbox, and it is worth knowing where its ceiling is before reaching for it on a larger graph. `wac compose` takes a `.wac` script, a small declarative language naming multiple component instances and the specific connections between their imports and exports, and is the escape hatch once a composition stops being a single pair: three or more components wired together, a component whose imports are satisfied by two or more different providers split across interfaces, or a graph where some imports are left unresolved so the host can supply them later. Nothing in this chapter's example needs that: one consumer, one provider, one WIT package connecting them, four times over. A future chapter building a pipeline of several components (an HTTP front end, a transform, a cargo provider, chained together) is exactly the point a `.wac` file starts paying for itself over a `wac plug` invocation that would need its own ad hoc chaining logic layered on top.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Compose with a native host (Chapters 6 and 7's pattern) when the caller needs capabilities a sandboxed component can't have on its own, such as arbitrary filesystem access, a long-running server loop, or orchestration across several unrelated components with conditional logic between calls, or when the caller is simply not going to be distributed as WebAssembly at all. Compose with <code>wac plug</code> when the caller itself is a component that imports exactly what one provider exports: the result is a single self-contained artifact runnable with nothing but <code>wasmtime run</code>, no native binary to build or ship alongside it, which is the right shape for a CLI, a plugin, or any unit of behavior that should travel as one file. Reach for <code>wac plug</code> specifically, not <code>wac compose</code>, when the graph is exactly one plug into exactly one socket; reach for a <code>.wac</code> script and <code>wac compose</code> the moment the graph has three or more components, a provider split across multiple consumers, or connections a single <code>--plug</code> flag can't express. This example's four compositions are all <code>wac plug</code> because each one is exactly one provider satisfying exactly one consumer's imports, the simplest case the tool was built for, run four times over two languages in both directions.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning) — component composition and the Canonical ABI mechanics underlying `wac plug`'s import/export matching.
- Shashank Jain, *WebAssembly for Cloud* (Apress) — cross-language composition patterns and the operational trade-offs between a native host and a composed, self-contained component.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/) — the canonical description of composition, worlds, and the plug/socket terminology this chapter's examples build on directly.
- [wac — WebAssembly Composition tool](https://github.com/bytecodealliance/wac) — `wac plug` and `wac compose` reference, including the `.wac` language this chapter's closing section points toward for multi-component graphs.

---
title: "wasmtime"
order: 14
part: "Runtimes: wasmtime & wasmCloud"
description: "Embed wasmtime 50 directly in a native Rust host: Engine/Store/Linker lifecycle, a host-provided import satisfied by a Rust closure, and the three Store-level controls (fuel, epoch interruption, and a ResourceLimiter) that keep a guest from running away with the process."
duration: "27 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain the difference between the `wasmtime` CLI (`wasmtime run`, `wasmtime serve -S cli`) this book has used throughout, and the embedded `wasmtime` crate `examples/part4-runtimes/wasmtime-host/host/` builds against directly.
- Build an `Engine`, a `Linker<T>`, and a `Store<T>` by hand, wire WASI into the linker with `wasmtime_wasi::p2::add_to_linker_sync`, and satisfy a component's own custom import with a Rust closure via `bindgen!`'s generated `add_to_linker`.
- Turn on fuel metering with `Config::consume_fuel(true)` and `Store::set_fuel`, and explain why a guest that exhausts its budget traps with `Trap::OutOfFuel` rather than returning an error.
- Turn on epoch interruption with `Config::epoch_interruption(true)`, a ticker thread calling `Engine::increment_epoch()`, and `Store::set_epoch_deadline`, and say why this control needs a second thread where fuel does not.
- Cap a guest's linear memory with a `ResourceLimiter` (`StoreLimits`/`StoreLimitsBuilder`), and explain why a denied `memory.grow` surfaces to the host as a trap rather than a clean `Err`.
- Classify a `wasmtime::Error` as a specific `Trap` with `downcast_ref::<Trap>()`, and say why `anyhow`'s `.context()` does not apply to it directly.

## Why this matters

Every host in Parts 2 and 3 of this book did the same three things: load a component, instantiate it against a `Linker` wasmtime itself built from `wasmtime_wasi::p2::add_to_linker_sync`, and call an exported function. The host never granted the guest anything beyond WASI, never metered how long a call could run, and never capped how much memory a call could claim. That was fine for the cargo domain's bounded, well-behaved operations, but it leaves open a question this chapter exists to answer: what does a host do about a guest that does not behave, one that spins forever, or tries to claim more memory than the host is willing to give it?

`examples/part4-runtimes/wasmtime-host/` answers that question with a single guest component and a single native host, embedding **wasmtime 50**'s component-model runtime directly instead of going through the `wasmtime` CLI binary. The guest exports one function, `run(mode, iterations)`, with three modes: `clean` does bounded work and calls back into the host; `spin` runs a tight, unbounded compute loop; `grow` repeatedly claims a megabyte of linear memory and holds onto it. The host drives all three modes under four different `Store` configurations and asserts, for each one, that the host-side control it set up fired, not merely that the guest failed for some reason. A **host-provided import** (`host-caps`) proves the Linker is also the mechanism by which a host hands a guest *capabilities*, not just WASI. **Fuel**, **epoch interruption**, and a **ResourceLimiter** each get their own contrast pair: a run where the control is set generously and the guest succeeds, next to a run where the same guest, unmodified, trips the control and traps. That pairing is deliberate: it is the difference between "the control fired" and "the guest just failed," and every assertion in `host/src/main.rs` is built to tell those two outcomes apart.

{% include excalidraw.html file="14-embedding-architecture" alt="A host box containing Engine::new(&Config::new()), then Linker::new(&engine) with wasmtime_wasi::p2::add_to_linker_sync and host_caps::add_to_linker wired in with HasSelf and a pipe-s-s getter, then Store::new(&engine, HostState) with a limiter closure, then HostDemo::instantiate, then bindings.call_run. A guest box exports run(mode, iterations) and imports host-caps::host-quote and host-caps::host-now. An arrow runs from instantiate to the guest's run export labeled call across component boundary, and a return arrow from the guest's host-caps imports back into the host's impl host_caps::Host for HostState block labeled guest calls host import. A caption notes the Linker closure is the whole of the guest's ambient authority." caption="Figure 14.1: the host's Engine/Store/Linker lifecycle, the host-caps import wired in by closure, and the guest calling back across the boundary." %}

## Two ways to run a component: the CLI and the embedded crate

Composing components together used `wasmtime run composed.wasm` to run a composed component. Debugging a trap reached for `wasmtime run` again, with `WASMTIME_BACKTRACE_DETAILS=1` and `--gdbstub`. Serving HTTP directly from a component put a component on a socket with `wasmtime serve -S cli composed-http-rust.wasm --addr 127.0.0.1:8080`, and that `-S cli` flag is itself one of five flag families (`-O`/`--optimize`, `-C`/`--codegen`, `-D`/`--debug`, `-W`/`--wasm`, and `-S`/`--wasi`) the `wasmtime` binary exposes for tuning Cranelift codegen, debugging, Wasm semantics, and WASI proposals respectively, each with its own `-X help` listing and an equivalent `--config FILE` TOML form. Every one of those used wasmtime as a **command**: a prebuilt binary that takes a `.wasm` file and some flags and runs it, with no Rust code of this book's own in the loop at all.

This chapter's host is not that. `host/src/main.rs` depends on the `wasmtime` crate directly (`wasmtime = "50"` in `host/Cargo.toml`) and calls its Rust API (`Engine`, `Store`, `Linker`, `Config`), the same types the `wasmtime` CLI binary itself is built on top of. The two surfaces are not alternatives for the same job; they are different altitudes on the same runtime. The CLI's `-W` flag family exposes two of this chapter's three Store controls directly: running `wasmtime run -W help` on this book's pinned wasmtime 50 prints `-W fuel=N -- Enable execution fuel with N units fuel, trapping after running out of fuel` and `-W epoch-interruption[=y|n] -- Yield when a global epoch counter changes`, so a reader who only ever needs to cap a `.wasm` file's resource use from the outside can reach for `wasmtime run -W fuel=100000 guest.wasm` and never write a line of Rust. What the CLI does not expose, because there is no flag for it, is a **host-provided import**: nothing on the `wasmtime run` command line lets an external process hand a component a Rust closure to call. The moment a component imports something beyond WASI, a pricing service, a clock, any capability the host alone can supply, the CLI's job is done and an embedding is the only way forward. That is exactly the shape of the guest this chapter builds against, and it is why the host here is a crate dependency instead of a command-line invocation.

## The host side of the Component Model: Engine, Store, Linker

Every embedding starts with the same three wasmtime types, each with a different lifetime. An `Engine` is expensive to build and cheap to clone (it wraps an `Arc` internally) and holds compiled code and the `Config` that produced it; this host builds a fresh `Engine` per `Config` variant (default, fuel-enabled, epoch-enabled) because fuel and epoch metering are properties of the `Config`, decided once and baked in, not settings a running `Store` can flip. A `Linker<T>` resolves a component's imports against host-supplied implementations; it is built once per `Engine` and reused across every `Store` that engine creates. A `Store<T>` holds one component instance's actual runtime state, including, in this host, the WASI context and the per-store memory limiter, and is cheap enough to build fresh for every one of the host's six scenario runs.

`host/src/main.rs` generates its bindings against a **local** WIT world, not the repository's shared `contracts/wit`:

```rust
wasmtime::component::bindgen!({
    path: "../wit",
    world: "host-demo",
});
```

That one macro call produces the `HostDemo` world struct with `instantiate` and `call_run`, the `patterncatalyst::host_demo::host_caps::Host` trait this host implements, and `host_caps::add_to_linker`, the function that wires a `Host` implementation into a `Linker`. Building the `Linker` itself is one small function, shared across every scenario:

```rust
fn make_linker(engine: &Engine) -> Result<Linker<HostState>> {
    let mut linker: Linker<HostState> = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).wc("add wasi to linker")?;
    host_caps::add_to_linker::<HostState, HasSelf<HostState>>(&mut linker, |s| s)
        .wc("add host-caps import to linker")?;
    Ok(linker)
}
```

`wasmtime_wasi::p2::add_to_linker_sync` is the identical call every Part 2 and Part 3 host used, resolving the guest's std/alloc/stdio imports the same way regardless of what else the guest needs. `host_caps::add_to_linker` is new to this chapter, and its type parameters are worth reading slowly: `host_caps::Host` is implemented for `HostState`, but the generated `add_to_linker` function is parameterized over `D: HasData`, not over `HostState` directly, because `bindgen!`'s generated import-linking code supports both "the host state itself implements `Host`" and "some projection of the host state implements `Host`," and it needs a type-level way to say which. `HasSelf<HostState>` picks the first shape, and the `|s| s` closure is the getter that satisfies it: it takes the store's `&mut HostState` and returns it unchanged. Passing `HasSelf<HostState>` with `|s| s` is boilerplate you write once per host; forgetting the type parameter, or getting the getter's return type wrong, fails at `cargo build` with a trait-bound error rather than at runtime, which is the better place for that mistake to surface.

`HostState` itself holds everything a `Store` needs across the chapter's three concerns: WASI, host-capability bookkeeping, and the memory limiter.

```rust
struct HostState {
    table: ResourceTable,
    wasi: WasiCtx,
    limits: StoreLimits,
    quote_calls: u32,
    now_calls: u32,
}
```

`quote_calls` and `now_calls` exist purely for the host's own assertions. They are not part of any WIT type, just plain counters the `host_caps::Host` implementation increments on every call, so the host can prove the import fired rather than merely trusting that a `clean` summary string containing the right substrings implies it.

## A host-provided import: host-caps

The local world this chapter's guest and host share is small enough to read in full:

```
interface host-caps {
    host-quote: func(id: string) -> string;
    host-now: func() -> u64;
}

world host-demo {
    import host-caps;
    export run: func(mode: string, iterations: u64) -> string;
}
```

`host-caps` is the **import** direction of the Component Model this book has not shown before: every other component built in this book exported the cargo domain's `booking` and `handling` interfaces for a host (or another component, via `wac plug`) to call. Here the guest imports a capability only the native host can supply, a pricing quote and a clock reading, and has no other way to obtain either value. `guest/src/lib.rs`'s `clean` mode makes the call directly:

```rust
let quote = host_caps::host_quote("CARGO-USNYC-DEHAM");
let now = host_caps::host_now();
```

The host side implements `host_caps::Host` for `HostState` with ordinary Rust, no WIT ceremony visible beyond the trait signature `bindgen!` generated:

```rust
impl host_caps::Host for HostState {
    fn host_quote(&mut self, id: String) -> String {
        self.quote_calls += 1;
        format!("{id}=1500.00USD@host")
    }

    fn host_now(&mut self) -> u64 {
        self.now_calls += 1;
        HOST_NOW
    }
}
```

This is the mechanism by which a host hands a guest ambient authority explicitly, rather than by accident: the guest can call exactly `host-quote` and `host-now`, nothing else, because the `host-demo` world's `import host-caps` line is the complete list of what the guest ever declared it needed, and `make_linker` is the complete list of what the host ever agreed to supply. Running the guest's `clean` mode and reading `store.data().quote_calls` and `store.data().now_calls` afterward is how the host proves the call crossed the boundary rather than the guest silently returning a default:

```
=== 1. clean run (host-provided import) ===
    guest returned: clean mode=ok quote=[CARGO-USNYC-DEHAM=1500.00USD@host] now=1700000000 acc=159304473746738296
    host-caps fired: host_quote x1, host_now x1 — host-provided import works
```

That `quote=[CARGO-USNYC-DEHAM=1500.00USD@host]` substring in the guest's own return value is the host's format string (`"{id}=1500.00USD@host"`) coming back out through the guest, proof that the number did not originate anywhere inside the `.wasm` binary.

## Fuel: metered execution

Fuel is the simplest of the three controls: it counts down a budget of abstract execution units as the guest runs, and traps the instant the budget reaches zero, with no thread of the host's own needed to drive it. Both pieces live where they look like they should: `Config` turns the mechanism on, `Store` sets the number.

```rust
let mut fuel_cfg = Config::new();
fuel_cfg.consume_fuel(true);
let fuel_engine = Engine::new(&fuel_cfg)?;
```

```rust
store.set_fuel(100_000).wc("set small fuel")?;
```

The guest's `spin` mode is built specifically to burn through any budget a Store gives it: a tight loop with a carried data dependency (`acc = acc.wrapping_mul(i | 1).wrapping_add(0x9E3779B97F4A7C15)`) so the optimizer cannot delete it, run for as many as 100 billion iterations if nothing stops it first. Against a 100,000-unit budget it never gets close:

```
=== 2. fuel metering ===
    ample fuel: clean run ok, fuel remaining=49967929: clean mode=ok quote=[CARGO-USNYC-DEHAM=1500.00USD@host] now=1700000000 acc=159304473746738296
    fuel: trapped with OutOfFuel (as expected)
```

The contrast line above it matters as much as the trap itself: the same `fuel_engine`, given 50,000,000 units of fuel for a `clean` run instead of 100,000 for a `spin` run, finishes with `fuel remaining=49967929`, proving fuel was consumed at all, not merely that this `Engine`'s fuel accounting is inert, and the host asserts `remaining < 50_000_000` for exactly that reason. Without that assertion, a build where `consume_fuel` silently did nothing would still print a plausible-looking clean run and nobody would notice.

## Epoch interruption: cooperative deadlines from outside

Fuel counts instructions; epoch interruption counts time, and it needs a second thread because nothing inside the `Engine` advances a clock on its own. `Config::epoch_interruption(true)` turns the mechanism on the same way `consume_fuel` does, and `Store::set_epoch_deadline(n)` sets how many ticks of the engine's global epoch counter the guest is allowed to run through before it traps. Something external has to call `Engine::increment_epoch()` to produce those ticks, and this host spawns exactly that:

```rust
let ticker_engine = epoch_engine.clone();
let stop = Arc::new(AtomicBool::new(false));
let stop_t = stop.clone();
let ticker = thread::spawn(move || {
    while !stop_t.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(5));
        ticker_engine.increment_epoch();
    }
});
```

`Engine::clone()` is cheap: it shares the same underlying compiled-code and epoch state as the original, so the ticker thread can hold its own handle without touching the `Store` the guest is running in at all; the two communicate only through the shared epoch counter inside the `Engine`. A `Store` with a far deadline (`set_epoch_deadline(1_000_000)`) never notices the ticker during a short `clean` run. A `Store` with `set_epoch_deadline(1)` racing against the same `spin` mode that defeated fuel gets interrupted on the next tick:

```
=== 3. epoch interruption ===
    far deadline: clean run ok: clean mode=ok quote=[CARGO-USNYC-DEHAM=1500.00USD@host] now=1700000000 acc=159304473746738296
    epoch: trapped with Interrupt (as expected)
```

The host stops the ticker thread and joins it (`stop.store(true, ...); ticker.join().ok();`) before asserting on the result, specifically so a failed assertion still leaves no thread running past `main`'s return: a detail easy to skip in a one-off demo and costly to skip in anything longer-lived.

{% include excalidraw.html file="14-store-safety-controls" alt="Three columns for the same guest running spin or grow under three different Stores. The fuel column shows Config::consume_fuel(true), store.set_fuel(100_000), the budget exhausted mid-loop, and trapped with OutOfFuel, contrasted below with set_fuel(50_000_000) succeeding. The epoch column shows Config::epoch_interruption(true), store.set_epoch_deadline(1), a ticker thread sleeping 5ms and calling engine.increment_epoch(), and trapped with Interrupt, contrasted below with a far deadline succeeding. The ResourceLimiter column shows StoreLimitsBuilder.memory_size(8 MiB), store.limiter, a denied memory.grow past the cap, and an allocator abort trap, contrasted below with a 256 MiB cap succeeding at 64 blocks and 67108864 bytes. A caption notes each column gates the same guest and the contrast row is the proof the control fired." caption="Figure 14.2: fuel, epoch interruption, and a ResourceLimiter, each contrasted against a clean run that succeeds." %}

## ResourceLimiter: capping memory from outside the guest

The third control caps something neither fuel nor epoch touch at all: how much linear memory a guest's `Store` is willing to let it claim. wasmtime's `StoreLimits` (built with `StoreLimitsBuilder`) implements the `ResourceLimiter` trait the embedding API expects, and attaching one to a `Store` is a single call:

```rust
let capped = StoreLimitsBuilder::new().memory_size(8 * 1024 * 1024).build();
let mut store = Store::new(&engine, new_state(capped));
store.limiter(|s| &mut s.limits);
```

The guest's `grow` mode claims memory a megabyte at a time, holding each chunk in a `Vec` so the allocator cannot reuse freed pages, up to whatever total `iterations` asks for: 64 iterations means 64 MiB. Against an 8 MiB cap, the growth past that ceiling is denied, and the denial does not come back as a tidy `Result::Err` the way a WIT-level `cargo-error` would. It surfaces as a trap, because the guest's own Rust allocator, told by the linear-memory host that `memory.grow` failed, aborts:

```
=== 4. resource limiter (memory cap) ===
memory allocation of 1048576 bytes failed
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
    grow past the 8 MiB cap was denied -> trap UnreachableCodeReached (as expected)
    same grow under 256 MiB cap succeeds: grow done blocks=64 bytes=67108864
```

That `memory allocation of 1048576 bytes failed` line is the guest's own allocator writing to stderr before the abort instruction turns into the `UnreachableCodeReached` trap the host classifies. The specific trap code here is almost incidental: it is whatever trap a Rust allocator abort happens to compile down to, not a dedicated "memory capped" trap wasmtime defines, which is exactly why the host does not assert on that trap code the way it asserts `Trap::OutOfFuel` and `Trap::Interrupt` for the other two controls. What it asserts instead is the contrast: the identical `grow` run, same component, same 64-MiB request, succeeds cleanly under a 256 MiB cap (`grow done blocks=64 bytes=67108864`). A limiter that silently did nothing would let both runs through; a guest that crashed on large allocations regardless of any cap would fail both. Only a limiter that is enforcing an 8 MiB ceiling produces exactly this pair of outcomes, and that pairing, not the trap's name, is the host's real assertion.

## Classifying errors: wasmtime::Error is not anyhow

Every one of the last three sections ended with the host telling `OutOfFuel` apart from `Interrupt` apart from an allocator abort, and that classification depends on a detail easy to trip over: wasmtime 50's own `Result` type is `wasmtime::Result<T>` (an alias for `Result<T, wasmtime::Error>`), not `anyhow::Result<T>`, even though the two `Error` types look similar enough to pass for each other at a glance. `anyhow::Error::context()` does not exist on `wasmtime::Error`, so a host written as if the two were interchangeable fails to compile the moment it tries to chain `.context(...)` onto a wasmtime call. `host/src/main.rs` bridges the gap with one small extension trait, the same idiom the Part 2 host uses:

```rust
trait WasmCtx<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T>;
}
impl<T> WasmCtx<T> for wasmtime::Result<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T> {
        self.map_err(|e| anyhow::anyhow!("{ctx}: {e}"))
    }
}
```

Every `.wc("...")` call you have read in this chapter's listings is that trait, converting a `wasmtime::Result<T>` into the `anyhow::Result<T>` the rest of `main` returns, with a short context string attached. Classifying a trap works the opposite direction, downcasting an `anyhow`-wrapped error back down to wasmtime's own `Trap` type:

```rust
fn expect_trap(err: &wasmtime::Error, want: Trap, ctx: &str) -> Result<()> {
    match err.downcast_ref::<Trap>() {
        Some(t) if *t == want => {
            println!("    {ctx}: trapped with {t:?} (as expected)");
            Ok(())
        }
        Some(t) => bail!("ASSERT FAIL [{ctx}]: expected {want:?}, got {t:?}"),
        None => bail!("ASSERT FAIL [{ctx}]: expected a {want:?} trap, got non-trap error: {err:#}"),
    }
}
```

`downcast_ref::<Trap>()` works because `wasmtime::Error` carries its source error's concrete type internally and exposes a downcast, the same pattern `anyhow::Error` itself uses, borrowed because wasmtime's own error type predates this host's dependency on `anyhow` and the two needed to interoperate. This function is also where the ResourceLimiter section's restraint becomes a design choice rather than an oversight: `expect_trap` is only called for fuel and epoch, where the trap code is a stable, documented contract of the control itself; the grow scenario inspects `downcast_ref::<Trap>()` for a log line but asserts on the Ok/Err shape and the contrast run instead, because `UnreachableCodeReached` is an artifact of how the guest's allocator happens to fail, not a promise wasmtime makes about what a denied `memory.grow` always produces.

## Build, run, observe

```bash
cd examples/part4-runtimes/wasmtime-host && ./build.sh
```

`build.sh` builds the guest component with `cargo-component`, builds the native host crate, and runs the host against the guest through all four scenarios: the host-caps import call, the fuel-metered spin, the epoch-interrupted spin, and the memory-capped grow. Each scenario prints a contrast pair, a run where the control is generous and the guest succeeds next to a run where the same unmodified guest trips the control and traps, and the script exits non-zero if any assertion in `host/src/main.rs` fails, so it works as a CI gate rather than a transcript you eyeball by hand. A successful run prints all four `===` sections, each ending in either a trap classified `(as expected)` or a captured call count; see `examples/part4-runtimes/wasmtime-host/README.md` for the full scenario breakdown.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for the <code>wasmtime</code> CLI (<code>wasmtime run</code>, <code>wasmtime serve -S cli</code>) when a component only needs WASI and the controls a <code>-W</code>/<code>-S</code>/<code>-O</code> flag already exposes: <code>-W fuel=N</code> and <code>-W epoch-interruption=y</code> cover two of this chapter's three controls without a line of Rust, and every host in Parts 2 and 3 of this book got by without an embedding at all. Reach for the embedded <code>wasmtime</code> crate, as this chapter's host does, the moment any one of three things is true: the component imports a capability beyond WASI that only your process can supply (this chapter's <code>host-caps</code>), you need to read back host-side state after a run (fuel remaining, a limiter's deny count, a capability's call counters) rather than just an exit code, or you need a <em>composite</em> policy (fuel on some Stores, epoch on others, a memory cap layered under both) that a single CLI invocation's flat flag list cannot express because fuel and epoch interruption are <code>Config</code>-time decisions baked into one <code>Engine</code> each. Inside the embedding, default to fuel for a hard, deterministic ceiling on computation (it needs no helper thread and traps at an exact, repeatable boundary); default to epoch interruption when the ceiling is wall-clock time rather than instruction count, accepting the cost of a ticker thread and epoch's coarser, tick-granularity trip point; and always attach a <code>ResourceLimiter</code> independently of both, because it is the only one of the three controls that gates memory rather than CPU time, and a guest that respects its fuel budget can still try to claim unbounded memory in that same budget.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model's embedding story and the host/guest boundary this chapter's `Linker` and `Store` wiring builds on directly.
- Shashank Jain, *WebAssembly for Cloud* (Apress): host-side resource governance and sandboxing trade-offs, the same ground this chapter's fuel/epoch/limiter trio covers for wasmtime specifically.
- [Wasmtime's Rust embedding guide](https://docs.wasmtime.dev/examples-rust.html): `Engine`/`Store`/`Linker` fundamentals and the `wasmtime::component::bindgen!` macro this chapter's host and the Rust provider's host both depend on.
- [Wasmtime CLI reference](https://docs.wasmtime.dev/cli-options.html): the `-O`/`-C`/`-D`/`-W`/`-S` flag families, including the `-W fuel=N` and `-W epoch-interruption` flags this chapter's Decision callout contrasts against the embedded API.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): the canonical description of imports, the Linker's role in satisfying them, and the resource-handle semantics `ResourceTable` implements.

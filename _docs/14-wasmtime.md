---
title: "wasmtime"
order: 14
part: "Runtimes: wasmtime & wasmCloud"
description: "Embed wasmtime in a native Rust host: the Engine, Store and Linker lifecycle, a host-provided import satisfied by a Rust closure, and the three Store-level controls (fuel, epoch interruption and a ResourceLimiter) that stop a guest from running away with the process."
duration: "22 min read"
---

## Learning objectives

By the end of this chapter you can:

- Choose between the `wasmtime` CLI and the embedded `wasmtime` crate.
- Build an `Engine`, a `Linker<T>` and a `Store<T>` by hand, wire WASI into the linker, and satisfy a component's own import with a Rust closure through `bindgen!`.
- Meter a guest with fuel (`Config::consume_fuel`, `Store::set_fuel`) and say why exhausting the budget is a trap, not an `Err`.
- Interrupt a guest on a deadline with epoch interruption and a ticker thread, and say why this control needs a second thread where fuel does not.
- Cap a guest's linear memory with a `ResourceLimiter`, and say why a denied `memory.grow` reaches the host as a trap.
- Classify a `wasmtime::Error` as a specific `Trap` with `downcast_ref::<Trap>()`.

## Why this matters

Every host so far did the same three things: load a component, instantiate it against a `Linker` built from `wasmtime_wasi::p2::add_to_linker_sync`, and call an export. None of them granted the guest anything beyond WASI, limited how long a call could run, or capped the memory a call could claim. That is fine for bounded, well-behaved operations. It leaves open what a host does with a guest that spins forever or claims more memory than the host will give.

Here, one guest component runs under one native host that embeds the component-model runtime of **wasmtime 50** as a crate. The guest exports `run(mode, iterations)` with three modes: `clean` does bounded work and calls back into the host, `spin` loops without end, and `grow` claims a megabyte of linear memory at a time and holds it. The host runs all three under four `Store` configurations and checks that the control it configured fired, not just that the guest failed. Each control is paired with a run where it is generous and the same unmodified guest succeeds.

{% include excalidraw.html file="14-embedding-architecture" alt="A host box builds an Engine, a Linker with WASI and the host-caps import wired in through a HasSelf getter, then a Store with a limiter closure, then instantiates the guest. The guest exports run(mode, iterations) and imports host-caps::host-quote and host-caps::host-now. Calls cross into the guest through run, and the guest's imports call back into the host's implementation of the host-caps trait. The Linker closure is the whole of the guest's ambient authority." caption="Figure 14.1: the host's Engine, Store and Linker lifecycle, the host-caps import wired in by closure, and the guest calling back across the boundary." %}

## The CLI and the embedded crate

`wasmtime run composed.wasm` and `wasmtime serve -S cli composed-http-rust.wasm --addr 127.0.0.1:8080` use wasmtime as a command: a prebuilt binary that takes a `.wasm` file and flags. The binary groups its flags into five families: `-O` (optimize), `-C` (codegen), `-D` (debug), `-W` (Wasm semantics) and `-S` (WASI), each with an `-X help` listing and a `--config FILE` TOML form.

The embedded host depends on the crate (`wasmtime = "50"`) and calls the same `Engine`, `Store`, `Linker` and `Config` types the CLI is built on. The two are different altitudes on one runtime. The `-W` family already exposes two of the three controls below, `-W fuel=N` and `-W epoch-interruption`, so `wasmtime run -W fuel=100000 guest.wasm` caps a `.wasm` file from outside without any Rust. What no flag can do is hand a component a **host-provided import**. When a component imports something beyond WASI, such as a pricing service or a clock, only an embedding can supply it.

## Engine, Store and Linker

Three types, three lifetimes:

| Type | Lifetime | Holds |
|---|---|---|
| `Engine` | Built once per `Config`; cheap to clone (it wraps an `Arc`) | Compiled code and the `Config` that produced it |
| `Linker<T>` | Built once per `Engine`, reused across stores | Host implementations for a component's imports |
| `Store<T>` | One per component instance; cheap enough to build per run | Runtime state: WASI context, memory limiter, host data |

Fuel and epoch metering are properties of the `Config`, decided once and baked into the `Engine`. A running `Store` cannot switch them on, so the host builds one `Engine` per `Config` variant: default, fuel and epoch.

Bindings come from a local WIT world, not the shared contracts:

```rust
wasmtime::component::bindgen!({
    path: "../wit",
    world: "host-demo",
});
```

The macro generates the `HostDemo` world struct with `instantiate` and `call_run`, the `host_caps::Host` trait the host implements, and `host_caps::add_to_linker`. One small function builds the `Linker` for every scenario:

```rust
fn make_linker(engine: &Engine) -> Result<Linker<HostState>> {
    let mut linker: Linker<HostState> = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).wc("add wasi to linker")?;
    host_caps::add_to_linker::<HostState, HasSelf<HostState>>(&mut linker, |s| s)
        .wc("add host-caps import to linker")?;
    Ok(linker)
}
```

The generated `add_to_linker` is parameterized over `D: HasData` because `bindgen!` supports both "the host state implements `Host`" and "a projection of the host state implements `Host`". `HasSelf<HostState>` with the getter `|s| s` picks the first shape. Get either wrong and the build fails with a trait-bound error, which is where the mistake should surface.

`HostState` carries what a `Store` needs for all three controls:

```rust
struct HostState {
    table: ResourceTable,
    wasi: WasiCtx,
    limits: StoreLimits,
    // Observability for the assertions:
    quote_calls: u32,
    now_calls: u32,
}
```

The two counters are plain host-side bookkeeping, not WIT types. They let the host check that an import was called rather than infer it from a return value.

## A host-provided import

The world the guest and host share is small enough to read whole:

```wit
package patterncatalyst:host-demo@0.1.0;

/// Host-provided capabilities. The host implements these functions and supplies
/// them to the guest at link time through a wasmtime `Linker` closure. The guest
/// cannot call anything the host does not wire in; this interface is the whole
/// of the guest's ambient authority.
///
/// This is a local world for the embedding example only; it never touches the
/// repository contract under contracts/wit. It models a host-side capability (a
/// pricing and clock service) rather than re-exporting the cargo domain, so the
/// example shows the host import direction.
interface host-caps {
    /// A host-computed quote for a cargo id. Pure host logic: the guest has no
    /// way to produce this itself and must call across the boundary.
    host-quote: func(id: string) -> string;

    /// A host-provided clock reading. Returning it from the host keeps the guest
    /// deterministic and shows a second, numeric host import.
    host-now: func() -> u64;
}

/// The guest world: it imports the host capability and exports one `run`
/// entrypoint the host drives with a mode selector:
///   "clean" -> light work; calls both host imports; returns a summary
///   "spin"  -> a tight compute loop (drives the fuel and epoch traps)
///   "grow"  -> repeated linear-memory growth (drives the ResourceLimiter deny)
world host-demo {
    import host-caps;

    /// Run `mode` for up to `iterations` steps; returns a human-readable summary.
    export run: func(mode: string, iterations: u64) -> string;
}
```

Every component so far exported the cargo domain for a host to call. Here the guest imports a capability only the native host can supply, and has no other way to get the value. The guest calls it directly:

```rust
                let quote = host_caps::host_quote("CARGO-USNYC-DEHAM");
                let now = host_caps::host_now();
```

The host implements the trait in ordinary Rust:

```rust
impl host_caps::Host for HostState {
    fn host_quote(&mut self, id: String) -> String {
        self.quote_calls += 1;
        // Pure host logic: a fixed book rate the guest cannot compute itself.
        format!("{id}=1500.00USD@host")
    }

    fn host_now(&mut self) -> u64 {
        self.now_calls += 1;
        HOST_NOW
    }
}
```

The `import host-caps` line is everything the guest declared it needs, and `make_linker` is everything the host agreed to supply. A clean run shows the call crossed the boundary: the host's format string comes back out through the guest's return value.

```
=== 1. clean run (host-provided import) ===
    guest returned: clean mode=ok quote=[CARGO-USNYC-DEHAM=1500.00USD@host] now=1700000000 acc=159304473746738296
    host-caps fired: host_quote x1, host_now x1, host-provided import works
```

## Fuel: metered execution

Fuel counts down a budget of abstract execution units as the guest runs and traps when it reaches zero. It needs no thread of the host's own. `Config` turns the mechanism on and `Store` sets the number:

```rust
    let mut fuel_cfg = Config::new();
    fuel_cfg.consume_fuel(true);
    let fuel_engine = Engine::new(&fuel_cfg)?;
```

```rust
    store.set_fuel(100_000).wc("set small fuel")?;
```

The `spin` mode carries a data dependency through its loop (`acc = acc.wrapping_mul(i | 1).wrapping_add(0x9E3779B97F4A7C15)`) so the optimizer cannot delete it. The fuel run asks it for a billion iterations, and a 100,000-unit budget stops it long before that. The paired run gives a `clean` call 50,000,000 units and finishes with fuel left over, which shows fuel was consumed at all; a build where `consume_fuel` silently did nothing would otherwise print a plausible clean run.

```
=== 2. fuel metering ===
    ample fuel: clean run ok, fuel remaining=49967929: clean mode=ok quote=[CARGO-USNYC-DEHAM=1500.00USD@host] now=1700000000 acc=159304473746738296
    fuel: trapped with OutOfFuel (as expected)
```

## Epoch interruption: deadlines from outside

Fuel counts instructions. Epoch interruption counts time, and nothing inside the `Engine` advances a clock on its own. `Config::epoch_interruption(true)` enables it, `Store::set_epoch_deadline(n)` sets how many ticks of the engine's global epoch counter the guest may run through, and something external must call `Engine::increment_epoch()` to produce the ticks:

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

Cloning an `Engine` shares its compiled code and epoch state, so the ticker holds its own handle and never touches the `Store` the guest runs in. A far deadline (`set_epoch_deadline(1_000_000)`) never notices the ticker during a short `clean` run. A deadline of 1 interrupts the same `spin` mode, asked for 100 billion iterations, on the next tick. The host stops and joins the ticker before it checks the result, so a failed check never leaves a thread running.

```
=== 3. epoch interruption ===
    far deadline: clean run ok: clean mode=ok quote=[CARGO-USNYC-DEHAM=1500.00USD@host] now=1700000000 acc=159304473746738296
    epoch: trapped with Interrupt (as expected)
```

{% include excalidraw.html file="14-store-safety-controls" alt="Three columns run the same guest under three Stores. Fuel: Config::consume_fuel(true) and set_fuel(100_000) exhaust mid-loop and trap with OutOfFuel; set_fuel(50_000_000) succeeds. Epoch: Config::epoch_interruption(true), set_epoch_deadline(1) and a ticker thread calling engine.increment_epoch() every 5ms trap with Interrupt; a far deadline succeeds. ResourceLimiter: StoreLimitsBuilder with an 8 MiB memory_size, attached with store.limiter, denies a memory.grow past the cap and the allocator aborts; a 256 MiB cap succeeds at 64 blocks and 67108864 bytes." caption="Figure 14.2: fuel, epoch interruption and a ResourceLimiter, each contrasted against a run that succeeds." %}

## ResourceLimiter: capping memory

Neither fuel nor epochs limit how much linear memory a guest may claim. `StoreLimits`, built with `StoreLimitsBuilder`, implements the `ResourceLimiter` trait, and attaching one is a single call:

```rust
    let capped = StoreLimitsBuilder::new().memory_size(8 * 1024 * 1024).build();
    let mut store = Store::new(&engine, new_state(capped));
    store.limiter(|s| &mut s.limits);
```

The `grow` mode claims a megabyte at a time and holds each chunk in a `Vec`, so the allocator cannot reuse freed pages. 64 iterations is 64 MiB. Under an 8 MiB cap the growth is denied, and the denial does not come back as a `Result::Err` the way a WIT-level `cargo-error` would. The guest's Rust allocator sees `memory.grow` fail and aborts, so the host sees a trap:

```
=== 4. resource limiter (memory cap) ===
memory allocation of 1048576 bytes failed
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
    grow past the 8 MiB cap was denied -> trap UnreachableCodeReached (as expected)
    same grow under 256 MiB cap succeeds: grow done blocks=64 bytes=67108864
```

`UnreachableCodeReached` is whatever trap a Rust allocator abort compiles to, not a dedicated "memory capped" trap, so the host does not assert on the code the way it does for `OutOfFuel` and `Interrupt`. It asserts on the pair: the identical 64 MiB request fails under the 8 MiB cap and succeeds under 256 MiB. A limiter that did nothing would let both through, and a guest that crashed on large allocations would fail both.

## Classifying errors

`wasmtime::Result<T>` is `Result<T, wasmtime::Error>`, not `anyhow::Result<T>`. The two error types look alike, but `.context()` does not exist on `wasmtime::Error`, so a host written as if they were interchangeable fails to compile. A small extension trait bridges them:

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

Every `.wc("...")` above is that trait. Going the other way, `downcast_ref::<Trap>()` recovers wasmtime's own `Trap` type from the error:

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

Use it only where the trap code is a documented contract of the control, as with fuel and epoch. For a denied `memory.grow`, check the outcome and its contrast run instead.

> **Decision**
>
> Use the `wasmtime` CLI (`wasmtime run`, `wasmtime serve -S cli`) when a component needs only WASI and the controls a flag already exposes, such as `-W fuel=N` and `-W epoch-interruption=y`. Embed the crate when the component imports a capability only your process can supply, when you need to read host-side state after a run (fuel remaining, call counters), or when you need a composite policy, because fuel and epoch interruption are `Config`-time choices baked into one `Engine` each. Inside the embedding, use fuel for a deterministic ceiling on computation with no helper thread, and epoch interruption when the ceiling is wall-clock time, accepting a ticker thread and a coarser trip point. Attach a `ResourceLimiter` regardless: it is the only one of the three that gates memory, and a guest inside its fuel budget can still claim unbounded memory.

> **🤖 Explore with your agent**
>
> "In examples/part4-runtimes/wasmtime-host, add a third host-caps function `host-fee: func(weight-kg: f64) -> string` to wit/host-world.wit, implement it for `HostState` in host/src/main.rs with its own call counter, call it from the guest's `clean` mode, and keep the fuel, epoch and ResourceLimiter scenarios unchanged. Then explain which of those three controls you would still attach if the host served untrusted guests, and why."
>
> Check: `cd examples/part4-runtimes/wasmtime-host && ./build.sh` exits zero with all four `===` sections, and the clean run shows the new fee in the guest's return value.

## Build, run, observe

```bash
cd examples/part4-runtimes/wasmtime-host && ./build.sh
```

The script builds the guest with `cargo-component`, builds the host crate and runs the host against the guest through four scenarios: the host-caps import, the fuel-metered spin, the epoch-interrupted spin and the memory-capped grow. It exits non-zero if any check fails. A passing run prints all four `===` sections, each ending in a classified trap or a call count. The README beside the script has the scenario breakdown.

Experiments, each checked by re-running `./build.sh`:

- Raise the 8 MiB `memory_size` cap to 256 MiB: the `grow` run is no longer denied, and the host fails with "grow run should have been denied".
- Lower the 50,000,000 fuel in the clean contrast run to 1,000: the clean run traps with `OutOfFuel` and the host stops.
- Change `1500.00USD@host` in the `host_quote` format string: the host fails because the guest's summary no longer carries the host-provided data.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model's embedding story and the host and guest boundary the `Linker` and `Store` wiring builds on.
- Shashank Jain, *WebAssembly for Cloud* (Apress): host-side resource governance and sandboxing trade-offs.
- [Wasmtime's Rust embedding guide](https://docs.wasmtime.dev/examples-rust.html): `Engine`, `Store`, `Linker` and the `wasmtime::component::bindgen!` macro.
- [Wasmtime CLI reference](https://docs.wasmtime.dev/cli-options.html): the `-O`, `-C`, `-D`, `-W` and `-S` flag families, including `-W fuel=N` and `-W epoch-interruption`.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): imports, the Linker's role in satisfying them and the `ResourceTable` semantics.

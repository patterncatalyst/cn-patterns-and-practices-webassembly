// Native host embedding wasmtime 50 (ch14).
//
// Beyond the Part 2/3 hosts (which only load a component and call its exports),
// this host demonstrates the control a host keeps over an embedded guest:
//
//   1. HOST-PROVIDED IMPORT. The local host-demo world imports `host-caps`
//      (host-quote / host-now). The host implements them in Rust and wires them
//      through a Linker closure; the guest's "clean" run calls across the
//      boundary into them. We assert the host saw the calls AND the returned
//      value carries the host's data.
//   2. FUEL. Config::consume_fuel(true) + Store::set_fuel(small). The "spin"
//      guest exhausts the budget -> Trap::OutOfFuel.
//   3. EPOCH INTERRUPTION. Config::epoch_interruption(true) +
//      Store::set_epoch_deadline(1) + a ticker thread calling
//      Engine::increment_epoch(). The "spin" guest is interrupted -> Trap::Interrupt.
//   4. RESOURCE LIMITER. A ResourceLimiter caps linear memory; the "grow" guest's
//      growth past the cap is DENIED (the limiter records it; the guest's failed
//      memory.grow becomes a trap).
//
// Each limited run is contrasted with a clean run that succeeds, so "the control
// fired" is distinguished from "the guest just failed". Any missed assertion
// aborts with a non-zero exit — nothing is faked.
//
// Usage: host-demo-host <guest-component.wasm>

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use anyhow::{bail, Result};
use wasmtime::component::{Component, HasSelf, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store, StoreLimits, StoreLimitsBuilder, Trap};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

// wasmtime 50 returns its own `wasmtime::Error` (not `anyhow::Error`), so
// anyhow's `.context()` does not apply to its results. This extension bridges a
// `wasmtime::Result<T>` into an `anyhow::Result<T>` with a context message —
// the same idiom the Part 2 host uses.
trait WasmCtx<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T>;
}
impl<T> WasmCtx<T> for wasmtime::Result<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T> {
        self.map_err(|e| anyhow::anyhow!("{ctx}: {e}"))
    }
}

// Generate bindings for the LOCAL host-demo world. This gives us:
//   * `HostDemo` (world struct) with `instantiate` + `call_run`,
//   * `patterncatalyst::host_demo::host_caps::Host` (the import trait we impl),
//   * `patterncatalyst::host_demo::host_caps::add_to_linker`.
wasmtime::component::bindgen!({
    path: "../wit",
    world: "host-demo",
});

use patterncatalyst::host_demo::host_caps;

// Deterministic host constants so the guest's "clean" summary is reproducible.
const HOST_NOW: u64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Store state. Holds WASI (so the guest's std/alloc/stdio imports resolve the
// same way as the Part 2 host), the host-capability call counter, and the
// per-store memory limits consulted by the ResourceLimiter.
// ---------------------------------------------------------------------------
struct HostState {
    table: ResourceTable,
    wasi: WasiCtx,
    limits: StoreLimits,
    // Observability for the assertions:
    quote_calls: u32,
    now_calls: u32,
}

impl WasiView for HostState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

// The host-provided capability. This is the import direction: the GUEST calls
// these; the HOST runs the code. The guest has no other way to obtain a quote or
// the clock reading.
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

fn new_state(limits: StoreLimits) -> HostState {
    HostState {
        table: ResourceTable::new(),
        wasi: WasiCtxBuilder::new().inherit_stderr().build(),
        limits,
        quote_calls: 0,
        now_calls: 0,
    }
}

// Build a linker with WASI + the host-caps import wired in.
fn make_linker(engine: &Engine) -> Result<Linker<HostState>> {
    let mut linker: Linker<HostState> = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).wc("add wasi to linker")?;
    host_caps::add_to_linker::<HostState, HasSelf<HostState>>(&mut linker, |s| s)
        .wc("add host-caps import to linker")?;
    Ok(linker)
}

// Classify a run error as a specific wasm trap, or bail with context.
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

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        bail!("usage: host-demo-host <guest-component.wasm>");
    }
    let wasm_path = &args[1];

    // =====================================================================
    // 1 + 4. Clean run and ResourceLimiter denial share a default Engine
    //        (no fuel, no epoch). The ONLY difference is the per-store memory
    //        cap, which isolates "the limiter fired" from any other control.
    // =====================================================================
    let engine = Engine::new(&Config::new())?;
    let component = Component::from_file(&engine, wasm_path)
        .wc(format!("loading guest component {wasm_path}"))?;
    let linker = make_linker(&engine)?;

    // ---- 1. Clean run: host import works, call succeeds. ----
    println!("=== 1. clean run (host-provided import) ===");
    let generous = StoreLimitsBuilder::new()
        .memory_size(256 * 1024 * 1024) // 256 MiB — never the binding constraint
        .build();
    let mut store = Store::new(&engine, new_state(generous));
    store.limiter(|s| &mut s.limits);
    let bindings = HostDemo::instantiate(&mut store, &component, &linker)
        .wc("instantiate guest (clean)")?;
    let summary = bindings
        .call_run(&mut store, "clean", 10_000)
        .wc("call run(clean)")?;
    println!("    guest returned: {summary}");
    // The host-provided import must have fired, and its data must be in the result.
    if store.data().quote_calls < 1 || store.data().now_calls < 1 {
        bail!(
            "ASSERT FAIL [host-import]: host-caps not called (quote_calls={}, now_calls={})",
            store.data().quote_calls,
            store.data().now_calls
        );
    }
    if !summary.contains("1500.00USD@host") || !summary.contains(&HOST_NOW.to_string()) {
        bail!("ASSERT FAIL [host-import]: guest summary missing host-provided data: {summary}");
    }
    println!(
        "    host-caps fired: host_quote x{}, host_now x{} — host-provided import works",
        store.data().quote_calls,
        store.data().now_calls
    );

    // ---- 4. ResourceLimiter: cap memory small, grow past it -> denied. ----
    println!("=== 4. resource limiter (memory cap) ===");
    // Cap total linear memory at 8 MiB; the guest tries to hold 64 MiB.
    let capped = StoreLimitsBuilder::new().memory_size(8 * 1024 * 1024).build();
    let mut store = Store::new(&engine, new_state(capped));
    store.limiter(|s| &mut s.limits);
    let bindings = HostDemo::instantiate(&mut store, &component, &linker)
        .wc("instantiate guest (grow)")?;
    match bindings.call_run(&mut store, "grow", 64) {
        Ok(out) => bail!("ASSERT FAIL [limiter]: grow run should have been denied, returned Ok: {out}"),
        Err(e) => {
            // The denial surfaces as a trap when the Rust allocator aborts on the
            // failed memory.grow. StoreLimits enforced the cap; without it the
            // same guest with the generous limit grows fine (proven above in the
            // clean run's 256 MiB ceiling).
            match e.downcast_ref::<Trap>() {
                Some(t) => println!("    grow past the 8 MiB cap was denied -> trap {t:?} (as expected)"),
                None => println!("    grow past the 8 MiB cap failed as expected: {e:#}"),
            }
        }
    }
    // Contrast: the SAME guest grows the same amount fine under a generous cap,
    // proving the deny was the limiter and not an unconditional guest failure.
    let generous2 = StoreLimitsBuilder::new()
        .memory_size(256 * 1024 * 1024)
        .build();
    let mut store = Store::new(&engine, new_state(generous2));
    store.limiter(|s| &mut s.limits);
    let bindings = HostDemo::instantiate(&mut store, &component, &linker)
        .wc("instantiate guest (grow-ok)")?;
    let out = bindings
        .call_run(&mut store, "grow", 64)
        .wc("call run(grow) under generous cap")?;
    println!("    same grow under 256 MiB cap succeeds: {out}");

    // =====================================================================
    // 2. Fuel metering on its own Engine.
    // =====================================================================
    println!("=== 2. fuel metering ===");
    let mut fuel_cfg = Config::new();
    fuel_cfg.consume_fuel(true);
    let fuel_engine = Engine::new(&fuel_cfg)?;
    let fuel_component = Component::from_file(&fuel_engine, wasm_path)
        .wc("loading guest (fuel engine)")?;
    let fuel_linker = make_linker(&fuel_engine)?;

    // Clean contrast: plenty of fuel -> succeeds.
    let generous3 = StoreLimitsBuilder::new()
        .memory_size(256 * 1024 * 1024)
        .build();
    let mut store = Store::new(&fuel_engine, new_state(generous3));
    store.limiter(|s| &mut s.limits);
    store.set_fuel(50_000_000).wc("set generous fuel")?;
    let bindings = HostDemo::instantiate(&mut store, &fuel_component, &fuel_linker)
        .wc("instantiate guest (fuel-ok)")?;
    let out = bindings
        .call_run(&mut store, "clean", 10_000)
        .wc("call run(clean) with ample fuel")?;
    let remaining = store.get_fuel().unwrap_or(0);
    println!("    ample fuel: clean run ok, fuel remaining={remaining}: {out}");
    if remaining >= 50_000_000 {
        bail!("ASSERT FAIL [fuel]: no fuel was consumed ({remaining}) — metering not active");
    }

    // Starve it: a tiny budget against a long spin -> OutOfFuel.
    let generous4 = StoreLimitsBuilder::new()
        .memory_size(256 * 1024 * 1024)
        .build();
    let mut store = Store::new(&fuel_engine, new_state(generous4));
    store.limiter(|s| &mut s.limits);
    store.set_fuel(100_000).wc("set small fuel")?;
    let bindings = HostDemo::instantiate(&mut store, &fuel_component, &fuel_linker)
        .wc("instantiate guest (fuel-trap)")?;
    match bindings.call_run(&mut store, "spin", 1_000_000_000) {
        Ok(out) => bail!("ASSERT FAIL [fuel]: spin should have run out of fuel, returned Ok: {out}"),
        Err(e) => expect_trap(&e, Trap::OutOfFuel, "fuel")?,
    }

    // =====================================================================
    // 3. Epoch interruption on its own Engine, with a ticker thread.
    // =====================================================================
    println!("=== 3. epoch interruption ===");
    let mut epoch_cfg = Config::new();
    epoch_cfg.epoch_interruption(true);
    let epoch_engine = Engine::new(&epoch_cfg)?;
    let epoch_component = Component::from_file(&epoch_engine, wasm_path)
        .wc("loading guest (epoch engine)")?;
    let epoch_linker = make_linker(&epoch_engine)?;

    // Ticker thread: bump the engine epoch every 5 ms until told to stop.
    let ticker_engine = epoch_engine.clone();
    let stop = Arc::new(AtomicBool::new(false));
    let stop_t = stop.clone();
    let ticker = thread::spawn(move || {
        while !stop_t.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(5));
            ticker_engine.increment_epoch();
        }
    });

    // Clean contrast: a far deadline + a quick run -> succeeds before any trip.
    let generous5 = StoreLimitsBuilder::new()
        .memory_size(256 * 1024 * 1024)
        .build();
    let mut store = Store::new(&epoch_engine, new_state(generous5));
    store.limiter(|s| &mut s.limits);
    store.set_epoch_deadline(1_000_000); // effectively unreachable for a short run
    let bindings = HostDemo::instantiate(&mut store, &epoch_component, &epoch_linker)
        .wc("instantiate guest (epoch-ok)")?;
    let out = bindings
        .call_run(&mut store, "clean", 10_000)
        .wc("call run(clean) with a far epoch deadline")?;
    println!("    far deadline: clean run ok: {out}");

    // Trip it: deadline of 1 epoch + a long spin -> the ticker interrupts it.
    let generous6 = StoreLimitsBuilder::new()
        .memory_size(256 * 1024 * 1024)
        .build();
    let mut store = Store::new(&epoch_engine, new_state(generous6));
    store.limiter(|s| &mut s.limits);
    store.set_epoch_deadline(1);
    let bindings = HostDemo::instantiate(&mut store, &epoch_component, &epoch_linker)
        .wc("instantiate guest (epoch-trap)")?;
    let epoch_result = bindings.call_run(&mut store, "spin", 100_000_000_000);
    // Stop the ticker before asserting so we never leak the thread.
    stop.store(true, Ordering::Relaxed);
    ticker.join().ok();
    match epoch_result {
        Ok(out) => bail!("ASSERT FAIL [epoch]: spin should have been interrupted, returned Ok: {out}"),
        Err(e) => expect_trap(&e, Trap::Interrupt, "epoch")?,
    }

    println!();
    println!("PASS — wasmtime-host (ch14):");
    println!("  * host-provided import (host-caps) satisfied by a Rust closure and called by the guest");
    println!("  * fuel metering exhausts -> OutOfFuel trap (clean run with ample fuel succeeds)");
    println!("  * epoch interruption via a ticker thread -> Interrupt trap (far deadline succeeds)");
    println!("  * ResourceLimiter denies memory growth past the cap (same grow succeeds uncapped)");
    Ok(())
}

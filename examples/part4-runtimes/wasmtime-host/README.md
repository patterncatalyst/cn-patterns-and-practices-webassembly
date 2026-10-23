# ch14: Embedding wasmtime, host-provided imports and Store/Engine controls

A native Rust host (`host/`) embeds the **wasmtime 50** component-model runtime
and drives a guest component (`guest/`) through four scenarios, asserting that
each host-side control fires. This goes beyond the Part 2/3 hosts, which
only load a component and call its exports.

```
guest/  cargo-component -> host_demo_guest.wasm   (imports host-caps, exports run)
host/   embeds wasmtime 50, implements host-caps, sets fuel/epoch/limits
```

## Run it

```bash
./build.sh
```

`build.sh` builds the guest component, builds the host, and runs the host against
the guest. It exits non-zero on any missed assertion (CI gate). Both
`Cargo.lock` files are committed.

## What it proves

### 1. Host-provided import (host-side capability)

The LOCAL world `wit/host-world.wit` defines `host-caps` with two host functions
(`host-quote`, `host-now`) and a guest `run` export. The repository contract
under `contracts/wit` is **not** touched: this is a self-contained local world.

The host implements `host-caps` in Rust and wires it into the component `Linker`
with the generated binding:

```rust
wasmtime::component::bindgen!({ path: "../wit", world: "host-demo" });

impl host_caps::Host for HostState {
    fn host_quote(&mut self, id: String) -> String { /* host logic */ }
    fn host_now(&mut self) -> u64 { /* host clock */ }
}

host_caps::add_to_linker::<HostState, HasSelf<HostState>>(&mut linker, |s| s)?;
```

The guest's `run("clean", …)` calls across the boundary into both functions; the
host asserts it saw the calls and that the returned summary carries the host's
data. WASI is added with the same idiom as the Part 2 host
(`wasmtime_wasi::p2::add_to_linker_sync`): the guest's std/alloc/stdio imports
resolve through it.

### 2. Fuel: `OutOfFuel` trap

`Config::consume_fuel(true)` + `Store::set_fuel(100_000)`. The guest's `spin`
loop exhausts the budget and the call traps with `Trap::OutOfFuel`. A contrast
run with ample fuel succeeds and reports fuel consumed, so "the meter fired" is
distinct from "the guest failed".

### 3. Epoch interruption: `Interrupt` trap

`Config::epoch_interruption(true)` + `Store::set_epoch_deadline(1)` + a ticker
thread calling `Engine::increment_epoch()` every 5 ms. The `spin` loop is
interrupted and the call traps with `Trap::Interrupt`. A contrast run with a far
deadline completes.

### 4. ResourceLimiter: denied memory growth

A `StoreLimits` (wasmtime's built-in `ResourceLimiter`) caps linear memory at
8 MiB via `Store::limiter`. The guest's `grow` run tries to hold 64 MiB; the
growth past the cap is denied, and the Rust allocator turns the failed
`memory.grow` into an abort (a trap: you'll see `memory allocation of … bytes
failed` on stderr from the guest). The same `grow` succeeds under a 256 MiB cap,
proving the deny was the limiter.

## Notes worth a chapter callout

- **wasmtime 50 errors are not `anyhow`.** wasmtime returns its own
  `wasmtime::Error`; `anyhow`'s `.context()` does not apply. The host uses a tiny
  `.wc()` extension (same idiom as the Part 2 host) to attach context, and
  classifies traps with `wasmtime::Error::downcast_ref::<Trap>()`.
- **`bindgen!` import linking needs `HasData`.** The generated
  `host_caps::add_to_linker` is parameterized over `D: HasData`; pass
  `HasSelf<HostState>` with a `|s| s` getter to use the store state directly.
- **A denied `memory.grow` surfaces as a trap, not a clean error.** The limiter's
  decision is enforced; the *observable* failure in the guest is the allocator
  aborting. Assert on the limiter outcome (the cap vs. the generous contrast),
  not on a specific trap code.
- **Each control gets its own `Engine`** here (fuel, epoch, default) so the
  configs don't interact; fuel/epoch metering must be enabled at `Config` time.

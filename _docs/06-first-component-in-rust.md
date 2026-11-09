---
title: "First Component in Rust"
order: 6
part: "Building Components in Rust & Go"
description: "Implement the cargo world as a Rust component with cargo-component, from binding generation to a running Wasmtime instance."
duration: "24 min read"
---

## Learning objectives

By the end of this chapter you can:

- Point `cargo-component` at `contracts/wit/` from `[package.metadata.component.target]`, with no WIT file copied into the crate.
- Read the traits `cargo-component` generates from `world cargo` and implement all three (`BookingGuest`, `HandlingGuest` and `GuestCargoTracker`) over in-memory state.
- Explain how a Rust `Result<Booking, CargoError>` lowers into the WIT `result<booking, cargo-error>` without changing the function signature.
- Build with `cargo component build --release`, find the `.wasm` under `target/wasm32-wasip1/release/`, and say why the path says `wasip1`.
- Confirm with `wasm-tools component wit` that the artifact exports exactly `world cargo`, then run it through the native host in `host/`.

## Why this matters

A WIT world isn't executable. A toolchain reads it and generates the types and signatures the source has to satisfy. `examples/part2-building-components/rust/` is a complete `cargo-component` crate that implements `world cargo` end to end, and `host/` is a native Wasmtime binary that calls every exported function and constructs the `cargo-tracker` resource.

The crate is small: one `Cargo.toml`, one `src/lib.rs`, and a generated `bindings.rs` nobody writes by hand. The interesting parts are where generated code and hand-written code meet: the `target` block that selects the world, the trait `impl` blocks, and the one line at the bottom that wires the implementation into the generated exports.

{% include excalidraw.html file="06-rust-build-pipeline" alt="contracts/wit feeding cargo-component, which reads Cargo.toml's package.metadata.component.target and generates bindings.rs with a Guest trait per interface and GuestCargoTracker for the resource. src/lib.rs implements those traits, returning Result<Booking, CargoError>, which generated code lowers to the WIT result<booking, cargo-error>. cargo component build --release produces a wasm32-wasip1 core module, adapted internally into target/wasm32-wasip1/release/cargo_rust.wasm, which exports world cargo." caption="Figure 6.1: One cargo component build --release, from the shared WIT contract to a component that exports world cargo." %}

## Pointing the crate at the shared contract

No `.wit` file lives in the crate. `Cargo.toml` names the shared contract:

```toml
[package]
name = "cargo-rust"
version = "0.1.0"
edition = "2024"

[dependencies]
wit-bindgen-rt = { version = "0.44.0", features = ["bitflags"] }

[lib]
crate-type = ["cdylib"]

# The component targets the repository's shared WIT contract directly: the
# crate does NOT copy the WIT. `target.path` points at contracts/wit (relative
# to this Cargo.toml) and `target.world` selects the provider-side `cargo`
# world, whose three exported interfaces (types, booking, handling) this crate
# implements.
[package.metadata.component]
package = "patterncatalyst:cargo"

[package.metadata.component.target]
path = "../../../contracts/wit"
world = "cargo"

[package.metadata.component.dependencies]
```

- `crate-type = ["cdylib"]` is what `cargo component build` expects. `cargo-component` compiles the crate to a core module and wraps it, and a Rust `rlib` has no relationship to the Component Model's binary format.
- `path` is relative to this `Cargo.toml`, three directories up to the repository's one contract. `world = "cargo"` selects the provider world, which exports `types`, `booking` and `handling`. Changing it to `"cargo-consumer"` generates import bindings instead; the world selection is the only place direction is stated.
- `package = "patterncatalyst:cargo"` is the identity the artifact claims and must match `package patterncatalyst:cargo@0.1.0;` in the contract. A mismatch fails at build time, not at instantiation on a host.
- `[package.metadata.component.dependencies]` is empty because the crate depends on no other WIT package.

## What cargo-component generates

`cargo component build` writes `src/bindings.rs`, declared with `mod bindings;` and never edited by hand; its header opens with a `DO NOT EDIT!` banner naming `wit-bindgen` 0.41.0 as the generator. It mirrors the package one module per interface under `exports::patterncatalyst::cargo::`: a Rust `struct` for every WIT `record`, an `enum` for every WIT `enum`, and a `Guest` trait for each interface that declares functions. `BookingGuest` has a method per function in `booking`. `HandlingGuest` has one per function in `handling` plus an associated type for the `cargo-tracker` resource. WIT `string` becomes Rust's `String` through the `wit-bindgen-rt` runtime crate.

Both traits are named `Guest`, so `src/lib.rs` aliases them on import:

```rust
use bindings::exports::patterncatalyst::cargo::booking::Guest as BookingGuest;
use bindings::exports::patterncatalyst::cargo::handling::{
    Guest as HandlingGuest, GuestCargoTracker,
};
use bindings::exports::patterncatalyst::cargo::types::{
    Booking, Cargo, CargoError, HandlingEvent, HandlingEventType, Itinerary, Leg, Location, Money,
    RouteSpec, RoutingStatus, TransportStatus,
};
```

State is a `thread_local!` `RefCell` holding three `HashMap`s (cargos, bookings, per-cargo event lists). A component runs single-threaded in its own linear memory, so there is nothing for a lock to guard.

## Implementing the Guest traits

`book_cargo` shows validation, deterministic ID derivation and the state write together:

```rust
    fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
        if spec.origin.unlocode.is_empty() || spec.destination.unlocode.is_empty() {
            return Err(CargoError::InvalidLocation(
                "origin and destination must each have a UN/LOCODE".to_string(),
            ));
        }
        if weight_kg <= 0.0 {
            return Err(CargoError::InvalidBooking(
                "weight-kg must be greater than zero".to_string(),
            ));
        }

        let tracking_id = tracking_id_for(&spec.origin, &spec.destination);
        let booking_id = booking_id_for(&spec.origin, &spec.destination);

        let cargo = Cargo {
            tracking_id: tracking_id.clone(),
            origin: spec.origin.clone(),
            destination: spec.destination.clone(),
            weight_kg,
        };
        let booking = Booking {
            booking_id: booking_id.clone(),
            cargo_id: tracking_id.clone(),
            route_spec: spec,
            price: Money {
                amount: PRICE_AMOUNT.to_string(),
                currency: PRICE_CURRENCY.to_string(),
            },
            status: RoutingStatus::NotRouted,
        };

        STATE.with(|s| {
            let mut s = s.borrow_mut();
            s.cargos.insert(tracking_id, cargo);
            s.bookings.insert(booking_id, booking.clone());
        });
        Ok(booking)
    }
```

The generated trait fixes the signature, and the WIT `result<T, E>` becomes `std::result::Result<T, E>`. The body writes `Ok(booking)` and `Err(CargoError::InvalidLocation(...))` like any fallible Rust function, with no hand-written success or failure tag. The export glue converts the `Result` back to the WIT shape the caller receives.

Lookups use the same mapping. `Option::ok_or_else` turns a missing entry into a typed error:

```rust
        STATE.with(|s| {
            s.borrow()
                .cargos
                .get(&tracking_id)
                .cloned()
                .ok_or_else(|| CargoError::NotFound(format!("no cargo {tracking_id}")))
        })
```

`CargoError::NotFound` is a generated variant arm carrying the `string` payload the contract declares, built like any other Rust enum variant. The same function panics on the sentinel tracking ID `__TRAP__`, so the host can tell a recoverable `cargo-error` (an `Err` inside a successful call) from a trap that tears the instance down.

## The cargo-tracker resource

A resource generates a second trait beside `Guest`. `impl HandlingGuest for Component` sets `type CargoTracker = Tracker;`, which tells the export machinery which Rust type backs the WIT resource. `GuestCargoTracker` has methods that take `&self`:

```rust
// The `cargo-tracker` resource. It holds only its tracking id; `history` and
// `current-status` read the live shared event state by that id, so a tracker
// constructed before events are registered still reflects them when queried.
struct Tracker {
    tracking_id: String,
}

impl GuestCargoTracker for Tracker {
    fn new(tracking_id: String) -> Self {
        Tracker { tracking_id }
    }

    fn tracking_id(&self) -> String {
        self.tracking_id.clone()
    }

    fn current_status(&self) -> TransportStatus {
        STATE.with(|s| {
            s.borrow()
                .events
                .get(&self.tracking_id)
                .and_then(|events| events.last())
                .map(|last| status_from_last_event(last.event_type))
                .unwrap_or(TransportStatus::Unspecified)
        })
    }

    fn history(&self) -> Vec<HandlingEvent> {
        STATE.with(|s| {
            s.borrow()
                .events
                .get(&self.tracking_id)
                .cloned()
                .unwrap_or_default()
        })
    }
}
```

`Tracker` holds only its tracking ID. `history` and `current_status` read the shared event map by that ID, so a tracker constructed before any event exists still reflects events registered later: a resource is a live view keyed by identity, not a snapshot. `status_from_last_event` maps `received` to `planned`, `loaded`, `unloaded` and `customs` to `in-transit`, `claimed` to `completed`, and no events to `unspecified`.

The last line of `src/lib.rs` makes everything above reachable:

```rust
bindings::export!(Component with_types_in bindings);
```

`export!` is a macro the generated `bindings.rs` defines. It registers `Component`, the unit struct every `impl` targets, as the type behind the component's export table. Without it the crate compiles as a library implementing two traits nobody instantiates.

## Building and inspecting the component

```bash
cargo component build --release
```

The artifact lands at `target/wasm32-wasip1/release/cargo_rust.wasm`, not under `wasm32-wasip2/`. `cargo-component` compiles a `wasm32-wasip1` core module, then adapts it into a WASI Preview 2 component inside the same invocation. Nothing in the crate names `wasip1`; it is where the intermediate artifact lives.

```bash
wasm-tools component wit target/wasm32-wasip1/release/cargo_rust.wasm
```

This prints the world derived from the binary's embedded component type, not from the source `.wit` files. `export patterncatalyst:cargo/types`, `booking` and `handling` in the output confirm the build satisfies `world cargo` exactly. A host or a composition step runs the same check before trusting the artifact.

`cargo-component` replaces what the Go build does by hand with `wit-bindgen-go` and separate `wasm-tools component embed` and `component new` steps. It folds WIT resolution, binding generation, the `wasip1` compile and the Preview 2 adapt into one command driven by `Cargo.toml`. The cost is a Rust-specific tool with its own release cadence, which stock `cargo build` can't replace.

## Running it through the host

The component has no `main`; something has to call it. `host/src/main.rs` is a native Rust binary that reads the same contract:

```rust
wasmtime::component::bindgen!({
    path: "../../../contracts/wit",
    world: "cargo",
});
```

This generates Wasmtime's caller-side types, where `cargo-component` generated implementer-side traits: one file read for two purposes, the same split as `world cargo` exports against `world cargo-consumer` imports. The host builds a `Linker` with WASI, instantiates the component and gets typed handles per interface:

```rust
    let cargo = Cargo::instantiate(&mut store, &component, &linker)
        .wc("instantiating cargo world")?;

    let booking_api = cargo.patterncatalyst_cargo_booking();
    let handling_api = cargo.patterncatalyst_cargo_handling();
```

Each call then reads like a method call on a local object while crossing into the component's linear memory:

```rust
    let booking = booking_api
        .call_book_cargo(&mut store, &spec, fixture.input.weight_kg)
        .wc("call book-cargo")?
        .map_err(|e| anyhow::anyhow!("book-cargo returned error: {e:?}"))?;
```

The result has two layers. `.wc(...)?` handles a Wasmtime-level failure: a trap, a resource limit, a host error. `.map_err(...)` handles the WIT `Err` arm, a successful call whose answer is a validation failure. The host keeps them separate, as the component does.

The `cargo-tracker` resource crosses with its own convention: a constructor call, method calls on the returned handle, then an explicit drop.

```rust
    let tracker_api = handling_api.cargo_tracker();
    let tracker: ResourceAny = tracker_api
        .call_constructor(&mut store, &booking.cargo_id)
        .wc("call cargo-tracker constructor")?;
    let t_id = tracker_api
        .call_tracking_id(&mut store, tracker)
        .wc("call tracking-id")?;
    assert_eq_ctx!(&fixture.expected.tracker.tracking_id, &t_id, "tracker.tracking-id");
    let t_status = tracker_api
        .call_current_status(&mut store, tracker)
        .wc("call current-status")?;
    assert_eq_ctx!(fixture.expected.tracker.current_status.as_str(), transport_status_str(t_status), "tracker.current-status");
    let t_history = tracker_api
        .call_history(&mut store, tracker)
        .wc("call history")?;
    assert_eq_ctx!(fixture.expected.tracker.history_count, t_history.len(), "tracker.history.count");
    tracker
        .resource_drop(&mut store)
        .wc("drop cargo-tracker resource")?;
```

`ResourceAny` is Wasmtime's opaque handle for a resource whose shape the host doesn't need to know. `resource_drop` is required: skipping it leaks the handle's slot in the component's resource table for the life of the `Store`.

{% include excalidraw.html file="06-host-exercises-component" alt="host/src/main.rs using bindgen! against contracts/wit's cargo world, instantiating cargo_rust.wasm, and calling book-cargo, get-cargo, request-possible-routes, assign-route, register-handling-event three times, list-handling-events, and the cargo-tracker constructor plus its three methods and resource_drop, each call crossing into the matching Guest trait implementation on the component side." caption="Figure 6.2: One host binary and one scenario, every call landing on a Guest trait implementation." %}

> **Decision**
>
> Point the crate at `contracts/wit/` through `[package.metadata.component.target]` instead of vendoring a copy into `rust/wit/`. A vendored copy stays identical to the contract only by discipline, and the Rust and Go crates would each own one with nothing forcing them to agree. With both pointed at the same files, `book-cargo`'s signature can't drift between languages without `contracts/wit/` changing first. The cost is a relative path (`../../../contracts/wit`) that resolves only from this crate's position in the tree. Move `rust/` without updating it and the build fails at resolution time, which beats a silently drifted copy.

> **🤖 Explore with your agent**
>
> "In `examples/part2-building-components/rust/src/lib.rs`, add a `cancel_booking` method to `impl BookingGuest for Component` that removes the booking and returns `CargoError::NotFound` for an unknown ID. First add `cancel-booking: func(booking-id: string) -> result<booking, cargo-error>;` to `contracts/wit/bookings.wit`, keep `[package.metadata.component.target]` pointing at `contracts/wit` rather than copying the file, and rebuild with `cargo component build --release`. Then run `wasm-tools component wit` on `cargo_rust.wasm`."
>
> Check: the build fails until the method exists with the generated signature, and the printed `booking` interface lists `cancel-booking`.

## Build, run, observe

From `examples/part2-building-components/`:

```bash
cd rust
cargo component build --release
wasm-tools component wit target/wasm32-wasip1/release/cargo_rust.wasm   # shows `export ...cargo/{types,booking,handling}`
cd ../host
cargo build --release
./target/release/cargo-host ../rust/target/wasm32-wasip1/release/cargo_rust.wasm ../fixtures/scenario.json rust
```

The host books `USNYC` to `DEHAM` at 1200.5 kg, registers three handling events, queries one `cargo-tracker`, checks every result against `fixtures/scenario.json`, prints `[rust] all assertions passed` to stderr and a normalized JSON summary to stdout. `./verify.sh` one level up runs the sequence for both languages and diffs the two summaries; expect `PASS`. The same script also covers the not-found `cargo-error` against a trap, and composes the consumers with `wac plug`.

- Change `world = "cargo"` to `"cargo-consumer"` in `Cargo.toml`: the crate generates import bindings instead of the `Guest` traits `src/lib.rs` implements.
- Move `rust/` without updating `path`: the build fails at WIT resolution.
- Delete the `export!` line: the crate compiles as a library implementing two traits nobody instantiates, with nothing wired into the export table.
- Skip `resource_drop` in the host: the tracker handle's slot stays in the resource table until the `Store` goes.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model and toolchain mechanics the `cargo-component` build exercises.
- Shashank Jain, *WebAssembly for Cloud* (Apress): component build pipelines and language-specific toolchain trade-offs.
- [cargo-component](https://github.com/bytecodealliance/cargo-component): the full `[package.metadata.component]` configuration beyond `target.path` and `target.world`.
- [Wasmtime's Rust embedding guide](https://docs.wasmtime.dev/examples-rust.html): `wasmtime::component::bindgen!` and the `Linker` and `Store` machinery `host/src/main.rs` builds on.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): the canonical ABI lowering the `Result` to `result` mapping relies on.

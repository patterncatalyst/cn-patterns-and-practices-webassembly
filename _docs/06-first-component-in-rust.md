---
title: "First Component in Rust"
order: 6
part: "Building Components in Rust & Go"
description: "Build and run the first cargo-domain component in Rust with cargo-component, from WIT binding generation to a running wasmtime instance."
duration: "24 min read"
---

## Learning objectives

By the end of this chapter you can:

- Point `cargo-component` at `contracts/wit/` from a crate's `Cargo.toml` using `[package.metadata.component.target]`, with no WIT file copied into the crate.
- Read the `Guest` traits `cargo-component` generates from `world cargo` and implement all three (`BookingGuest`, `HandlingGuest`, and `GuestCargoTracker`) over plain in-memory state.
- Explain how a Rust `Result<Booking, CargoError>` return type lowers into the WIT `result<booking, cargo-error>` the contract declares, and why the function signature never changes to accommodate that.
- Build the crate with `cargo component build --release`, find the resulting `.wasm` under `target/wasm32-wasip1/release/`, and say why that path says `wasip1` rather than `wasip2`.
- Use `wasm-tools component wit` to confirm the built artifact exports exactly `world cargo`, then run it against a real scenario through the native host in `host/`.

## Why this matters

Chapter 3 named the mechanism: a WIT world is not executable, a toolchain reads it and generates the types and function signatures a language's source code has to satisfy. Chapter 5 fixed the vocabulary those signatures are built from: `patterncatalyst:cargo@0.1.0`'s three interfaces, the records and enums in `types`, the four functions in `booking`, the two functions and the `cargo-tracker` resource in `handling`. Neither chapter ran a build. This one does: `examples/part2-building-components/rust/` is a complete, buildable `cargo-component` crate that implements `world cargo` end to end, built with `cargo component build --release` into a real `.wasm` component, inspected with `wasm-tools`, and exercised through a native wasmtime host that calls every exported function and constructs the `cargo-tracker` resource.

The crate stays this small by design: one `Cargo.toml`, one `src/lib.rs`, a generated `bindings.rs` neither you nor this chapter writes by hand. That smallness is the point. Everything interesting in this chapter is the handful of places where the generated bindings and the hand-written implementation meet: the `[package.metadata.component.target]` block that tells `cargo-component` which WIT world to generate against, the `Guest` trait `impl` blocks the crate supplies, and the one line at the bottom of `src/lib.rs` that wires the implementation back into the generated export machinery. Chapter 7 writes the same domain in Go against the identical contract; Chapter 8 composes the two. This chapter's job is to get one working component on the ground first, in the language whose toolchain generates the contract closest to ordinary application code.

{% include excalidraw.html file="06-rust-build-pipeline" alt="contracts/wit feeding cargo-component, which reads Cargo.toml's package.metadata.component.target and generates bindings.rs with a Guest trait per interface and GuestCargoTracker for the resource. src/lib.rs implements those traits, returning Result<Booking, CargoError>, which generated code lowers to the WIT result<booking, cargo-error>. cargo component build --release produces a wasm32-wasip1 core module, adapted internally into target/wasm32-wasip1/release/cargo_rust.wasm, which exports world cargo." caption="Figure 6.1 — one cargo component build --release, from the shared WIT contract to a component that exports world cargo." %}

## Pointing the crate at the shared contract

Nothing under `examples/part2-building-components/rust/` copies a `.wit` file. The crate's `Cargo.toml` names the shared contract directly:

```toml
[package]
name = "cargo-rust"
version = "0.1.0"
edition = "2024"

[dependencies]
wit-bindgen-rt = { version = "0.44.0", features = ["bitflags"] }

[lib]
crate-type = ["cdylib"]

# The component targets the repository's shared WIT contract directly — the
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

Three things in that file carry the whole chapter's setup. `crate-type = ["cdylib"]` is unremarkable on its own (any crate building a dynamic library needs it), but it is what `cargo component build` expects to find rather than the ordinary `rlib` an ordinary `cargo build` produces; the Component Model's binary format has no relationship to a Rust `rlib`, and `cargo-component` compiles the crate to a `cdylib` core module as its own intermediate step. `[package.metadata.component.target]`'s two keys are the part that actually reaches across the repository: `path = "../../../contracts/wit"` is a relative path from this `Cargo.toml` up three directories to the repository's one shared contract, and `world = "cargo"` selects the provider world Chapter 3 and Chapter 5 both named, the one that exports `types`, `booking`, and `handling` rather than importing them. Change that single string to `"cargo-consumer"` and the same crate would generate import bindings instead, the shape a caller rather than an implementer needs; nothing else in the file would have to change, because the world selection is the only place direction is stated. `[package.metadata.component.dependencies]` is present and empty: this crate depends on no other WIT package, only on the one it targets, so the table names that absence directly rather than configuring anything.

The `package = "patterncatalyst:cargo"` line under `[package.metadata.component]` is worth separating from the `target` block beneath it: it names the WIT package identity this crate's own build artifact will claim, matching `contracts/wit/world.wit`'s `package patterncatalyst:cargo@0.1.0;` declaration. A mismatch here (building against a `target.path` whose package identity disagrees with this field) is exactly the kind of error `cargo-component` catches at build time, before a mismatched component ever reaches a host that would otherwise have to fail at instantiation instead.

## What cargo-component generates

Running `cargo component build` (covered fully below) produces `src/bindings.rs`, a file the crate declares with `mod bindings;` and never hand-edits; its header makes the rule explicit: `// Generated by wit-bindgen 0.41.0. DO NOT EDIT!`. The file mirrors the WIT package's structure one module per interface, nested under `exports::patterncatalyst::cargo::`, with a Rust `struct` generated for every WIT `record` and a Rust `enum` for every WIT `enum`:

```rust
pub struct Location {
    pub unlocode: _rt::String,
    pub name: _rt::String,
    pub country: _rt::String,
}
```

That `Location` struct is the generated twin of `contracts/wit/types.wit`'s `record location`, field for field, with WIT's `string` becoming `_rt::String`, a re-export of Rust's own `String` through the `wit-bindgen-rt` runtime crate, not a new type the domain code has to learn. The `booking` and `handling` interfaces generate a `Guest` trait apiece instead of a plain struct, because those two interfaces declare functions, not just data: `BookingGuest` has one method per function in `interface booking`, and `HandlingGuest` has one method per function in `interface handling`, plus an associated type for the `cargo-tracker` resource. This chapter doesn't reproduce `bindings.rs` in full (it runs to hundreds of lines once every record, enum, and trait method is spelled out) because the point of a generated file is that you read the trait signatures it produces, not the generation machinery that produced them. `src/lib.rs`'s imports show exactly which signatures the crate's own code needs:

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

Both `booking::Guest` and `handling::Guest` get aliased on import, as `BookingGuest` and `HandlingGuest`, because WIT names every interface's function-carrying trait `Guest`, and a crate implementing more than one interface needs distinct names to `impl` against. That aliasing is a crate-level naming choice, not something `cargo-component` forces; the generated trait really is named `Guest` in both `booking`'s and `handling`'s generated modules; only the Rust `use ... as` syntax resolves the collision.

## Implementing the Guest traits

`src/lib.rs` opens with a file-level comment that states the chapter's thesis in two sentences: `cargo-component` generates `bindings` from the shared contract, and this file implements the three exported interfaces over simple in-memory state. The state itself is a `thread_local!` `RefCell` holding three `HashMap`s (cargos, bookings, and per-cargo event lists), which is sufficient because a WebAssembly component runs single-threaded inside its own linear memory; there is no concurrent access to guard against with a lock, only the ordinary aliasing discipline `RefCell` already enforces at runtime.

`impl BookingGuest for Component` supplies the four methods `interface booking` declares. `book_cargo` is the one worth reading in full, because it shows the validation, the deterministic ID derivation, and the state write together:

```rust
impl BookingGuest for Component {
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
    // ...
}
```

The function's signature, `fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError>`, is fixed by the generated trait, not a choice this file makes, and it is the exact point where Chapter 3's claim about lowering becomes visible in real code. `contracts/wit/bookings.wit` declares `book-cargo: func(spec: route-spec, weight-kg: f64) -> result<booking, cargo-error>;`. `cargo-component` turns that WIT `result<T, E>` into the Rust `std::result::Result<T, E>` the standard library already defines, which means this implementation writes `Ok(booking)` and `Err(CargoError::InvalidLocation(...))` exactly the way any other fallible Rust function would, with no manual encoding of a success/failure tag anywhere in this file. The generated export machinery handles converting that `Result` back into the WIT `result` shape a caller on the other side of the component boundary receives: a Rust idiom in, a WIT idiom out, with the conversion itself invisible to this code.

`get_cargo` and the `cargo-tracker` resource's `current_status` method show the same `Result`-mapping pattern used for lookups:

```rust
    fn get_cargo(tracking_id: String) -> Result<Cargo, CargoError> {
        STATE.with(|s| {
            s.borrow()
                .cargos
                .get(&tracking_id)
                .cloned()
                .ok_or_else(|| CargoError::NotFound(format!("no cargo {tracking_id}")))
        })
    }
```

`Option::ok_or_else` is the ordinary Rust pattern for turning a missing-value `None` into a typed error, and it reads here exactly as it would in any Rust codebase with no WIT involved at all. `CargoError::NotFound` is a generated variant arm, carrying the `String` payload `contracts/wit/types.wit`'s `variant cargo-error` declared for that case, but constructing it is indistinguishable from constructing any other Rust enum variant. That is the generated bindings doing their job well: the places where this file touches the Component Model directly are the function signatures and the `use` statements pulling in generated types, and everywhere else is ordinary application Rust.

## The cargo-tracker resource

`interface handling` declares one construct Chapter 3 called out as having no equivalent among records, enums, and variants: the `cargo-tracker` `resource`. A resource generates differently from everything else in the package: not a trait method on `Guest` itself, but an associated type plus a second trait, `GuestCargoTracker`, whose methods take `&self` the way an ordinary Rust object's methods would:

```rust
impl HandlingGuest for Component {
    type CargoTracker = Tracker;
    // ...
}

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

`type CargoTracker = Tracker;` on `impl HandlingGuest for Component` is the line that connects the two traits: it tells the generated export machinery which concrete Rust type backs the WIT resource, so a caller's `constructor(tracking-id: string)` call produces a `Tracker` under the hood. `Tracker` itself holds exactly one field (the tracking ID it was constructed with) and nothing else, by design: the comment above the struct states the reason directly. `history` and `current_status` read the same shared `STATE.events` map every handling-event call writes to, keyed by that one stored tracking ID, rather than caching a snapshot at construction time. That means a `Tracker` built before any handling events exist for its cargo still reports the right answer once events arrive later: the resource is a live view keyed by identity, not a value frozen at the moment it was constructed, which is exactly the distinction Chapter 3 drew between a resource and an ordinary record.

`status_from_last_event` is the one piece of domain logic this file adds beyond pass-through storage: it maps the most recent `HandlingEventType` to a `TransportStatus`, matching `received` to `planned`, `loaded`/`unloaded`/`customs` to `in-transit`, and `claimed` to `completed`, with no events at all defaulting to `TransportStatus::Unspecified`, the explicit zero value Chapter 5 described for exactly this situation: "no leg has reported a status yet" rather than a silent, wrong default.

The file's last line is the piece that makes everything above actually reachable from outside the component:

```rust
bindings::export!(Component with_types_in bindings);
```

`bindings::export!` is a macro the generated `bindings.rs` itself defines, and this is the one place `src/lib.rs` calls into the generated code rather than the other way around. It registers `Component` (the unit struct every `impl BookingGuest for Component` and `impl HandlingGuest for Component` block above targets) as the concrete type backing every exported function in the component's table. Without this line, the crate would compile as an ordinary Rust library implementing two traits nobody ever instantiates against; with it, `cargo-component`'s build step knows exactly which type's methods to wire into the `.wasm` binary's export table.

## Building the component

With the traits implemented, building is one command from the crate root:

```bash
cargo component build --release
```

The artifact lands at `target/wasm32-wasip1/release/cargo_rust.wasm`, not under `wasm32-wasip2/`, even though WASI Preview 2 is the API surface Chapter 4 described and the one this whole site targets. `cargo-component` 0.21 compiles the crate to a `wasm32-wasip1` core module as an internal build step, then adapts that core module into a real Preview 2 component using a bundled adapter, entirely inside the one `cargo component build` invocation. Nothing about the crate's source or its `Cargo.toml` names `wasip1` anywhere; it is purely where the toolchain's intermediate artifact happens to live before the adapt step turns it into the component this chapter builds everything else around. Knowing that path in advance saves a search the first time a build succeeds and the expected `wasm32-wasip2/` directory simply isn't there.

A built component is not self-describing at a glance; it is a binary. `wasm-tools`, the Bytecode Alliance's reference tool for inspecting components, is how you confirm the build did what `Cargo.toml`'s `target.world = "cargo"` asked for:

```bash
wasm-tools component wit target/wasm32-wasip1/release/cargo_rust.wasm
```

Run against a correctly built `cargo_rust.wasm`, this prints the same resolved WIT shape Chapter 3 showed for `contracts/wit` itself, with one difference that matters: it is derived from the compiled binary's own embedded component type, not read back from the source `.wit` files. Seeing `export patterncatalyst:cargo/types`, `export patterncatalyst:cargo/booking`, and `export patterncatalyst:cargo/handling` in that output is the build's own proof that `cargo component build` produced a component satisfying `world cargo`'s export list exactly, the same check a host or a composition step performs before trusting this artifact at all, just run here by hand instead of by a linker.

## Running it through the host

A component sitting on disk, confirmed to export the right world, still hasn't done anything yet: it has no `main`, nothing to call it. `host/src/main.rs` is a native Rust binary built independently of the component, using wasmtime's own code generation macro to get typed accessors for the world this component exports:

```rust
wasmtime::component::bindgen!({
    path: "../../../contracts/wit",
    world: "cargo",
});
```

That `bindgen!` call is the host's own binding-generation step, reading the identical WIT contract the component was built against, but generating wasmtime's *caller*-side types instead of `cargo-component`'s *implementer*-side traits, the same distinction Chapter 5 drew between `world cargo`'s exports and `world cargo-consumer`'s imports, expressed here as two different tools reading one file for two different purposes. The host loads the component, builds a `Linker` with WASI support, instantiates it, and gets back typed handles for each interface:

```rust
let cargo = Cargo::instantiate(&mut store, &component, &linker)
    .wc("instantiating cargo world")?;

let booking_api = cargo.patterncatalyst_cargo_booking();
let handling_api = cargo.patterncatalyst_cargo_handling();
```

From there, every call reads like an ordinary method call on a local object, even though each one crosses the component boundary into the `.wasm` binary's own linear memory and back:

```rust
let booking = booking_api
    .call_book_cargo(&mut store, &spec, fixture.input.weight_kg)
    .wc("call book-cargo")?
    .map_err(|e| anyhow::anyhow!("book-cargo returned error: {e:?}"))?;
```

Note the double unwrap: `.wc(...)?` handles a wasmtime-level failure (the call itself failing to execute: a trap, a resource limit, a host-side error), and the following `.map_err(...)` handles the WIT-level `Err` arm of the `result<booking, cargo-error>` this function can legitimately return as a successful call whose answer happens to be a validation failure. Those are two different failure modes at two different layers, and the host's error handling keeps them visibly separate rather than collapsing both into one generic error path, a distinction this chapter's component code enforces on the implementation side and the host's code enforces again on the calling side.

The `cargo-tracker` resource crosses the same boundary with its own calling convention: a constructor call, then method calls against the handle it returns, then an explicit drop:

```rust
let tracker_api = handling_api.cargo_tracker();
let tracker: ResourceAny = tracker_api
    .call_constructor(&mut store, &booking.cargo_id)
    .wc("call cargo-tracker constructor")?;
let t_id = tracker_api
    .call_tracking_id(&mut store, tracker)
    .wc("call tracking-id")?;
// ...
tracker
    .resource_drop(&mut store)
    .wc("drop cargo-tracker resource")?;
```

`ResourceAny` is wasmtime's handle type for any resource whose concrete shape the host doesn't need to know beyond its WIT type: the host never sees `Tracker`'s Rust fields, only an opaque handle it passes back into every subsequent `cargo-tracker` method call. `resource_drop` is not optional cleanup the host happens to remember to call; a resource's lifetime on the component side is tied to an explicit drop on the host side, and skipping it would leak the handle's slot in the component's resource table for the lifetime of the `Store`.

{% include excalidraw.html file="06-host-exercises-component" alt="host/src/main.rs using bindgen! against contracts/wit's cargo world, instantiating cargo_rust.wasm, and calling book-cargo, get-cargo, request-possible-routes, assign-route, register-handling-event three times, list-handling-events, and the cargo-tracker constructor plus its three methods and resource_drop, each call crossing into the matching Guest trait implementation on the component side." caption="Figure 6.2 — one host binary, one scenario, every call landing on the Guest trait implementations this chapter wrote." %}

Build and run both sides together from `examples/part2-building-components/`:

```bash
cd rust
cargo component build --release
wasm-tools component wit target/wasm32-wasip1/release/cargo_rust.wasm   # shows `export ...cargo/{types,booking,handling}`
cd ../host
cargo build --release
./target/release/cargo-host ../rust/target/wasm32-wasip1/release/cargo_rust.wasm ../fixtures/scenario.json rust
```

The host reads `fixtures/scenario.json` (book `USNYC → DEHAM` at 1200.5 kg, three handling events, one `cargo-tracker` query), asserts every result against the fixture's expected values with `assert_eq_ctx!`, and prints `[rust] all assertions passed` to stderr followed by a normalized JSON summary on stdout. `./verify.sh`, one level up, runs this exact sequence for both languages and diffs their two summaries, which is how Chapter 8 ultimately proves the Rust and Go components are interchangeable rather than merely similar: identical fixture, identical host, byte-identical output.

## Why cargo-component instead of hand-rolled bindgen

It would be possible, in principle, to call `wit-bindgen` directly and wire its output into a crate by hand, the way the Go side of this example does with `wit-bindgen-go` and a separate `wasm-tools component embed`/`component new` step (Chapter 7 covers that path in full). `cargo-component` exists specifically to remove that manual wiring on the Rust side: it folds WIT resolution, binding generation, the `wasm32-wasip1` compile, and the Preview 2 adapt step into one `cargo component build` invocation driven entirely by `Cargo.toml` metadata. The cost of that convenience is narrow but real: `cargo-component` is a Rust-specific tool with its own release cadence tracking the Component Model's evolving tooling, not a thin wrapper a project could trivially replace with stock `cargo build` if the project ever needed to. The benefit, visible across this entire chapter, is that nothing in `src/lib.rs` or `Cargo.toml` manually invokes `wit-bindgen`, manually embeds a WIT type section into a core module, or manually runs `wasm-tools component new`; one declarative `[package.metadata.component.target]` block and one build command produce a component wasmtime can load directly.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>This crate targets <code>contracts/wit/</code> via <code>[package.metadata.component.target]</code>'s relative <code>path</code> rather than vendoring a copy of the WIT files into <code>rust/wit/</code>. A vendored copy would need to stay byte-identical to the shared contract by developer discipline alone, and the two Rust and Go implementations would each own their own copy with no mechanism forcing them to agree; pointing both at the same three files on disk means <code>book-cargo</code>'s signature cannot drift between the two languages without <code>contracts/wit/</code> itself changing first, which is exactly the guarantee Chapter 3's composition claim depends on. The cost is a relative path threading three directories up from this crate's own root (<code>../../../contracts/wit</code>), which only resolves correctly from this crate's specific position in the repository tree. Move <code>rust/</code> without updating the path and the build fails loudly at resolution time rather than silently building against stale types. That failure mode is the better trade: a build-time path error is visible and immediate, where a silently vendored, drifted copy of three WIT files is not.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning) — the Component Model and Wasm toolchain mechanics this chapter's `cargo-component` build exercises directly.
- Shashank Jain, *WebAssembly for Cloud* (Apress) — component build pipelines and language-specific toolchain trade-offs, the same ground this chapter's "why cargo-component" section covers for Rust.
- [cargo-component](https://github.com/bytecodealliance/cargo-component) — the tool's own documentation for `[package.metadata.component]`'s full configuration surface beyond `target.path` and `target.world`.
- [Wasmtime's Rust embedding guide](https://docs.wasmtime.dev/examples-rust.html) — `wasmtime::component::bindgen!` and the `Linker`/`Store` machinery `host/src/main.rs` builds on.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/) — the canonical ABI lowering this chapter's `Result`-to-`result` mapping relies on without implementing by hand.

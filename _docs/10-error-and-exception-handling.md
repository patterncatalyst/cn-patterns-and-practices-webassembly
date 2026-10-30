---
title: "Error and Exception Handling"
order: 10
part: "Building Components in Rust & Go"
description: "How errors cross a component boundary through WIT result types, and how Rust and Go each map their native error handling onto that contract."
duration: "18 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the two distinct failure channels a call across the component boundary can produce: a **recoverable** domain error modeled by `result<_, cargo-error>`, and an **unrecoverable** trap produced by a Rust `panic!` or Go `panic()`.
- Explain, in wasmtime terms, why a recoverable error arrives as `Ok(Err(cargo-error::...))` (the call itself succeeded) while a trap arrives as `Err` on the call itself, with no domain value at all.
- Trace how Rust's `Result<T, CargoError>` and Go's `cm.Result[...]`/`cm.Err`/`cm.OK` each lower onto the identical WIT `result<_, cargo-error>` shape, and how the four-case `cargo-error` variant carries its string payloads across the boundary.
- State why a trap poisons the `Store`'s instance, and why `examples/part2-building-components/host/src/main.rs` runs its trap call last, after every other assertion.
- Decide, for a new function on this contract, whether a given failure belongs in `cargo-error` or should be allowed to panic/trap instead.

## Why this matters

A function call inside one process has exactly one way to fail that a caller must think about on every call: it can throw, panic, or return a sentinel the language itself defines, and the surrounding runtime decides what happens next: an unwound stack, a crashed thread, a process that keeps running. Crossing a WebAssembly component boundary removes that single channel and replaces it with two that behave nothing alike. `contracts/wit/types.wit` defines a `cargo-error` variant and every function in `bookings.wit` and `handling.wit` that can fail returns `result<_, cargo-error>` or `result<T, cargo-error>`: a value the host receives as an ordinary, successful call whose payload happens to be a `cargo-error::not-found`. But `examples/part2-building-components/rust/src/lib.rs`'s `get_cargo` and `examples/part2-building-components/go/main.go`'s `GetCargo` both also contain a documented `panic!`/`panic()` path, reachable with a specific sentinel tracking ID, and when the host calls into that path the function never returns a `cargo-error` at all; the wasmtime call that invoked it returns `Err`, and the component instance that was running is no longer usable for anything. The Component Model's WIT tagged union introduced `cargo-error` as the shape for recoverable failure; the Rust and Go provider implementations both return it. The fork those implementations built into their own code is the subject here: which of two completely different failure channels a given problem should use, and what each one costs the host that's driving the component.

{% include excalidraw.html file="10-two-failure-channels" alt="Two parallel columns. Left, RECOVERABLE: get-cargo(NO-SUCH-CARGO) -> component returns Err(CargoError::NotFound) or cm.Err(...) -> wasmtime CALL returns Ok(..) -> host sees Ok(Err(cargo-error::not-found)), a domain result not a call failure -> Store and instance remain alive -> host can call it again, or any other export, on this Store. Right, UNRECOVERABLE: get-cargo(__TRAP__) -> component code runs panic!(...) or panic(...) -> unwinds to a wasm TRAP -> wasmtime CALL ITSELF returns Err, no domain value at all, not Ok(Err(..)) -> Store's instance is POISONED -> no further exports may be called on this Store, it must be the LAST call. A caption notes host/src/main.rs runs the trap call last, against both providers, specifically because of the bottom-right box." caption="Figure 10.1: the same wasmtime host observes two structurally different kinds of failure from the identical function, get-cargo, depending on which tracking ID it passes." %}

## Two channels, not one: result versus trap

The contract draws this line explicitly, in WIT's own terms, before either language's implementation adds anything to it. `contracts/wit/types.wit` declares:

```wit
/// Errors returned by the booking and handling interfaces.
variant cargo-error {
    not-found(string),
    invalid-booking(string),
    invalid-location(string),
    conflict(string),
}
```

and `bookings.wit` declares every booking function against that variant:

```wit
/// Look up a cargo by its tracking ID.
get-cargo: func(tracking-id: string) -> result<cargo, cargo-error>;
```

`result<cargo, cargo-error>` is a value the WIT type system knows about: a binding generator on either side of the boundary has to account for both the success case and the `cargo-error` case, because the function's return type says so. A caller cannot forget to check: there is no bare `cargo` returned on failure, no null, no out-of-band flag. This is what "recoverable" means in this chapter: the failure is data, flowing through the same channel a successful call uses, observable by ordinary pattern matching on either side.

A trap is not data. Nothing in `bookings.wit` or `handling.wit` declares a trap as part of any function's return type, because a trap is not a value the WIT type system describes at all: it is the component model's name for what happens when execution inside a component cannot continue and the wasm runtime has to abandon it. `get-cargo`'s signature promises `result<cargo, cargo-error>` on every call, and that promise still holds for the recoverable path; a trap is the one way a component can fail to honor it, by not returning at all. From the host's point of view the distinction shows up exactly where a Rust program would normally distinguish `Result::Err` from a panicking thread: a `result<_, cargo-error>` surfaces as `Ok(Err(cargo-error::...))` from the generated binding (the call returned, successfully, carrying a domain error), while a trap surfaces as `Err` from the call itself, carrying a wasmtime-level error with no `cargo-error` inside it, because none was ever constructed.

## Rust: Result<T, CargoError> and panic! in the same function

`examples/part2-building-components/rust/src/lib.rs`'s `get_cargo` implements both channels in one function, and the comment above the sentinel constant states the intent directly:

```rust
// Documented sentinel tracking id that makes `get-cargo` PANIC, so the host (and
// the debugging/error chapter) can show a genuine wasm TRAP — the whole instance
// is torn down — as distinct from a recoverable domain `cargo-error`. Kept in
// LOCKSTEP with the Go provider (go/main.go `trapSentinel`) and deliberately NOT
// used by the main scenario, so the byte-identical cross-language summary is
// unaffected.
const TRAP_SENTINEL: &str = "__TRAP__";
```

and the function itself:

```rust
fn get_cargo(tracking_id: String) -> Result<Cargo, CargoError> {
    if tracking_id == TRAP_SENTINEL {
        // A panic unwinds to a wasm trap at the component boundary — the host
        // observes an `Err` from the CALL itself, not an `Ok(Err(..))` domain
        // result. This is the "unrecoverable" side of the error taxonomy.
        panic!("__TRAP__ sentinel: deliberate trap for the debugging/error chapter");
    }
    STATE.with(|s| {
        s.borrow()
            .cargos
            .get(&tracking_id)
            .cloned()
            .ok_or_else(|| CargoError::NotFound(format!("no cargo {tracking_id}")))
    })
}
```

Two things to notice. First, the function's declared return type is `Result<Cargo, CargoError>` (ordinary Rust, matching the WIT signature one for one), and the recoverable path uses it exactly the way idiomatic Rust uses `Result` everywhere else: `.ok_or_else()` turns a missing `HashMap` entry into `Err(CargoError::NotFound(..))`, no different from how this function would behave if it had nothing to do with WebAssembly at all. Second, the `panic!` call sits above that return type entirely: it never constructs a `CargoError`, never returns anything, and Rust's own panic machinery takes over instead of the function's normal control flow. `cargo-component`'s generated bindings handle the first case by lowering `Result<Cargo, CargoError>` into the WIT `result<cargo, cargo-error>` the host expects; they have no lowering to perform for the second case, because a panic never reaches the point where lowering would happen. It unwinds past the generated binding code and becomes a wasm trap at the component boundary: the host-visible event the two channels differ on.

This same pattern (a declared `Result` return type for the domain logic, with a documented `panic!` reachable through a sentinel value the main scenario never hits) appears across the rest of `rust/src/lib.rs`'s booking and handling functions, every one of which returns `Result<_, CargoError>` and uses `ok_or_else` or an explicit `return Err(...)` for its validation failures:

```rust
fn assign_route(booking_id: String, itinerary: Itinerary) -> Result<Booking, CargoError> {
    if itinerary.legs.is_empty() {
        return Err(CargoError::InvalidBooking(
            "itinerary must have at least one leg".to_string(),
        ));
    }
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        let booking = s
            .bookings
            .get_mut(&booking_id)
            .ok_or_else(|| CargoError::NotFound(format!("no booking {booking_id}")))?;
        booking.status = RoutingStatus::Routed;
        Ok(booking.clone())
    })
}
```

`book_cargo` follows the identical shape for its two validation checks:

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
    // ... construct and store the booking ...
```

Every one of these is an ordinary, expected-to-happen failure: a caller passed an empty UN/LOCODE, a non-positive weight, an unknown booking ID, and every one of them flows through `CargoError`, never through `panic!`. `__TRAP__` is the only path in this entire file that reaches for the other channel, and the comment makes clear that is deliberate rather than an oversight: this file has exactly one documented trap, for exactly one purpose.

## Go: cm.Err/cm.OK and panic() doing the same job

`examples/part2-building-components/go/main.go` implements the identical two functions, the identical validation rules, and the identical sentinel, in Go's idiom rather than Rust's. Where Rust has a `Result<T, E>` built into the language, Go's generated bindings (from `wit-bindgen-go`) represent a WIT `result<T, E>` as a `cm.Result[Shape, T, E]` value, constructed with the generated `cm.OK[...]` and `cm.Err[...]` helpers:

```go
type cargoResult = cm.Result[booking.CargoShape, types.Cargo, types.CargoError]
```

```go
// trapSentinel is a documented tracking id that makes GetCargo PANIC, so the
// host (and the debugging/error chapter) can show a genuine wasm TRAP — the
// whole instance is torn down — as distinct from a recoverable domain
// cargo-error. Kept in LOCKSTEP with the Rust provider (rust/src/lib.rs
// TRAP_SENTINEL) and deliberately NOT used by the main scenario, so the
// byte-identical cross-language summary is unaffected.
const trapSentinel = "__TRAP__"
```

```go
booking.Exports.GetCargo = func(trackingID string) cargoResult {
    if trackingID == trapSentinel {
        // A panic unwinds to a wasm trap at the component boundary — the host
        // observes an error from the CALL itself, not an Ok(Err(..)) domain
        // result. This is the "unrecoverable" side of the error taxonomy.
        panic("__TRAP__ sentinel: deliberate trap for the debugging/error chapter")
    }
    c, ok := cargos[trackingID]
    if !ok {
        return cm.Err[cargoResult](types.CargoErrorNotFound("no cargo " + trackingID))
    }
    return cm.OK[cargoResult](c)
}
```

Structurally this is the same fork as the Rust version, expressed with Go's tools instead of Rust's: `cm.OK[cargoResult](c)` and `cm.Err[cargoResult](types.CargoErrorNotFound(...))` are both ordinary return statements producing a `cargoResult` value, exercising the normal Go call/return mechanism all the way out through the generated export wiring. `panic("__TRAP__ sentinel: ...")` does not produce a `cargoResult` at all; like the Rust `panic!`, it unwinds past the point where the function would have returned one, and TinyGo's wasm output turns that unwind into the same kind of wasm trap the Rust build produces. The comments in both files are worded almost identically, matching each other line for line; the two implementations are meant to be read side by side.

The same `cm.Err`/`cm.OK` pattern covers every validation rule in `book_cargo`'s Go sibling:

```go
booking.Exports.BookCargo = func(spec types.RouteSpec, weightKg float64) bookingResult {
    if spec.Origin.Unlocode == "" || spec.Destination.Unlocode == "" {
        return cm.Err[bookingResult](types.CargoErrorInvalidLocation(
            "origin and destination must each have a UN/LOCODE"))
    }
    if weightKg <= 0 {
        return cm.Err[bookingResult](types.CargoErrorInvalidBooking(
            "weight-kg must be greater than zero"))
    }
    // ... construct and store the booking ...
    return cm.OK[bookingResult](b)
}
```

and `assign_route`'s:

```go
booking.Exports.AssignRoute = func(bookingID string, itinerary types.Itinerary) bookingResult {
    if itinerary.Legs.Len() == 0 {
        return cm.Err[bookingResult](types.CargoErrorInvalidBooking(
            "itinerary must have at least one leg"))
    }
    b, ok := bookings[bookingID]
    if !ok {
        return cm.Err[bookingResult](types.CargoErrorNotFound("no booking " + bookingID))
    }
    b.Status = types.RoutingStatusRouted
    bookings[bookingID] = b
    return cm.OK[bookingResult](b)
}
```

Go's `types.CargoErrorNotFound(...)`, `types.CargoErrorInvalidBooking(...)`, `types.CargoErrorInvalidLocation(...)` constructors are the generated bindings' representation of the same four-case `cargo-error` variant Rust represents as `CargoError::NotFound(...)`, `CargoError::InvalidBooking(...)`, `CargoError::InvalidLocation(...)`. Neither implementation invented its own error vocabulary: both read `not-found`, `invalid-booking`, `invalid-location`, and `conflict` out of the identical `contracts/wit/types.wit` `variant cargo-error` block, and each language's binding generator produced the matching constructor names for its own idiom.

{% include excalidraw.html file="10-error-mapping" alt="Three columns. Left, rust/src/lib.rs: Result<Booking, CargoError> with Err(CargoError::NotFound(..)), and separately panic!(__TRAP__ sentinel...) in get_cargo. Middle, contracts/wit/types.wit: variant cargo-error with four cases not-found/invalid-booking/invalid-location/conflict each carrying a string, and result<booking, cargo-error>, with a note that there is no WIT shape for a trap -- it bypasses the result entirely. Right, go/main.go: cm.Result[..., Booking, CargoError] with cm.Err(types.CargoErrorNotFound(..)), and separately panic(__TRAP__ sentinel...) in GetCargo. Arrows show Result and cm.Result both lowering to and lifting from the central result<booking, cargo-error> via bindgen, while the panic boxes on both sides connect to the WIT box with arrows labeled 'no lowering -- unwinds to a trap'. A caption states the wasmtime host observes both result paths as Ok(Err(cargo-error::...)), and both panic paths as the same trap, regardless of which language produced it." caption="Figure 10.2: Rust's Result/panic! and Go's cm.Result/panic() both map onto the same WIT result&lt;_, cargo-error&gt;, except for the trap path, which has no WIT representation at all." %}

## What the host sees: wasmtime 50's two return shapes

`examples/part2-building-components/host/src/main.rs` is the one place in this example where both languages' output is observed through the same code, so it is the clearest place to see the distinction a reader has to program against. The host generates its bindings with wasmtime's `bindgen!` macro against the same `contracts/wit`:

```rust
wasmtime::component::bindgen!({
    path: "../../../contracts/wit",
    world: "cargo",
});
```

and every generated call method, such as `call_get_cargo`, returns a `wasmtime::Result<Result<Cargo, CargoError>>`: an outer `Result` for "did the call itself succeed" and an inner `Result` for "what did the WIT `result<cargo, cargo-error>` contain." The host's own `WasmCtx` extension exists specifically because wasmtime 50 changed that outer type from `anyhow::Error` to its own `wasmtime::Error`:

```rust
// wasmtime 50 returns its own `wasmtime::Error` (no longer `anyhow::Error`), so
// anyhow's `.context()` does not apply to its results. This extension bridges a
// `wasmtime::Result<T>` into an `anyhow::Result<T>` with a context message.
trait WasmCtx<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T>;
}
impl<T> WasmCtx<T> for wasmtime::Result<T> {
    fn wc(self, ctx: impl std::fmt::Display) -> Result<T> {
        self.map_err(|e| anyhow::anyhow!("{ctx}: {e}"))
    }
}
```

The normal, main-scenario calls chain `.wc(...)` on the outer `Result` and then pattern-match the inner one, because for these calls the outer `Result` is never expected to be an `Err` at all; a trap on `book_cargo` or `assign_route` during the happy-path scenario would be a bug, not a modeled outcome:

```rust
let booking = booking_api
    .call_book_cargo(&mut store, &spec, fixture.input.weight_kg)
    .wc("call book-cargo")?
    .map_err(|e| anyhow::anyhow!("book-cargo returned error: {e:?}"))?;
```

The error-taxonomy section at the end of `main()` is where the host stops assuming the outer `Result` is always `Ok` and tests both shapes directly. First, the recoverable case: `get-cargo` with an unknown tracking ID, asserted to come back as `Ok` on the outer call with `Err(CargoError::NotFound(..))` as the inner value:

```rust
// Recoverable: get-cargo on an unknown id returns Ok(Err(not-found)) — the
// CALL succeeds, the domain result is an error. No trap.
let missing = booking_api
    .call_get_cargo(&mut store, "NO-SUCH-CARGO")
    .wc("call get-cargo (unknown id)")?;
match missing {
    Ok(c) => bail!(
        "ASSERT FAIL [recoverable]: expected cargo-error::not-found for an unknown id, got Ok({:?})",
        c.tracking_id
    ),
    Err(CargoError::NotFound(msg)) => {
        eprintln!("[{label}] recoverable: get-cargo(\"NO-SUCH-CARGO\") -> Ok(Err(cargo-error::not-found: {msg:?})) — domain error, instance still alive");
    }
    Err(other) => bail!(
        "ASSERT FAIL [recoverable]: expected cargo-error::not-found, got {other:?}"
    ),
}
```

Notice the `?` is gone after `.wc(...)` here: the host needs to keep the outer `Result` around and match on it (`missing`), because the whole point of this block is to confirm the outer call succeeded and only the inner value is an error. Then, the unrecoverable case, with the sentinel tracking ID, where the host does the opposite: it matches the *outer* result directly, with no inner `Result` to unwrap at all, because a trap never produces one:

```rust
// Unrecoverable: the sentinel id makes get-cargo panic inside the component,
// which surfaces as an Err from the wasmtime CALL itself (a trap) — NOT an
// Ok(Err(..)) domain result. Distinguishing these is the whole point.
let trapped = booking_api.call_get_cargo(&mut store, TRAP_SENTINEL);
match trapped {
    Err(e) => {
        eprintln!("[{label}] trap: get-cargo(\"{TRAP_SENTINEL}\") -> wasmtime call returned Err (a trap): {e}");
    }
    Ok(domain) => bail!(
        "ASSERT FAIL [trap]: expected a wasm trap for the sentinel id, but the call returned a value: {domain:?}"
    ),
}
```

`trapped` here has type `wasmtime::Result<Result<Cargo, CargoError>>`, exactly like `missing` did, but the assertion never looks inside the `Ok` arm's `Result<Cargo, CargoError>`, because for a trap that inner value is never constructed. `Err(e)` is the only arm that should ever fire; `Ok(domain)` firing instead would mean the sentinel somehow didn't trigger the panic, which the host treats as a test failure in its own right. This is the concrete, type-level version of the distinction between the two channels: one failure mode lives in the `Ok` arm's payload, the other lives in which arm fired at all.

## Why the trap call runs last: store poisoning

The two calls above are not interchangeable in the order they can run, and `host/src/main.rs`'s own comment states the reason directly: "The trap call is LAST because a trap poisons the component instance in this Store." A `wasmtime::Store<T>` owns the linear memory and the instance state for every component instantiated against it; a trap does not merely fail the one call that triggered it, it leaves that instance in a state wasmtime will not allow further calls into, because the component's internal state at the moment of the panic cannot be trusted to still satisfy whatever invariants its own code depends on. Rust's `panic!` unwinding through `get_cargo`, or Go's `panic()` unwinding through `GetCargo`, both leave behind a Wasm instance that stopped mid-execution rather than returning normally: there is no guarantee the `RefCell`-guarded `STATE` in the Rust provider, or the package-level maps in the Go provider, are in a sound state to keep reading from.

This is why the host's `main()` runs the recoverable `missing` check before the unrecoverable `trapped` check, and why every other assertion in the function (`book-cargo`, `get-cargo` on the real tracking ID, `request-possible-routes`, `assign-route`, the handling-event registrations, the `cargo-tracker` resource's constructor and its three methods and its `resource_drop`) all run before either error-taxonomy check. Reordering the trap call earlier would poison the Store before any of those assertions ran, and every call after it would fail for the wrong reason: not because the booking or handling logic is broken, but because the instance underneath it is gone. A reader extending this example with a new function that might also panic should keep the same discipline: exercise everything that needs the instance alive first, save any trap for strictly last, and if more than one trap path needs testing in one run, give each its own freshly instantiated component rather than sharing a `Store`.

## Deciding where a given failure belongs

The contract's own shape of `cargo-error` is itself a decision about this question, worth reading as the house answer rather than an arbitrary list. Four cases (`not-found`, `invalid-booking`, `invalid-location`, `conflict`) cover every failure a caller of this domain should reasonably expect to happen and be positioned to handle: an unknown ID, a malformed request, a bad location, a state conflict. None of these represent a bug in the provider; they represent an input or a state the domain model anticipates. `panic!`/`panic()` is reserved for exactly the opposite kind of event: the `__TRAP__` sentinel exists purely to demonstrate the mechanism, and the comment above it in both `rust/src/lib.rs` and `go/main.go` says so: the main scenario never reaches it. In a real provider, a panic should mean the same thing it means anywhere else in Rust or Go: an invariant the code assumed would hold did not, a precondition the function's own logic depends on was violated by code elsewhere in the same component, something a caller cannot be expected to recover from because the component's internal correctness is now in question.

The practical rule follows directly: if a new case belongs in a WIT `result<_, cargo-error>` or a new variant case, a caller somewhere should be expected to branch on it and continue running: retry with a corrected input, look up a different ID, surface a validation message to a user. If a failure would instead mean "this component's own code reached a state its author believed was unreachable," that is what a panic or trap is for, and it should stay rare and loud rather than get smuggled into the error variant as a vague `conflict` case nobody can act on. Mixing the two (returning `cargo-error::not-found` for a bug, or panicking on a routine missing lookup) breaks the taxonomy in different directions: the first hides a real defect behind a value that looks like normal domain behavior, while the second turns an ordinary "caller looked something up that isn't there" into a Store-poisoning event that tears down far more than the one failed call warranted.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>A call across this component boundary fails through exactly one of two channels, and the WIT contract keeps them structurally distinct: a <strong>recoverable</strong> failure is a <code>result&lt;_, cargo-error&gt;</code> value: the wasmtime call succeeds and returns <code>Ok</code>, with the failure living inside that <code>Ok</code> as <code>Err(cargo-error::not-found | invalid-booking | invalid-location | conflict)</code>, while an <strong>unrecoverable</strong> failure is a Rust <code>panic!</code> or Go <code>panic()</code> that unwinds to a wasm trap, which the host observes as <code>Err</code> on the wasmtime call itself, with no domain value constructed at all. Use <code>cargo-error</code> for anything a caller should reasonably expect and be positioned to handle: an unknown ID, a bad input, a conflicting state, and reserve a panic for a bug the component cannot recover from: an invariant the component's own code assumed would hold and did not. A trap poisons the <code>Store</code>'s instance; no further export calls are valid against it afterward. <code>examples/part2-building-components/host/src/main.rs</code> enforces this operationally by running its <code>__TRAP__</code> sentinel call strictly last, after every other assertion against that Store has already passed, so a reader extending this example with a new failure path should follow the identical order: exercise everything else first, trap last, one <code>Store</code> per trap if more than one needs testing.</p></div>

## For deeper coverage

- *Designing Data-Intensive Applications*, Martin Kleppmann (O'Reilly, 2017): Chapter 8's treatment of partial failure and the difference between an error a system can reason about and one that leaves state undefined, the same distinction drawn here at the component boundary.
- *Cloud Native Design Patterns*, "API Error Handling" chapter: error taxonomies and when a machine-readable error payload belongs on the wire, the same design question `cargo-error`'s four cases answer for this contract.
- *Cloud Native Design Patterns*, "Failure Modes" chapter: the broader catalog of failure types, including the "the whole unit of execution must be abandoned" case a wasm trap represents here.
- [WebAssembly Component Model design documents](https://component-model.bytecodealliance.org/): the `result` type and the semantics of a trap at the component boundary this chapter builds on.
- [wasmtime API documentation, `wasmtime::Error` and `Store`](https://docs.rs/wasmtime/latest/wasmtime/): the outer/inner `Result` shape `host/src/main.rs`'s generated bindings return, and the `Store` lifecycle a trap terminates.
- `contracts/wit/types.wit`: the `cargo-error` variant and `result<_, cargo-error>` signatures that define the shared contract's recoverable-failure shape.
- `examples/part2-building-components/rust/src/lib.rs` and `go/main.go`: the full provider implementations this chapter's code excerpts are drawn from.
- Runtime backtraces and `wasm-tools` static inspection: the tooling for inspecting a component when a trap or an unexpected `cargo-error` shows up and the cause isn't obvious from the host's own output.

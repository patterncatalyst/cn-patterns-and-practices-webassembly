---
title: "Error and Exception Handling"
order: 10
part: "Building Components in Rust & Go"
description: "A recoverable failure is a WIT result value and an unrecoverable one is a trap; how Rust and Go map their error handling onto each, and which one to use."
duration: "18 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the two failure channels across a component boundary: a recoverable domain error in `result<_, cargo-error>`, and an unrecoverable trap from a Rust `panic!` or Go `panic()`.
- Explain why a recoverable error reaches the host as `Ok(Err(cargo-error::...))` while a trap is an `Err` on the call itself with no domain value.
- Trace how Rust's `Result<T, CargoError>` and Go's `cm.Result`, `cm.Err` and `cm.OK` lower onto the same WIT `result` and the four-case `cargo-error` variant.
- Say why a trap poisons the instance in its `Store`, and why the host runs its trap call last.
- Decide whether a failure on a new function belongs in `cargo-error` or should trap.

## Why this matters

Inside one process a failure is a thrown exception, a panic or a sentinel, and the runtime decides what survives. Across a component boundary there are two channels that behave nothing alike. Every fallible function in the contract returns `result<_, cargo-error>`: the host receives an ordinary successful call whose payload is a `cargo-error::not-found`. Both providers also contain a `panic` path, reachable with one sentinel tracking ID. When the host calls into it, the function never returns a `cargo-error`, the wasmtime call returns `Err`, and the component instance is no longer usable.

Choosing the channel decides what a failure costs the host.

{% include excalidraw.html file="10-two-failure-channels" alt="Two parallel columns. Left, RECOVERABLE: get-cargo(NO-SUCH-CARGO) -> component returns Err(CargoError::NotFound) or cm.Err(...) -> wasmtime CALL returns Ok(..) -> host sees Ok(Err(cargo-error::not-found)), a domain result not a call failure -> Store and instance remain alive -> host can call it again, or any other export, on this Store. Right, UNRECOVERABLE: get-cargo(__TRAP__) -> component code runs panic!(...) or panic(...) -> unwinds to a wasm TRAP -> wasmtime CALL ITSELF returns Err, no domain value at all, not Ok(Err(..)) -> Store's instance is POISONED -> no further exports may be called on this Store, it must be the LAST call. A caption notes host/src/main.rs runs the trap call last, against both providers, specifically because of the bottom-right box." caption="Figure 10.1: The same host sees two structurally different failures from get-cargo, depending on the tracking ID it passes." %}

## Two channels: result and trap

The contract draws the line in WIT before either language adds anything:

```wit
    /// Errors returned by the booking and handling interfaces.
    variant cargo-error {
        not-found(string),
        invalid-booking(string),
        invalid-location(string),
        conflict(string),
    }
```

Every booking function returns that variant in a `result`:

```wit
    /// Look up a cargo by its tracking ID.
    get-cargo: func(tracking-id: string) -> result<cargo, cargo-error>;
```

A `result` is a value the type system knows. A binding generator on either side must handle both the success and the `cargo-error` case, because the signature says so. A caller can't forget to check: there is no bare `cargo` on failure, no null, no out-of-band flag. That is what recoverable means here: the failure is data, flowing through the channel a success uses.

A trap isn't data. No WIT signature declares one, because a trap is what happens when execution inside a component can't continue and the runtime abandons it. It's the one way a component fails to honor `result<cargo, cargo-error>`: by not returning at all. The host sees the difference in the shape of the return value:

| Failure | Host sees |
| --- | --- |
| `result<_, cargo-error>` error | `Ok(Err(cargo-error::...))`: the call succeeded and carries a domain error |
| `panic!` or `panic()` | `Err` from the call itself, with a wasmtime-level error and no `cargo-error` inside |

## Rust: Result and panic! in one function

The Rust provider's `get_cargo` uses both channels. The sentinel `TRAP_SENTINEL` (`"__TRAP__"`) is documented, kept in step with the Go provider, and never used by the main scenario:

```rust
    fn get_cargo(tracking_id: String) -> Result<Cargo, CargoError> {
        if tracking_id == TRAP_SENTINEL {
            // A panic unwinds to a wasm trap at the component boundary. The host
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

The recoverable path is idiomatic Rust: `ok_or_else` turns a missing map entry into `Err(CargoError::NotFound(..))`, and `cargo-component`'s bindings lower the `Result` into the WIT `result`. The `panic!` never constructs a `CargoError`. It unwinds past the generated binding code and becomes a wasm trap at the boundary.

Every other function returns `Result<_, CargoError>` and fails through it. `book_cargo` rejects an empty UN/LOCODE with `InvalidLocation` and a non-positive weight with `InvalidBooking`:

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
```

`assign_route` rejects an itinerary with no legs and an unknown booking the same way, with `return Err(...)` for the first check and `ok_or_else(...)?` for the second:

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

Each of these is an expected failure: an empty UN/LOCODE, a non-positive weight, an unknown booking ID. Each flows through `CargoError`, never through `panic!`. `__TRAP__` is the only path in the file that reaches for the other channel.

## Go: cm.Err, cm.OK and panic()

`wit-bindgen-go` represents a WIT `result<T, E>` as a `cm.Result` value, built with `cm.OK` and `cm.Err`:

```go
type cargoResult = cm.Result[booking.CargoShape, types.Cargo, types.CargoError]
```

The Go provider implements the same function, the same validation rules and the same sentinel:

```go
	booking.Exports.GetCargo = func(trackingID string) cargoResult {
		if trackingID == trapSentinel {
			// A panic unwinds to a wasm trap at the component boundary. The host
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

The same `cm.Err` and `cm.OK` pair carries every validation rule. `BookCargo` checks the UN/LOCODEs and the weight first:

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
```

`AssignRoute` rejects an empty itinerary and an unknown booking:

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

`cm.OK` and `cm.Err` are ordinary returns that produce a `cargoResult`. `panic` produces none: it unwinds past the return, and TinyGo turns the unwind into the same kind of wasm trap. `types.CargoErrorNotFound`, `CargoErrorInvalidBooking` and `CargoErrorInvalidLocation` are the generated constructors for the same four-case variant. Neither language invented an error vocabulary; both read `not-found`, `invalid-booking`, `invalid-location` and `conflict` from `contracts/wit/types.wit`.

{% include excalidraw.html file="10-error-mapping" alt="Three columns. Left, rust/src/lib.rs: Result<Booking, CargoError> with Err(CargoError::NotFound(..)), and separately panic!(__TRAP__ sentinel...) in get_cargo. Middle, contracts/wit/types.wit: variant cargo-error with four cases not-found/invalid-booking/invalid-location/conflict each carrying a string, and result<booking, cargo-error>, with a note that there is no WIT shape for a trap: it bypasses the result entirely. Right, go/main.go: cm.Result[..., Booking, CargoError] with cm.Err(types.CargoErrorNotFound(..)), and separately panic(__TRAP__ sentinel...) in GetCargo. Arrows show Result and cm.Result both lowering to and lifting from the central result<booking, cargo-error> via bindgen, while the panic boxes on both sides connect to the WIT box with arrows labeled 'no lowering: unwinds to a trap'. A caption states the wasmtime host observes both result paths as Ok(Err(cargo-error::...)), and both panic paths as the same trap, regardless of which language produced it." caption="Figure 10.2: Rust Result and Go cm.Result map onto the same WIT result type; the panic path has no WIT representation." %}

## What the host sees

The native host generates its bindings against the same contract:

```rust
wasmtime::component::bindgen!({
    path: "../../../contracts/wit",
    world: "cargo",
});
```

Every generated method such as `call_get_cargo` returns a `wasmtime::Result<Result<Cargo, CargoError>>`. The outer `Result` answers whether the call succeeded. The inner one holds what the WIT `result` contained. wasmtime 50 changed the outer error type from `anyhow::Error` to its own `wasmtime::Error`, so anyhow's `.context()` no longer applies and the host bridges it with a small extension trait:

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

On the happy path the outer `Result` is never expected to fail: a trap in `book_cargo` or `assign_route` during the main scenario is a bug, not a modeled outcome. Those calls chain `.wc(...)?` on the outer result and then turn the inner error into an anyhow error:

```rust
    let booking = booking_api
        .call_book_cargo(&mut store, &spec, fixture.input.weight_kg)
        .wc("call book-cargo")?
        .map_err(|e| anyhow::anyhow!("book-cargo returned error: {e:?}"))?;
```

The error checks at the end of `main` test both shapes. The recoverable case drops the `?` after `.wc(...)`, keeps the result and matches the inner value; the unrecoverable case matches the outer result directly, with no inner value to unwrap:

```rust
    // Recoverable: get-cargo on an unknown id returns Ok(Err(not-found)). The
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
            eprintln!("[{label}] recoverable: get-cargo(\"NO-SUCH-CARGO\") -> Ok(Err(cargo-error::not-found: {msg:?})), domain error, instance still alive");
        }
        Err(other) => bail!(
            "ASSERT FAIL [recoverable]: expected cargo-error::not-found, got {other:?}"
        ),
    }
```

```rust
    // Unrecoverable: the sentinel id makes get-cargo panic inside the component,
    // which surfaces as an Err from the wasmtime CALL itself (a trap), NOT an
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

The `Err(e)` arm is the only one that should fire for the sentinel. If `Ok(domain)` fires, the panic didn't happen. One failure mode lives in the payload of `Ok`; the other lives in which arm fired at all.

## Why the trap call runs last

A trap doesn't only fail the call that triggered it. It leaves the instance stopped mid-execution, and wasmtime won't allow further calls into it, because the component's internal state at the moment of the panic can't be trusted. The `RefCell`-guarded state in the Rust provider and the package-level maps in the Go provider may be half-updated.

So the host runs every other call first (booking, lookup, routing, handling events, the `cargo-tracker` resource and its drop), then the recoverable check, then the trap. Moving the trap earlier makes every later call fail for the wrong reason: the instance underneath is gone, not the booking logic. To test more than one trap path in a run, give each a freshly instantiated component instead of sharing a `Store`.

## Where a failure belongs

The four cases of `cargo-error` cover what a caller of this domain should expect and can handle: an unknown ID, a malformed request, a bad location, a state conflict. None is a bug in the provider. A panic means what it means in any Rust or Go program: an invariant the code assumed has failed, and the component's internal correctness is in question. The sentinel exists only to demonstrate the mechanism.

If a caller can retry with a corrected input, look up a different ID or show a validation message, the failure is a `cargo-error` case. If it means this component reached a state its author believed unreachable, it traps, and it should stay rare and loud. Mixing them breaks the taxonomy in both directions:

| Mistake | Effect |
| --- | --- |
| `cargo-error::not-found` returned for a bug | Hides a defect behind a value that looks like normal domain behavior |
| Panic on a routine missing lookup | Turns an ordinary miss into a `Store`-poisoning event that tears down far more than one call |

> **Decision**
>
> A recoverable failure is a `result<_, cargo-error>` value: the call returns `Ok` and the failure is inside it. Use it for anything a caller should expect and can handle: an unknown ID, bad input, a conflicting state. An unrecoverable failure is a Rust `panic!` or Go `panic()` that unwinds to a trap, seen as `Err` on the wasmtime call. Reserve it for a broken invariant. A trap poisons the instance, so exercise everything else first, trap last, and use one `Store` per trap path.

> **🤖 Explore with your agent**
>
> "In examples/part2-building-components, add a new `get-handling-summary` function to the booking interface in contracts/wit/bookings.wit that fails for an unknown tracking ID. Implement it in rust/src/lib.rs and go/main.go so the unknown ID returns `cargo-error::not-found` and a corrupt internal state panics, then extend host/src/main.rs to assert the two shapes (`Ok(Err(..))` versus `Err` on the call) and keep the trap call last."
>
> Check: `./verify.sh` still passes, and the host's recoverable line prints before the trap line for both providers.

## Build, run, observe

```bash
cd examples/part2-building-components && ./verify.sh
```

The script builds both providers and the host, runs the host against each, and ends with `PASS` when the Rust and Go components produce the same results and the same two error shapes. The host prints the recoverable and trap lines to stderr, prefixed `[rust]` or `[go]`.

- Pass an unknown ID such as `NO-SUCH-CARGO` to `get-cargo`: the host prints `Ok(Err(cargo-error::not-found: ...))` and the instance stays alive.
- Pass `__TRAP__`: the host prints the call's `Err` with a wasm backtrace, and no further export call works on that `Store`.
- Move the trap call before the other assertions in `host/src/main.rs`: every call after it fails because the instance is poisoned.

## For deeper coverage

- *Designing Data-Intensive Applications*, Martin Kleppmann (O'Reilly, 2017): the treatment of partial failure and the difference between an error a system can reason about and one that leaves state undefined.
- *Cloud Native Design Patterns*, "API Error Handling" chapter: error taxonomies and when a machine-readable error payload belongs on the wire.
- *Cloud Native Design Patterns*, "Failure Modes" chapter: the case where the whole unit of execution must be abandoned, which a wasm trap represents here.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): the `result` type and the semantics of a trap at the component boundary.
- [wasmtime API documentation](https://docs.rs/wasmtime/latest/wasmtime/): `wasmtime::Error` and the `Store` lifecycle a trap terminates.
- `contracts/wit/types.wit`: the `cargo-error` variant and `result<_, cargo-error>` signatures of the shared contract.
- `examples/part2-building-components/rust/src/lib.rs` and `go/main.go`: the provider implementations the excerpts come from.

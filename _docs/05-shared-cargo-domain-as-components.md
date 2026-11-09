---
title: "The Shared Cargo Domain as Components"
order: 5
part: "Foundations"
description: "The shipping and cargo domain every later chapter builds on, modeled as three WIT interfaces and two worlds that the Rust and Go implementations share."
duration: "22 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the three interfaces in package `patterncatalyst:cargo@0.1.0` (`types`, `booking`, `handling`) and say which one owns data and which two own behavior.
- Explain why `money.amount` is a `string` rather than `f32` or `f64`, and why `location` identifies a place by UN/LOCODE.
- Trace a `book-cargo` call: the `route-spec` it accepts, the `booking` it returns, and how `cargo-error` reports a failure without a trap.
- Distinguish `world cargo` from `world cargo-consumer`, and say which one an implementation targets and which one a caller targets.
- Explain why `cargo-tracker` is a WIT `resource` rather than stateless functions.

## Why this matters

Every hands-on chapter targets one package, `patterncatalyst:cargo@0.1.0`. A WIT world names the interfaces a component imports and exports, and an interface with two made-up functions would show that as well as a real one. A real domain shows the decisions: where data ends and behavior begins, how errors cross the boundary, and what a second language has to match.

The domain is the shipping story the REST, gRPC, GraphQL and WebSockets books in this series tell: a shipper books cargo between two ports, a carrier plans an itinerary of legs, and handling events record what happens to the cargo. Here it is not a wire format. A WIT interface has no verb, status code or envelope, because calls between components are in-process typed function calls that the canonical ABI lowers into and lifts out of linear memory. What crosses the boundary is a `route-spec` record or a `result<booking, cargo-error>`, checked by the compiler at build time.

One noun from the gRPC book has no analog: `Operation`, the long-running-job handle. `request-possible-routes` returns its `list<itinerary>` directly, because a component call is a function call in a shared address space and there is no round trip to amortize. Work that spans a real external system would use a WASI async primitive or a resource with poll-style methods.

{% include excalidraw.html file="05-cargo-domain" alt="Domain model diagram showing route-spec and cargo feeding into booking, booking producing an itinerary made of legs, a handling-event recorded against a cargo's tracking id, and a cargo-tracker resource built from a cargo's handling history. A separate column on the right shows location and money as shared value types referenced from multiple entities: route-spec's origin and destination, a leg's load and unload locations, a handling-event's location, and a booking's price." caption="Figure 5.1: The cargo domain model: what books, what plans a route, what records history, and the two value types every entity shares." %}

## Three interfaces, one package

The split tracks one question: does this thing carry data, or does it do something with data?

| Interface | Owns | Contents |
|---|---|---|
| `types` | Data | `location`, `money`, `cargo`, `route-spec`, `booking`, `leg`, `itinerary`, `handling-event`, three enums, the `cargo-error` variant. No functions. |
| `booking` | Pre-shipment lifecycle | `book-cargo`, `request-possible-routes`, `assign-route`, `get-cargo` |
| `handling` | Movement once cargo is underway | `register-handling-event`, `list-handling-events`, the `cargo-tracker` resource |

The records compose. `cargo` carries a tracking ID, an origin, a destination and a weight. `route-spec` is the shipper's request: origin, destination and arrival deadline. `booking` ties a cargo to a route spec with an agreed price and a routing status. `leg` is one voyage between two locations within a load and unload window, and `itinerary` is an ordered list of legs satisfying one booking. `handling-event` records which cargo, what happened, where, on which voyage and when. None of them knows how to book a cargo or register an event: `types` is vocabulary, the role a shared `.proto` message file or a JSON Schema definitions block plays elsewhere.

`booking` and `handling` import `types` with `use` instead of redeclaring a record. The full `booking` interface:

```wit
/// Booking lifecycle: book a cargo against a route spec, request candidate
/// itineraries, assign one, and read a cargo back by tracking ID.
interface booking {
    use types.{cargo, booking, route-spec, itinerary, cargo-error};

    /// Book a new cargo shipment against a route specification.
    book-cargo: func(spec: route-spec, weight-kg: f64) -> result<booking, cargo-error>;

    /// Request the candidate itineraries that satisfy a booking's route
    /// spec.
    request-possible-routes: func(booking-id: string) -> result<list<itinerary>, cargo-error>;

    /// Assign one of the candidate itineraries to a booking.
    assign-route: func(booking-id: string, itinerary: itinerary) -> result<booking, cargo-error>;

    /// Look up a cargo by its tracking ID.
    get-cargo: func(tracking-id: string) -> result<cargo, cargo-error>;
}
```

Keeping `types` single and dependency-free means a later interface, such as customs clearance, reuses `location`, `money` and `cargo-error` without a second copy or a circular `use`. Keeping `booking` and `handling` apart means a component that only records and queries handling events imports `handling` and `types` and skips `booking`. A REST client importing one OpenAPI document has no way to declare that it uses three of twelve endpoints; a world's `import` list does.

## Conventions carried across the series

These come from the REST and gRPC contracts field for field, because the reasons don't depend on the protocol.

**Money is a decimal string.** A WIT `f64` is an IEEE 754 double, which can't represent every decimal fraction: `0.1 + 0.2` isn't `0.3`. A price computed in a component's linear memory has the same problem as a JSON number on the wire. `"1250.00"` means exactly `1250.00`, parsed by a decimal type on whichever side reads it.

```wit
    /// An amount of money.
    record money {
        /// Decimal string representation of the amount (for example
        /// "1250.00"), not a float, so currency arithmetic never loses
        /// cents to binary rounding.
        amount: string,
        currency: string,
    }
```

**Location is a UN/LOCODE.** `location.unlocode` is a five-character code such as `USNYC` or `NLRTM`, not free text or coordinates. "New York", "Port of New York and New Jersey" and "NYC" can name one terminal; a UN/LOCODE, maintained by UNECE, is the form terminals, customs and carriers already agree on. `name` and `country` ride along for display. Two locations are the same place when their `unlocode` values match.

**Enums start with `unspecified`.** `handling-event-type`, `routing-status` and `transport-status` each declare `unspecified` first, as the gRPC book's `*_UNSPECIFIED` zero values do. An absent field or an unknown future member falls back to the default, and the default has to be something a caller can test for. A `cargo-tracker` whose `current-status` returns `transport-status::unspecified` says no leg has reported yet. If `planned` held that slot, "planned" and "never set" would look the same.

**Errors are a variant, not an enum.** Each of the four `cargo-error` cases carries a `string` saying what was not found or invalid. A WIT `enum` only says which case occurred; a `variant` carries the payload a caller debugging a failed `assign-route` needs.

```wit
    /// Errors returned by the booking and handling interfaces.
    variant cargo-error {
        not-found(string),
        invalid-booking(string),
        invalid-location(string),
        conflict(string),
    }
```

{% include excalidraw.html file="05-domain-to-wit" alt="Diagram mapping domain concepts onto the three WIT interfaces in package patterncatalyst:cargo. The types interface band holds location and money, cargo/route-spec/booking, leg/itinerary/handling-event, and the three enums plus cargo-error, with no functions. The booking interface band holds book-cargo, request-possible-routes, assign-route, and get-cargo. The handling interface band holds register-handling-event, list-handling-events, and the cargo-tracker resource. Below, world cargo exports all three interfaces and world cargo-consumer imports the same three; a Rust component and a Go component both export world cargo, while a consumer component, such as an HTTP or gRPC adapter, imports world cargo-consumer and calls whichever implementation is composed with it." caption="Figure 5.2: Domain concepts in WIT: three interfaces, two worlds, and the side each component targets." %}

## Two worlds: who exports, who imports

A world is the bundle of imports and exports a component targets at build time. `world.wit` declares two over the same three interfaces:

```wit
/// The provider side of the cargo domain. A Rust or Go component that
/// implements booking and handling logic targets this world and exports
/// these interfaces for a host or another component to call.
world cargo {
    export types;
    export booking;
    export handling;
}

/// The consumer side of the cargo domain. A component that calls into a
/// `cargo`-implementing component, rather than implementing the domain
/// itself, targets this world and imports the same interfaces.
world cargo-consumer {
    import types;
    import booking;
    import handling;
}
```

A component targeting `cargo` is the provider. It implements `book-cargo`, `register-handling-event` and the rest, and exports them. Both the Rust and the Go component target `cargo`.

A component targeting `cargo-consumer` is the caller. It declares that it needs those functions to exist somewhere, and the toolchain generates import bindings instead of export bindings. An HTTP or gRPC adapter has this shape: it turns a request into a `booking` or `handling` call, and the logic lives in whichever `cargo` component is linked beside it.

Composition works because both worlds are built from the same `types`, `booking` and `handling` declarations, not two copies kept in step. A `cargo` export and a `cargo-consumer` import describe identical interfaces down to every field, so swapping the Rust provider for the Go one under the same adapter changes nothing for the caller.

## Rust and Go against the same world

A world isn't executable. A toolchain reads it and generates bindings, and the developer writes against those.

| | Rust | Go |
|---|---|---|
| Generator | `cargo-component` | `wit-bindgen-go` |
| Interface functions | A generated trait per exported interface, one method per function | A package-level `Exports` struct of function-valued fields per interface |
| WIT `result` | `Result<T, E>` | `cm.Result[Shape, T, E]` |
| Record | Generated `struct` | Generated struct with exported fields |
| Resource | An associated type plus a `GuestCargoTracker` trait with `&self` methods | A constructor, destructor and methods keyed by `cm.Rep` |

The surfaces differ because neither language should be pushed out of its idiom, and the contract underneath is one source. A call to `book-cargo` on the Rust component and on the Go component exercises the same `booking` interface.

Resources are the one construct with no equivalent in a stateless RPC. A resource is a handle: `constructor(tracking-id: string)` creates it, and `tracking-id`, `current-status` and `history` are called on that handle without passing the ID again.

```wit
    /// Tracks one cargo's current status and handling history. Construct
    /// one per tracking ID, then query it as handling events arrive.
    resource cargo-tracker {
        constructor(tracking-id: string);

        /// The tracking ID this tracker was constructed with.
        tracking-id: func() -> string;

        /// The cargo's most recent transport status.
        current-status: func() -> transport-status;

        /// The full handling history recorded for this cargo so far.
        history: func() -> list<handling-event>;
    }
```

A caller constructs one `cargo-tracker` per cargo it watches and calls it repeatedly, like a single-purpose client object. `book-cargo` and `register-handling-event` need no such shape because booking and recording are one-shot actions, while tracking is something a caller keeps doing.

> **Decision**
>
> Draw the component boundary between data and behavior, not between records. `types` holds every record, enum and the `cargo-error` variant with no functions, and `booking` and `handling` add behavior over that vocabulary. Keep `money.amount` a decimal string and `location` a UN/LOCODE: those conventions follow from what shipping needs, and WIT only changes the syntax. The cost is indirection: a reader follows a `use types.{...}` line to see a full signature. The payoff is one vocabulary for every consumer, future interface and language binding, so a field added to `booking` reaches all of them when the bindings are regenerated, instead of drifting across four hand-maintained schemas.

> **🤖 Explore with your agent**
>
> "In `contracts/wit/`, add a `cancel-booking: func(booking-id: string) -> result<booking, cargo-error>` function to the `booking` interface, reusing the existing `use types.{...}` list and returning `cargo-error::not-found` for an unknown ID. Keep `money.amount` a string and give any new enum an `unspecified` first member. Then run `wasm-tools component wit contracts/wit` and tell me which of `world cargo` and `world cargo-consumer` changed."
>
> Check: the command prints without error, and both worlds list `cancel-booking` through their `booking` interface without any edit to `world.wit`.

## Build, run, observe

The contract needs only `wasm-tools`:

```bash
wasm-tools component wit contracts/wit
```

It resolves the package and prints every interface and both worlds; a type error, a missing `use` or a duplicate name fails the command. The CI contract job runs the same command.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning, 2026): modeling a real domain as WIT interfaces and worlds, and the composition patterns built on this domain later.
- Shashank Jain, *WebAssembly for Cloud* (Apress, 2024): contract-first component design across languages, the problem the `types`, `booking` and `handling` split addresses.
- Eric Evans, *Domain-Driven Design: Tackling Complexity in the Heart of Software* (Addison-Wesley, 2003): the case for drawing a boundary around shared vocabulary and keeping behavior out of it, the shape `types` takes here.
- [WIT (Wasm Interface Type)](https://component-model.bytecodealliance.org/design/wit.html): the `interface`, `world`, `record`, `enum`, `variant` and `resource` constructs used here.
- [WebAssembly Component Model](https://component-model.bytecodealliance.org/): how a world's imports and exports compose at the binary level.

---
title: "The Shared Cargo Domain as Components"
order: 5
part: "Foundations"
description: "The shipping/cargo domain every later chapter builds on, modeled as Wasm components against the patterncatalyst:cargo WIT world shared by the Rust and Go implementations."
duration: "22 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the three interfaces in package `patterncatalyst:cargo@0.1.0` (`types`, `booking`, `handling`) and say which one owns data and which two own behavior.
- Explain why `money.amount` is typed as a `string` instead of `f32`/`f64`, and why `location` identifies a place by its UN/LOCODE rather than free text or coordinates.
- Trace a `book-cargo` call end to end: the `route-spec` it accepts, the `booking` it returns, and how `cargo-error` reports a failure without the caller ever seeing a trap.
- Distinguish `world cargo` from `world cargo-consumer`, and say which one a Rust or Go implementation of the domain targets versus which one a calling component targets.
- Explain why `cargo-tracker` is declared as a WIT `resource` rather than a pair of stateless functions, and what a constructed handle buys over passing `tracking-id` on every call.

## Why this matters

Chapter 3 described what a WIT world is (a name for a set of imported and exported interfaces), and Chapter 4 covered the host-side capabilities WASI Preview 2 grants a component. Neither chapter needed a real domain to make its point; an interface with two made-up functions illustrates imports and exports as well as a real one does. This chapter is where that abstraction becomes concrete: the one package every hands-on chapter from here forward targets, `patterncatalyst:cargo@0.1.0`, and the shipping/cargo domain it encodes as WIT records, enums, and functions, rather than as REST resources, Protobuf messages, or AsyncAPI channels.

That domain is not new to this series. The REST, gRPC, GraphQL, and WebSockets sibling sites all describe the same shipping and cargo story: a booking moving cargo from an origin to a destination, a route built from legs, a handling event recording what happened to the cargo in the physical world, each from its own protocol's angle. This site tells the same story one layer down: not as a wire format a client parses, but as a typed component interface two different languages compile against and call into directly. Chapter 6 writes the Rust side of that interface, Chapter 7 writes the Go side, and Chapter 8 wires the two together through the same WIT world named in full below. Nothing downstream of this chapter re-derives the domain from scratch; every record name, every enum member, and every function signature quoted here is copied from `contracts/wit/`, the same files `wasm-tools component wit` validates in CI.

{% include excalidraw.html file="05-cargo-domain" alt="Domain model diagram showing route-spec and cargo feeding into booking, booking producing an itinerary made of legs, a handling-event recorded against a cargo's tracking id, and a cargo-tracker resource built from a cargo's handling history. A separate column on the right shows location and money as shared value types referenced from multiple entities: route-spec's origin and destination, a leg's load and unload locations, a handling-event's location, and a booking's price." caption="Figure 5.1 — The cargo domain model: what books, what plans a route, and what records history, plus the two shared value types every entity borrows from." %}

## The shipping/cargo domain, continuous across the series

A shipper books cargo for transport between two ports. The carrier plans an itinerary: one or more legs, each a single voyage moving the cargo between two locations within a time window. As the cargo moves, the system records handling events: received at origin, loaded aboard a vessel, unloaded at a port, held by customs, claimed at destination. That is the entire story, and it is the same story the REST site's `Booking` and `Cargo` resources tell over HTTP, the gRPC site's `Booking` and `Cargo` Protobuf messages tell over four RPC types, and the WebSockets site's `HandlingEvent` feed tells as a stream of pushes. Each site picks a different slice of the story to emphasize (REST models the full resource lifecycle, gRPC adds typed RPCs and long-running operations, WebSockets narrows to the live event feed), but none of them invented a second domain. They are one glossary, read through four different protocol lenses.

This site reads the same glossary through a fifth lens: not a protocol at all, but a component boundary. A WIT interface has no wire format of its own (no HTTP verb, no status code, no message envelope) because a component's calls into another component happen in-process, as typed function calls the Component Model's canonical ABI lowers to and lifts from linear memory. What travels between a caller and the cargo domain's implementation is not bytes on a socket but a `route-spec` record, a `result<booking, cargo-error>`, values a compiler checks at build time rather than a schema a runtime validates after the fact. The domain itself does not change shape because of that; `booking-id`, `cargo-id`, `price`, and `status` mean exactly what they mean on the REST and gRPC sites. What changes is the boundary the domain is pinned against, and this chapter is concerned entirely with that boundary.

One domain noun present on the gRPC sibling site has no analog here: `Operation`, the async long-running-job pattern gRPC uses for work like route recomputation that takes longer than a single RPC round trip. The `patterncatalyst:cargo` package has no equivalent, because `request-possible-routes` returns its `list<itinerary>` directly, as a synchronous `result`. A component call is a function call inside a shared address space; there is no network round trip to amortize by returning a handle a caller polls later. A Wasm component with work that actually spans a real external system rather than a local computation would model that with a WASI async primitive or a resource exposing poll-style methods, not by importing `Operation` from the gRPC site's vocabulary. That gap is a direct consequence of the component boundary, not an oversight in this package.

## Three interfaces, one package

Package `patterncatalyst:cargo@0.1.0` splits into three interfaces, and the split tracks a single question: does this thing carry data, or does it do something with data?

`types` answers the first half. It declares every record and enum the domain needs and the shared `cargo-error` variant every fallible function returns, and it declares zero functions. `location` carries a UN/LOCODE plus a name and a country. `money` carries an amount and a currency. `cargo` carries a tracking ID, an origin, a destination, and a weight. `route-spec` is the shipper's request: an origin, a destination, and an arrival deadline. `booking` ties a cargo to a route-spec with an agreed price and a routing status. `leg` is one voyage's movement between two locations within a load and unload window, and `itinerary` is an ordered list of legs satisfying one booking's route-spec. `handling-event` is the record of something that happened: which cargo, what kind of event, where, on which voyage, and when. None of those eight records knows how to book a cargo or register an event; `types` is vocabulary, not behavior, the same role a shared `.proto` message file or a JSON Schema definitions block plays on the sibling sites, just expressed as a WIT interface instead.

`booking` and `handling` answer the second half, and each imports `types` with a `use` statement rather than redeclaring any record. `booking` owns the lifecycle a shipment goes through before anything physical happens: `book-cargo` accepts a `route-spec` and a weight and returns a new `booking`; `request-possible-routes` takes a `booking-id` and returns the candidate itineraries that satisfy its route-spec; `assign-route` commits one of those itineraries to the booking; `get-cargo` looks a cargo up by its tracking ID. `handling` owns everything that happens once cargo is moving: `register-handling-event` records a new event, `list-handling-events` returns a cargo's history in order, and the `cargo-tracker` resource, covered in its own section below, follows one cargo's status and history as a stateful handle rather than a pair of stateless calls.

That three-way split is a design decision with real alternatives, because it would have been just as valid to fold `booking` and `handling` into one interface, or to split `types` per-interface instead of sharing it. Keeping `types` single and dependency-free means a future interface (a customs-clearance interface, say, added in a later package version) reuses `location`, `money`, and `cargo-error` without introducing a second copy of any of them or a circular `use` between interfaces. Keeping `booking` and `handling` separate means a component that only needs to record and query handling events, and never books anything, can import `handling` and `types` alone and skip `booking` entirely, a real distinction a WIT world's `import` list makes explicit, where a REST client importing one OpenAPI document has no equivalent way to declare it only uses three of twelve endpoints.

## Conventions carried across the series

Three conventions on this package are not local inventions; they are carried over, field for field, from the REST and gRPC sibling sites' own contracts, because the reasons behind each one have nothing to do with which protocol or interface language is doing the carrying.

**Money is a decimal string.** `money.amount` is typed `string`, holding a value like `"1250.00"`, never an `f32` or `f64`. A WIT `f64` is an IEEE 754 double, and a double cannot represent every decimal fraction exactly — the familiar failure where `0.1 + 0.2` does not equal `0.3` in binary floating point is the same failure waiting inside a shipping price computed in a component's linear memory as it is inside a JSON number on the wire. A string sidesteps the representation question: `"1250.00"` means exactly `1250.00`, parsed by a decimal type on whichever side reads it, with no binary approximation sitting between the value a shipper agreed to and the value a later computation reads back. This is the exact convention the REST site's JSON Schema and the gRPC site's Protobuf `Money` type both commit to; the WIT `money` record just restates it in a language whose native floating-point type would otherwise have been the obvious, and wrong, first choice.

**Location is identified by UN/LOCODE.** `location.unlocode` is a five-character code like `USNYC` or `NLRTM`, not a free-text city name and not a latitude/longitude pair. A free-text name invites exactly the ambiguity a shipping system cannot afford — "New York" and "Port of New York and New Jersey" and "NYC" all naming the same terminal, with no canonical form a downstream system can match against without a lookup table of its own. A UN/LOCODE is already that canonical form, maintained by UNECE and used across the shipping industry as the identifier a terminal, a customs authority, and a carrier's own systems all agree on. Carrying `name` and `country` alongside `unlocode` on the `location` record keeps the human-readable label available for display without making it the field anything compares against; two `location` values are the same place if their `unlocode` fields match, independent of whatever string happens to sit in `name`.

**Enums put an explicit `unspecified` value first.** `handling-event-type`, `routing-status`, and `transport-status` each declare `unspecified` as their first member, ahead of every real value the enum otherwise names. This mirrors the `*_UNSPECIFIED`-zero-value convention the gRPC sibling site's Protobuf enums use, and the reason transfers unchanged: a WIT enum, like a Protobuf enum, has a default value a deserializer falls back to when a field is absent or when a future member this binary does not yet know about arrives, and that default needs to be a value callers can check for and branch on, not silently collapse into whatever the first *meaningful* member happens to be. A `cargo-tracker` whose `current-status` returns `transport-status::unspecified` is telling a caller "no leg has reported a status yet," a real and checkable condition; if `planned` sat in that slot instead, there would be no way to tell "a leg is actually planned" apart from "nothing has set this field at all."

One more convention is specific to the error path rather than to a single field: `cargo-error` is declared as a `variant`, not an `enum`, because each of its four cases (`not-found`, `invalid-booking`, `invalid-location`, `conflict`) carries a `string` payload describing what, specifically, was not found or invalid. An `enum` in WIT can only distinguish which case occurred; a `variant` can carry data alongside that choice, which is exactly what a caller debugging a failed `assign-route` call needs: not just that the booking was invalid, but which constraint the itinerary failed to satisfy.

{% include excalidraw.html file="05-domain-to-wit" alt="Diagram mapping domain concepts onto the three WIT interfaces in package patterncatalyst:cargo. The types interface band holds location and money, cargo/route-spec/booking, leg/itinerary/handling-event, and the three enums plus cargo-error, with no functions. The booking interface band holds book-cargo, request-possible-routes, assign-route, and get-cargo. The handling interface band holds register-handling-event, list-handling-events, and the cargo-tracker resource. Below, world cargo exports all three interfaces and world cargo-consumer imports the same three; a Rust component built with cargo-component and a Go component built with wasm-tools both implement and export world cargo, while a separate consumer component — an HTTP or gRPC adapter — imports world cargo-consumer and calls into whichever implementation is composed with it." caption="Figure 5.2 — Domain concepts landing in WIT: three interfaces, two worlds, and which side a Rust, Go, or consumer component targets." %}

## The two worlds: who exports, who imports

A WIT world is a named bundle of imports and exports a single component targets at build time, and `world.wit` declares exactly two for this domain, over the identical set of three interfaces.

`world cargo` exports `types`, `booking`, and `handling`. A component targeting `cargo` is the provider: it implements `book-cargo`, `register-handling-event`, every function the two behavioral interfaces declare, and it is the component a host or another component instantiates to get real booking and handling logic. Both the Rust component Chapter 6 builds and the Go component Chapter 7 builds target `world cargo`, each compiling its own implementation of the same three interfaces into a `.wasm` binary that exports them.

`world cargo-consumer` imports the same three interfaces instead of exporting them. A component targeting `cargo-consumer` is the caller: it declares that it needs `book-cargo` and `register-handling-event` to exist somewhere, without implementing either itself, and the WIT toolchain generates import bindings rather than export bindings from that declaration. An HTTP adapter component (Chapter 11) or a gRPC adapter component (Chapter 12) is exactly this shape: it translates an incoming HTTP request or gRPC call into a `booking` or `handling` function call, but the booking and handling logic itself lives in whichever `cargo`-exporting component gets linked in alongside it.

That export/import split is what makes component composition, the subject of Chapter 8, possible at all rather than a vague promise. A `cargo-consumer` component's imports and a `cargo`-exporting component's exports describe the identical three interfaces, down to every record field and function signature, because both worlds are built from the same `types`, `booking`, and `handling` declarations rather than two independently maintained copies. Composing a Rust-built `cargo` provider with a `cargo-consumer` HTTP adapter, or swapping that provider for the Go-built one without touching the adapter at all, is a direct consequence of this exact symmetry — the kind of substitution Chapter 1 already previewed when it called the Rust and Go implementations interchangeable from any caller's point of view, and the mechanism behind that claim is nothing more than these two worlds sharing one set of interfaces.

## Rust and Go against the same world

Chapters 6 and 7 do the work of actually compiling a `cargo`-exporting component in each language; this chapter stops at the concept both chapters build from, because the concept is the same regardless of which language gets there first.

A WIT world is not itself executable code in either language: it is a contract a toolchain reads to generate bindings, and those bindings are what a developer actually writes against. On the Rust side, `cargo-component` reads `contracts/wit/` and generates a Rust trait for each exported interface, with one method per WIT function and Rust types (`String`, `f64`, `Result`, a generated `struct` per record, a generated `enum` per WIT enum) standing in for the WIT types on function boundaries. Implementing `world cargo` in Rust means writing a type that implements those generated traits: a `book-cargo` method whose signature `cargo-component` already fixed, taking a generated `RouteSpec` struct and a `f64`, returning a `Result<Booking, CargoError>`.

On the Go side, the same WIT files drive a different generator (`wasm-tools` paired with Go's WASI Preview 2 binding support), producing Go types and function signatures instead of Rust ones: a `RouteSpec` struct with exported fields matching the WIT record, a `BookCargo` function whose return type encodes the WIT `result` as a Go two-value return or a generated result type, depending on the generator's chosen idiom. The generated surface looks different in the two languages, because Rust's `Result<T, E>` and Go's `(T, error)` are different idioms neither language should be forced out of, but the WIT contract underneath generates both from one source. A test that calls `book-cargo` against the Rust component and the same conceptual call against the Go component is exercising the identical `booking` interface in both cases; the difference is entirely in which language's binding generator produced the function signature being called.

`cargo-tracker`'s resource shape matters here specifically because resources are the one WIT construct with no equivalent in a stateless RPC call. A resource is a handle: `constructor(tracking-id: string)` creates one, and `tracking-id`, `current-status`, and `history` are methods called against that specific handle rather than free functions each needing `tracking-id` passed in again. In Rust, that generates an owned type whose methods take `&self`; in Go, a generated struct or interface value with methods bound to it. Either way, a caller constructs one `cargo-tracker` per cargo it is watching and calls its methods repeatedly, instead of calling three stateless functions and passing the same tracking ID into all three — closer to a single-purpose client object than to the per-call style `booking`'s four functions use, and a shape neither `book-cargo` nor `register-handling-event` needed, because booking and recording are one-shot actions while tracking is something a caller keeps doing.

## The WIT world for this site

Here is the shape both languages build against, trimmed to the fields and functions this chapter has already named, exactly as `contracts/wit/types.wit`, `contracts/wit/bookings.wit`, `contracts/wit/handling.wit`, and `contracts/wit/world.wit` declare them:

```wit
package patterncatalyst:cargo@0.1.0;

interface types {
    record location {
        unlocode: string,
        name: string,
        country: string,
    }

    record money {
        amount: string,
        currency: string,
    }

    record booking {
        booking-id: string,
        cargo-id: string,
        route-spec: route-spec,
        price: money,
        status: routing-status,
    }

    enum routing-status {
        unspecified,
        not-routed,
        routed,
        misrouted,
    }

    variant cargo-error {
        not-found(string),
        invalid-booking(string),
        invalid-location(string),
        conflict(string),
    }
}

interface booking {
    use types.{cargo, booking, route-spec, itinerary, cargo-error};

    book-cargo: func(spec: route-spec, weight-kg: f64) -> result<booking, cargo-error>;
    get-cargo: func(tracking-id: string) -> result<cargo, cargo-error>;
}

interface handling {
    use types.{handling-event, handling-event-type, location, transport-status, cargo-error};

    register-handling-event: func(
        cargo-id: string,
        event-type: handling-event-type,
        location: location,
        voyage-id: string,
        recorded-at: string,
    ) -> result<_, cargo-error>;

    resource cargo-tracker {
        constructor(tracking-id: string);
        tracking-id: func() -> string;
        current-status: func() -> transport-status;
        history: func() -> list<handling-event>;
    }
}

world cargo {
    export types;
    export booking;
    export handling;
}

world cargo-consumer {
    import types;
    import booking;
    import handling;
}
```

Every identifier above (`patterncatalyst:cargo@0.1.0`, `routing-status`, `cargo-error`, `book-cargo`, `register-handling-event`, `cargo-tracker`) is quoted exactly as `contracts/wit/` declares it, including the hyphenated kebab-case WIT itself requires. The full files add `request-possible-routes` and `assign-route` to `booking`, `list-handling-events` to `handling`, and the remaining records (`cargo`, `route-spec`, `leg`, `itinerary`, `handling-event`, and the `handling-event-type` and `transport-status` enums) to `types`; none of that is new material beyond what this chapter has already walked through field by field.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>The component boundary in this package sits between data and behavior, not between one record and another: <code>types</code> holds every record, enum, and the shared <code>cargo-error</code> variant with zero functions, and <code>booking</code> and <code>handling</code> add behavior over that shared vocabulary without either one redeclaring a type the other also needs. That is why <code>money.amount</code> stays a decimal string rather than becoming an <code>f64</code> once it is expressed in a language with real numeric types, and why <code>location</code> stays pinned to a UN/LOCODE rather than loosening into free text: both conventions were set by what a shipping system needs to stay correct, not by what any one interface language makes convenient, and WIT changes the syntax those decisions are written in without giving either one a reason to change. The cost of the three-interface split is indirection: implementing <code>booking</code> alone still requires a <code>use types.{...}</code> import pulling in records this interface does not own, and a reader has to follow that import to see a full function signature. The payoff is that <code>cargo-consumer</code> components, future interfaces, and both language implementations all draw from one shared vocabulary, so a field added to <code>booking</code> the record is visible to every interface and every language binding the moment <code>contracts/wit/</code> is regenerated, rather than drifting across four independently maintained copies the way the same domain's REST, gRPC, and GraphQL schemas would without a shared source.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning, 2026) — modeling a real domain as WIT interfaces and worlds, and the component-composition patterns Chapter 8 builds on from here.
- Shashank Jain, *WebAssembly for Cloud* (Apress, 2024) — contract-first component design across languages, the same problem this chapter's `types`/`booking`/`handling` split addresses.
- Eric Evans, *Domain-Driven Design: Tackling Complexity in the Heart of Software* (Addison-Wesley, 2003) — the originating case for drawing a boundary around shared vocabulary and keeping behavior out of it, the same shape `types` takes here.
- [WIT (Wasm Interface Type)](https://component-model.bytecodealliance.org/design/wit.html) — the `interface`, `world`, `record`, `enum`, `variant`, and `resource` constructs this chapter's excerpt uses.
- [WebAssembly Component Model](https://component-model.bytecodealliance.org/) — how a world's imports and exports compose at the binary level, the mechanism Chapter 8 exercises directly.

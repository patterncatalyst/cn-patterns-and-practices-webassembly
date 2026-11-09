---
title: "The Component Model and WIT"
order: 3
part: "Foundations"
description: "Interfaces as the contract between components, how a WIT world describes imports and exports, and what it takes to compose components together."
duration: "22 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why a raw WebAssembly module cannot describe a structured argument or return value, and what the Component Model adds on top of it to fix that.
- Read `contracts/wit/types.wit`, `bookings.wit`, and `handling.wit` and identify every record, enum, variant, and resource the shipping domain is built from.
- Tell a world's imports apart from its exports using `contracts/wit/world.wit`'s `cargo` and `cargo-consumer` worlds, and say which side a provider component targets and which side a caller targets.
- Run `wasm-tools component wit contracts/wit` and read its resolved output against the four source files it was built from.
- State the Component Model's standardization status as of late 2026, and what that status does and does not change about building against it today.

## Why this matters

A raw WebAssembly module answers "what can one component ask another to do?" badly. Its exports take and return `i32`, `i64`, `f32` and `f64`. A module that wants to hand over a string, a record or a list has to agree out of band on a memory layout, write the data into linear memory and pass a pointer and a length as two integers. Two modules from different teams in different languages can follow that scheme and still misread each other's bytes the moment one struct layout drifts. The signature `(i32, i32) -> i32` is equally true of a string and of two unrelated numbers.

The Component Model closes that gap. WIT, the Wasm Interface Type language, is how a component states its half of the agreement in a form that both sides and every tool between them can read. The cargo package in `contracts/wit/` is a shipping domain of bookings, routes and handling events, expressed as interfaces and bound into two worlds. Rust and Go components later in the series are built against it.

## Interfaces as the contract

The agreement between two sides lives in a file that is checked before either side's code exists, so a reviewer can read a diff of the agreement without reading either implementation. REST does this with an OpenAPI document, gRPC with a `.proto` package compiled by Buf, and Wasm components with a WIT package. A `.wit` file is not documentation of an API. It is the API, and a toolchain reads it to produce the types and signatures both sides must satisfy.

What sits behind the contract is different here. WIT describes the boundary between two WebAssembly components: no network hop and no wire format, just two sandboxes exchanging calls through a runtime that lowers a WIT-typed value into linear memory on one side and lifts it out on the other. The lowering and lifting are generated, so no implementation detail can change what crosses the boundary without changing the file first.

Package `patterncatalyst:cargo@0.1.0` has three interfaces, `types` (`types.wit`), `booking` (`bookings.wit`) and `handling` (`handling.wit`), bound into two worlds in `world.wit`. `types` holds every shared shape and no functions. `booking` and `handling` each add one slice of behavior on top of it.

{% include excalidraw.html file="03-wit-package-structure" alt="The patterncatalyst:cargo package: interface types at the top holding every record, enum, and the cargo-error variant, with interface booking and interface handling below it each declaring use types.{...} to pull in the exact subset of shapes their functions need." caption="Figure 3.1: One shared interface and two behavior interfaces. The types interface carries every shape, and booking and handling add functions over it." %}

## WIT's type vocabulary

A `record` is a plain product type: a named bundle of named fields. `location` is the simplest in the package:

```wit
    /// A location identified by its UN/LOCODE (for example "USNYC" for
    /// New York).
    record location {
        unlocode: string,
        name: string,
        country: string,
    }
```

`unlocode` is a UN/LOCODE such as `USNYC`, not an arbitrary string. `money` is a record whose `amount` is a `string`, because WIT has no fixed-point decimal and a binary float would drop cents over enough arithmetic. `cargo`, `route-spec`, `booking`, `leg`, `itinerary` and `handling-event` compose the simpler records: `cargo` embeds two `location` values, `booking` embeds a `route-spec` and a `money`, and `itinerary` holds a `list<leg>`. `list<T>` is WIT's only generic container: there is no map, no set and no tuple shorthand beyond what a record gives you.

Three `enum`s follow one convention: `unspecified` is the first value.

```wit
    /// The kind of handling event recorded against a cargo. `unspecified`
    /// is the explicit zero value so callers cannot mistake an unset
    /// field for a real event type.
    enum handling-event-type {
        unspecified,
        received,
        loaded,
        unloaded,
        customs,
        claimed,
    }
```

An absent or malformed field reads as an explicit "no value was set". Defaulting to `received` would be a wrong fact that looks real, and `unspecified` is a visible absence the caller has to check. `routing-status` and `transport-status` use the same shape.

The package's one `variant`, a tagged union of which exactly one case is present at a time, is its error type:

```wit
    /// Errors returned by the booking and handling interfaces.
    variant cargo-error {
        not-found(string),
        invalid-booking(string),
        invalid-location(string),
        conflict(string),
    }
```

Every function that can fail returns `result<_, cargo-error>` or `result<T, cargo-error>`, so failure is part of the function's type and every binding generator checks it.

A `resource` is the one construct a record or list can't express. A record is a value: pass it across the boundary and the receiver holds an independent copy. A resource is a handle to something with identity and state that stays where it was created. The other side calls its methods without ever holding the state they close over. `handling.wit` uses one for the stateful piece of the domain, a tracker you construct once and query repeatedly:

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

`bookings.wit` and `handling.wit` each open with a `use` naming exactly the `types` members they need, such as `use types.{cargo, booking, route-spec, itinerary, cargo-error}` in `bookings.wit`. The clause is the complete list of types an interface touches, so a reviewer doesn't scan `types.wit` for what might be relevant.

`booking` declares the shipment lifecycle in four functions: `book-cargo` takes a `route-spec` and a weight and returns a `booking`, `request-possible-routes` returns a `list<itinerary>` for a booking ID, `assign-route` commits one itinerary, and `get-cargo` looks a cargo up by tracking ID. `handling` adds `register-handling-event` and `list-handling-events` beside `cargo-tracker`. Those six signatures and the resource are the complete surface either language must implement.

## Worlds: the same interfaces, read in one direction

A world states which interfaces a component provides and which it needs. `world.wit` declares two over the same three interfaces:

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

`cargo` is the provider side. A Rust or Go component that implements booking and handling logic targets `cargo` and exports all three interfaces for a host or another component to call. `cargo-consumer` is the caller side. A component that needs to book cargo without implementing it targets `cargo-consumer` and imports the same three interfaces, a dependency that composition must satisfy before the component can run.

{% include excalidraw.html file="03-world-imports-vs-exports" alt="The same three interfaces, types, booking, and handling, feeding into world cargo as exports on the left and into world cargo-consumer as imports on the right, with a dashed bidirectional arrow between the two worlds labeled same shape, opposite direction." caption="Figure 3.2: A world names no new types. It only states which direction each interface faces." %}

A world adds no type and no function. It is a direction applied to interfaces that already exist, which is why one package defines two worlds without duplicating a record. A provider exporting `book-cargo` with the signature `func(spec: route-spec, weight-kg: f64) -> result<booking, cargo-error>` and a consumer importing that signature satisfy each other by construction, because both were checked against the same WIT source.

## Composing components

A component built against `cargo-consumer` can't run alone. A runtime refuses to instantiate a component with an import nothing satisfies. Composition wires one component's export to another's matching import so the pair runs as one unit.

{% include excalidraw.html file="03-component-composition" alt="A component named cargo-service.wasm built against world cargo on the left, exporting booking and handling, wired by a composed-component step to a component named gateway.wasm on the right built against world cargo-consumer, importing the same two interfaces; a note states composition links by interface identifier, not by source language." caption="Figure 3.3: Composing a provider's export to a consumer's import. The WIT identifiers match, and the source languages don't have to." %}

Take a `cargo-service.wasm` built in Rust against `cargo` and a `gateway.wasm` built in Go against `cargo-consumer`. Composition matches the gateway's imported `booking` interface to the service's exported one by the shared identifier `patterncatalyst:cargo@0.1.0/booking`, not by source language or toolchain. The composed pair has no unmet imports left and looks to a host like one component. A Go gateway over a Rust service is exactly as valid as two components in one language. That cross-language property is the Component Model's headline claim, and it is why the series builds the same domain in Rust and in Go against one package.

## From WIT to bindings to a component

Neither Rust nor Go understands WIT directly. Each toolchain generates source its language does understand from the world a component targets, before any domain logic is written.

{% include excalidraw.html file="03-wit-bindings-pipeline" alt="contracts/wit/ feeding two parallel paths: cargo-component generating a Rust binding crate on the left, and wasm-tools plus wit-bindgen-go generating a Go binding package on the right, each converging into a .wasm component implementing world cargo." caption="Figure 3.4: One WIT source, two independent toolchains, each producing the trait or interface its own language's code implements." %}

In Rust, `cargo-component` generates a trait matching the interface's functions one for one, and generated code lowers a Rust `Result<Booking, CargoError>` into the WIT `result<booking, cargo-error>`. In Go, `wasm-tools` with `wit-bindgen-go` generates an interface and supporting types, with the same lowering in generated code. Generated bindings can't drift from the WIT source, because every build produces them fresh from the file. A hand-maintained binding drifts the first time either side changes alone.

## WIT versus the raw module

A core module has no record, enum, result or resource. Its exports are a flat list of functions typed in numbers, plus memory and table references. Every `cargo` and `cargo-consumer` component compiles down to one or more core modules wired together by component-level machinery that lowers a `booking` into linear memory on one side of a call and lifts it back on the other. The Component Model doesn't replace the core format. It layers a typed boundary on top and generates the lowering and lifting code so no source language writes it by hand.

As of late 2026 the Component Model is not a finished, versioned 1.0 specification. It is moving through the W3C WebAssembly Community Group's phase process, with the binary component format, WIT and the canonical ABI that defines lowering and lifting at different stages of stabilization. `wasm-tools`, `cargo-component` and `wit-bindgen-go` implement the same canonical ABI version this package targets, so a WIT file written today reads the same across the whole toolchain. A later revision could add vocabulary, streams and futures for asynchronous interfaces chief among the candidates, without changing what this package already declares.

> **Decision**
>
> Split along a boundary that something outside the WIT file already needs to reason about separately. `types` stands alone because both `booking` and `handling` need the same vocabulary, and a duplicated vocabulary drifts the first time one copy changes. `booking` and `handling` stay separate because they are two responsibilities, the booking workflow and the tracking workflow, even though the early examples implement both in one component. Keeping them separate interfaces means a later split into two components costs a redeployment, not a WIT rewrite. Two worlds exist because the domain has a real provider side and a real caller side, and a single world that exports some interfaces while importing others hides which direction a component commits to. A domain with one component that both implements and calls its own interfaces needs only one.

> **🤖 Explore with your agent**
>
> "In `contracts/wit`, add a `cancel-booking: func(booking-id: string) -> result<booking, cargo-error>` function to the `booking` interface in `bookings.wit`, reusing the existing `use types.{...}` list. Then say whether `world cargo` and `world cargo-consumer` need any edit, and why, using the rule that a world is only a direction applied to existing interfaces."
>
> Check: `wasm-tools component wit contracts/wit` resolves without error and lists `cancel-booking` under `interface booking`, and `world.wit` is unchanged.

## Build, run, observe

Print the whole package with every `use` followed:

```bash
wasm-tools component wit contracts/wit
```

The output has the package line, the `types`, `booking` and `handling` interfaces in one resolved view, and the `cargo` and `cargo-consumer` worlds. This resolved view is what every binding generator consumes. To see a provider's side of the same contract, build the Rust component in `examples/part2-building-components/rust` with `cargo component build --release`, then run `wasm-tools component wit` on the resulting `.wasm`. It shows the `export` lines for `types`, `booking` and `handling`.

Experiments:

- Misspell a type in a `use` clause, such as `cargo-eror`. Resolution fails here, before any language toolchain runs.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model and WIT covered as the foundation server-side Wasm tooling builds on.
- Shashank Jain, *WebAssembly for Cloud* (Apress): component composition and cross-language interoperability in cloud deployments.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): the canonical reference for worlds, interfaces, and the canonical ABI behind lowering and lifting.
- [WIT (Wasm Interface Type) specification](https://component-model.bytecodealliance.org/design/wit.html): the full grammar for records, enums, variants, resources, and worlds.

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
- Read `contracts/wit/types.wit`, `bookings.wit`, and `handling.wit` and identify every record, enum, variant, and resource this site's shipping domain is built from.
- Tell a world's imports apart from its exports using `contracts/wit/world.wit`'s `cargo` and `cargo-consumer` worlds, and say which side a provider component targets and which side a caller targets.
- Run `wasm-tools component wit contracts/wit` and read its resolved output against the four source files it was built from.
- State the Component Model's standardization status as of this writing, and what that status does and does not change about building against it today.

## Why this matters

The case for shipping server-side workloads as Wasm components instead of containers rests on the execution model underneath it: linear memory, the sandbox boundary, capability-based security instead of ambient authority. Neither of those answers a question that matters the moment two components need to talk to each other: what, exactly, can one component ask another to do?

A raw WebAssembly module answers that question badly. Its exported functions take and return `i32`, `i64`, `f32`, `f64`, and nothing else; a module that wants to hand another module a string, a record, or a list has to agree out of band on a memory layout, write the data into linear memory itself, and pass a pointer and a length as two plain integers. Two modules built by different teams, in different languages, can satisfy that scheme and still misread each other's bytes the moment one side's struct layout drifts from the other's. Nothing in the module format describes the shape of what crossed the boundary; the signature says `(i32, i32) -> i32`, which is true of a string argument and equally true of two unrelated numbers.

The Component Model exists to close exactly that gap, and WIT (the Wasm Interface Type language) is how a component states its half of the agreement in a form both sides, and every tool between them, can read. This chapter walks the actual WIT package that ships in this site's `contracts/wit/` directory: a shipping and cargo domain with bookings, routes, and handling events, expressed as interfaces and bound into two worlds. By the end you will have read every identifier that domain is built from, and the chapters that follow this one, implementing it in Rust and then in Go, hand you the exact bindings a toolchain generates from the file you are about to read.

## Interfaces as the contract

This series has made the same move for every protocol it covers: pin the agreement between two sides down in a file that is checked before either side's code exists, so a reviewer can read a diff of the agreement without reading either implementation. The REST site uses an OpenAPI document. The gRPC site compiles a `.proto` package with Buf. This site uses a WIT package, and the shape of the commitment is the same: a `.wit` file is not documentation of an API, it is the API, and a toolchain reads it to produce the types and function signatures either side's source code has to satisfy.

What sits on the other side of that contract differs here. OpenAPI describes HTTP requests and responses. Protobuf describes messages carried over gRPC's framing. WIT describes the boundary between two WebAssembly components, which is a narrower and stranger thing than either: no network hop, no serialization format a client can inspect on the wire, just two sandboxes exchanging calls through a runtime that lowers a WIT-typed value into linear memory on one side and lifts it back out on the other. That lowering and lifting is mechanical and generated, not something either component's source code writes by hand, which is why reading the WIT means reading the whole contract: no implementation detail can change what crosses the boundary without changing the file first.

Package `patterncatalyst:cargo@0.1.0` is split into three interfaces inside `contracts/wit/`: `types` (`types.wit`), `booking` (`bookings.wit`), and `handling` (`handling.wit`), bound into two worlds in `world.wit`. The split is not arbitrary. `types` holds every shared shape and carries no functions; `booking` and `handling` each add one slice of behavior on top of it. That separation is the chapter's second thread, after the type vocabulary itself, and it closes the chapter as a named decision.

{% include excalidraw.html file="03-wit-package-structure" alt="The patterncatalyst:cargo package: interface types at the top holding every record, enum, and the cargo-error variant, with interface booking and interface handling below it each declaring use types.{...} to pull in the exact subset of shapes their functions need." caption="Figure 3.1: one shared interface and two behavior interfaces; types carries every shape, booking and handling add functions over it." %}

## WIT's type vocabulary, read from the real package

`types.wit` opens with a doc comment stating its job in one line: "shared records, enums, and the shared error type for the shipping and cargo domain... no functions live here." Everything that follows backs that claim.

A `record` in WIT is a plain product type, a named bundle of named fields, each with its own type. `location` is the simplest one in the package:

```wit
record location {
    unlocode: string,
    name: string,
    country: string,
}
```

Three strings, each carrying structured meaning this record's name supplies: `unlocode` is a UN/LOCODE like `USNYC`, not an arbitrary string. `money` is a record too, and its doc comment states a decision directly: the `amount` field is a `string`, not a numeric type, specifically because WIT has no fixed-point decimal and a binary float would drop cents over enough arithmetic. `cargo`, `route-spec`, `booking`, `leg`, `itinerary`, and `handling-event` are all records built the same way, composing the simpler records above them: `cargo` embeds two `location` values for its origin and destination, `booking` embeds a `route-spec` and a `money`, `itinerary` holds a `list<leg>`. `list<T>` is WIT's one generic container, and it is the only one; there is no map, no set, no tuple shorthand beyond what a record already gives you.

Three `enum`s follow, and each one shares a convention that holds across the whole package: `unspecified` is always the first value.

```wit
enum handling-event-type {
    unspecified,
    received,
    loaded,
    unloaded,
    customs,
    claimed,
}
```

`routing-status` and `transport-status` repeat the same shape: `unspecified` first, then the real values. An enum in a serialization format defaults to its zero value when a field is absent or a sender omits it; putting a named `unspecified` at that zero position means an absent or malformed field reads as an explicit "no value was set" rather than silently landing on whatever the first *meaningful* value happens to be. A `handling-event-type` that defaulted to `received` on a missing field would be a wrong fact masquerading as a real one; defaulting to `unspecified` is a visible absence a caller has to check for.

The package's one `variant` is its error type:

```wit
variant cargo-error {
    not-found(string),
    invalid-booking(string),
    invalid-location(string),
    conflict(string),
}
```

A `variant` is WIT's tagged union: exactly one of these four cases is present at a time, and three of the four carry a `string` payload (a message or identifier explaining the failure), while the shape itself guarantees a caller can only ever be holding one specific kind of error, never an ambiguous combination. Every function in `booking` and `handling` that can fail returns `result<_, cargo-error>` or `result<T, cargo-error>` rather than a bare value, which means failure is part of the function's type, checked by every binding generator that reads this file, not a convention a caller has to remember to honor.

`handling.wit` adds the one vocabulary item not yet covered: `resource`.

```wit
resource cargo-tracker {
    constructor(tracking-id: string);

    tracking-id: func() -> string;
    current-status: func() -> transport-status;
    history: func() -> list<handling-event>;
}
```

Every type up to this point describes a value: pass it across the boundary, and the receiving side has an independent copy with no further relationship to the sender. A `resource` is different. It describes a handle to something with identity and internal state that stays wherever it was created; a `cargo-tracker`, once constructed with a `tracking-id`, exists on one side of the boundary, and the other side holds a reference to it, calling its methods without ever holding the state those methods close over. That is the one thing a record and a list cannot express, and it is why `handling.wit` reaches for a resource specifically for the one piece of this domain that is inherently stateful over time, a tracker you construct once and query repeatedly, rather than a value you'd reconstruct per call.

`bookings.wit` and `handling.wit` each open with a `use` statement naming exactly the types.wit members they need: `use types.{cargo, booking, route-spec, itinerary, cargo-error}` in `bookings.wit`, a different, overlapping subset in `handling.wit`. That explicit import list is doing real work. A reader auditing `bookings.wit` alone can see every type its four functions touch without opening `types.wit` and scanning the whole file for what might be relevant; the `use` clause is the complete list.

`booking` then declares the shipment lifecycle in four functions, each returning `result<_, cargo-error>` in some form: `book-cargo` takes a `route-spec` and a weight and returns a `booking`; `request-possible-routes` takes a booking ID and returns a `list<itinerary>`; `assign-route` commits one itinerary to a booking; `get-cargo` looks a cargo up by tracking ID. `handling` adds `register-handling-event` and `list-handling-events` alongside the `cargo-tracker` resource above. Read those six function signatures and the `cargo-tracker` resource together, and you have the complete surface area either language's implementation has to satisfy, before either implementation exists.

## Worlds: the same interfaces, read in one direction

A world is WIT's answer to a question none of the interfaces above can answer on their own: for a given component, which of these interfaces does it provide, and which does it need? `world.wit` declares exactly two, and they name opposite answers over the identical three interfaces:

```wit
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

`cargo` is the provider side. A Rust or Go component that implements the booking and handling logic, the thing that stores a booking or appends a handling event, targets `cargo` and exports all three interfaces, meaning a host or another component can call into it. `cargo-consumer` is the caller side: a component that needs to book cargo or read handling history without implementing that logic itself targets `cargo-consumer` and imports the same three interfaces, meaning it declares a dependency a composition step has to satisfy before the component can run at all.

{% include excalidraw.html file="03-world-imports-vs-exports" alt="The same three interfaces, types, booking, and handling, feeding into world cargo as exports on the left and into world cargo-consumer as imports on the right, with a dashed bidirectional arrow between the two worlds labeled same shape, opposite direction." caption="Figure 3.2: a world names no new types; it only states which direction each interface faces." %}

A world introduces no new type, no new function, nothing `types.wit`, `bookings.wit`, and `handling.wit` did not already declare. A world is a direction, applied to interfaces that already exist, which is exactly why one package can define two worlds without duplicating a single record or function signature. `cargo-component` targeting `cargo` and a wasmtime host targeting `cargo-consumer` both read from the same files; neither needs its own copy of what `money` or `cargo-error` means.

That symmetry is the thing a component toolchain checks for you: if a provider component built against `cargo` exports `booking`'s `book-cargo` function with the exact signature `func(spec: route-spec, weight-kg: f64) -> result<booking, cargo-error>`, and a consumer component built against `cargo-consumer` imports that same signature, the two satisfy each other by construction. There is no serialization mismatch to debug at runtime because the match was checked against the same WIT source on both sides before either component was built.

## Composing components

A single component built against `cargo-consumer` cannot run on its own: its imports are unmet obligations, not optional conveniences, and a runtime refuses to instantiate a component with an import nothing satisfies. Composition is the step that closes that gap, wiring one component's export to another component's matching import so the pair can run together as if they were one unit.

{% include excalidraw.html file="03-component-composition" alt="A component named cargo-service.wasm built against world cargo on the left, exporting booking and handling, wired by a composed-component step to a component named gateway.wasm on the right built against world cargo-consumer, importing the same two interfaces; a note states composition links by interface identifier, not by source language." caption="Figure 3.3: composing a provider's export to a consumer's import: the WIT identifiers match, the source languages don't have to." %}

Say a `cargo-service.wasm` component implements the `cargo` world, built in Rust, and a `gateway.wasm` component implements `cargo-consumer`, built in Go. Composition matches `gateway.wasm`'s imported `booking` interface against `cargo-service.wasm`'s exported `booking` interface by the package and interface identifier they share, `patterncatalyst:cargo@0.1.0/booking`, not by anything to do with either component's source language or toolchain. A composed pair behaves, from a host's perspective, as one component with no unmet imports left, and a Go gateway composed against a Rust-built cargo service is exactly as valid as composing two components from the same language, because the WIT identifiers, not the source, are what composition checks. That cross-language property is the Component Model's headline claim and the reason this site builds the same domain twice, once in Rust and once in Go, against the identical WIT package: the Rust and Go component builds produce two components that can be composed against each other's worlds, in either direction, without either implementation knowing or caring what language produced the other side.

## From WIT to bindings to a component

Neither Rust nor Go understands WIT directly; each toolchain runs a generation step that turns the WIT world a component targets into source the language does understand, before any domain logic gets written.

{% include excalidraw.html file="03-wit-bindings-pipeline" alt="contracts/wit/ feeding two parallel paths: cargo-component generating a Rust binding crate on the left, and wasm-tools plus wit-bindgen-go generating a Go binding package on the right, each converging into a .wasm component implementing world cargo." caption="Figure 3.4: one WIT source, two independent toolchains, each producing the trait or interface its own language's code implements." %}

On the Rust side, `cargo-component` reads the WIT world a crate targets and generates a trait, matching the interface's functions one for one, that the crate's code implements; the generated code also handles lowering a Rust `Result<Booking, CargoError>` into the WIT `result<booking, cargo-error>` the boundary expects, so the domain code writes ordinary Rust against ordinary Rust types. On the Go side, `wasm-tools` together with `wit-bindgen-go` play the same role, generating a Go interface and the supporting types a package implements, with the same lowering handled by generated code rather than hand-written marshaling. The Rust and Go component builds run both toolchains against this exact package and show the generated output directly; this chapter's job is only to name where that output comes from and why it is generated rather than hand-written: a hand-maintained binding drifts from its WIT source the first time either changes without the other, and a generated one cannot, because it is produced fresh from the file every build.

## The package, resolved

`wasm-tools`, the Bytecode Alliance's reference tool for inspecting and manipulating WIT and components, can read an entire WIT package directory and print its fully resolved form, every `use` followed and every interface shown in one coherent order:

```
$ wasm-tools component wit contracts/wit
```

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

  // ... cargo, route-spec, handling-event-type, handling-event,
  // routing-status, booking, transport-status, leg, itinerary ...

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
  request-possible-routes: func(booking-id: string) -> result<list<itinerary>, cargo-error>;
  assign-route: func(booking-id: string, itinerary: itinerary) -> result<booking, cargo-error>;
  get-cargo: func(tracking-id: string) -> result<cargo, cargo-error>;
}

interface handling {
  use types.{handling-event, handling-event-type, location, transport-status, cargo-error};

  resource cargo-tracker {
    constructor(tracking-id: string);
    tracking-id: func() -> string;
    current-status: func() -> transport-status;
    history: func() -> list<handling-event>;
  }

  register-handling-event: func(cargo-id: string, event-type: handling-event-type, location: location, voyage-id: string, recorded-at: string) -> result<_, cargo-error>;
  list-handling-events: func(cargo-id: string) -> result<list<handling-event>, cargo-error>;
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

This output is what every binding generator consumes: not the four `.wit` files as separately authored, but this one resolved view with every `use` already followed. Running the command against `contracts/wit` yourself is the fastest way to confirm a change you make to one file lands correctly everywhere that file's types are used; a typo in a `use` clause or a renamed record field surfaces here as a resolution error before it ever reaches a language-specific toolchain.

## WIT versus the raw module

Tying this back to the core module's ground floor: a core WebAssembly module has no concept of a record, an enum, a result, or a resource; its export table is a flat list of functions typed only in `i32`/`i64`/`f32`/`f64`, plus memory and table references. Every one of this chapter's `cargo` and `cargo-consumer` worlds compiles down, eventually, to one or more core modules wired together by component-level machinery that lowers a `booking` record into linear memory on one side of a call and lifts it back into a `booking` value on the other. The Component Model does not replace the core module format; it layers a typed, interface-oriented boundary on top of it, generating the lowering and lifting code so that neither Rust nor Go source has to hand-write it. WIT is the vocabulary that boundary speaks, and this chapter's job was to read that vocabulary against a real domain before the chapters ahead write code against it.

The Component Model is not a finished, versioned 1.0 specification as of this writing in late 2026. It is moving through the W3C WebAssembly Community Group's phase process, with core pieces, the binary component format, WIT itself, and the canonical ABI that defines lowering and lifting, each at different points of stabilization. That status does not make today's `patterncatalyst:cargo@0.1.0` package fragile or provisional in practice: `wasm-tools`, `cargo-component`, and `wit-bindgen-go` all implement the same canonical ABI version this package targets, and a WIT file written today reads the same way across every tool in this book's toolchain. It does mean a future, broader revision of the Component Model could add vocabulary this chapter does not cover, streams and futures for asynchronous interfaces chief among the candidates, without retroactively changing anything this package already declares.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>This package splits one WIT package into three interfaces rather than declaring every record and function inside a single <code>interface</code> block, and binds those interfaces into two worlds rather than one. Both choices follow the same rule: split along a boundary that something outside the WIT file already needs to reason about separately. <code>types</code> stands alone because every function in both <code>booking</code> and <code>handling</code> needs the same vocabulary, and a shared vocabulary duplicated into two interfaces would drift the first time one changed without the other. <code>booking</code> and <code>handling</code> stay separate from each other because they represent two different components' worth of responsibility in a larger system, the booking workflow and the tracking workflow, even though this site's early chapters implement both inside one component for simplicity; keeping them as separate interfaces now means a later split into two actual components costs a redeployment, not a WIT rewrite. The two-world split follows the same logic at a coarser grain: <code>cargo</code> and <code>cargo-consumer</code> exist because this domain has a real provider side and a real caller side, and a single world that exported some interfaces while importing others would hide which direction a given component commits to. A smaller domain with one component that both implements and calls its own interfaces would not need a second world at all; this one needs the second world because composing two separately built components depends on exactly this split.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model and WIT covered as the foundation server-side Wasm tooling builds on.
- Shashank Jain, *WebAssembly for Cloud* (Apress): component composition and cross-language interoperability in cloud deployments.
- [WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): the canonical reference for worlds, interfaces, and the canonical ABI this chapter's lowering and lifting claims rest on.
- [WIT (Wasm Interface Type) specification](https://component-model.bytecodealliance.org/design/wit.html): the full grammar for records, enums, variants, resources, and worlds this chapter walked against a real package.

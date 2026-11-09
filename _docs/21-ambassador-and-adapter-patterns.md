---
title: "Ambassador and Adapter Patterns with Wasm"
order: 21
part: "Deploying to Kubernetes"
description: "An adapter that round-trips bookings through a legacy request shape and an ambassador that reaches its dependency only through an explicit grant, each deployed on minikube or CRC where the platform allows it."
duration: "22 min read"
---

## Learning objectives

By the end of this chapter you can:

- Write an adapter interposer that round-trips the canonical `book-cargo` through a legacy request shape and also exports that shape for legacy callers.
- Find the translation functions and the `conv` module in `adapter/src/lib.rs`.
- Explain why the adapter returns the exact cargo JSON on minikube and the provider's 404 on CRC for the same valid id.
- State the ambassador's defining property, an outbound call reached only through an explicit grant, and show it with a 404-versus-5xx link pair on CRC and a local `wasmtime run -S inherit-network` run.
- Decide between an adapter and an ambassador, and recognize a pattern that a platform can express in only one place.

## Why this matters

A filter that polices requests is one interposer. Two more solve different problems on the same cargo provider and HTTP front door, with `patterncatalyst:cargo` still untouched in `contracts/wit/`.

An **adapter** normalizes a non-conforming interface so a legacy caller can drive a modern provider without either side changing. An **ambassador** represents an outbound dependency to the service that calls it, so the caller never has to know the dependency is flaky, slow or reached over a network. The ambassador here is the `wasi:sockets` component with backoff and jitter, interposed in front of a service instead of run standalone.

Both are Brendan Burns' multi-container Pod patterns restated at the component level. The adapter inherits the state finding from build-time composition versus runtime links: a valid id returns 200 when composed and 404 when linked. The ambassador adds a second difference. The containerd shim exposes no way to grant a component outbound network access, so the ambassador can run as a cluster workload only on CRC; minikube's evidence is a local run of the same component.

{% include excalidraw.html file="21-adapter-shape-translation" alt="Two bands. Top, minikube: the http-rust front door, the cargo-adapter interposer and the cargo provider are composed with two wac plug steps into one app-adapted.wasm in a single Pod; book-cargo round-trips canonical to legacy and back inside one instance and the exact cargo JSON returns. Bottom, CRC: the same three components are wired by wadm links over wRPC; the round-trip still runs, but book-cargo and get-cargo land on different fresh instances, so a valid id returns the provider's 404." caption="Figure 21.1: The adapter on two substrates: the shape round-trip is lossless on both, but the valid-id state problem appears only on CRC." %}

## Pattern: Adapter

### The problem

A legacy caller sends flat UN/LOCODE strings, renamed fields and a service level that the canonical model has no concept of. The provider speaks the canonical `route-spec`. Rewriting either side for a shape that only one side uses spreads the old contract through the new code.

### The solution

**An Adapter translates one interface shape into another at the boundary, so caller and provider keep their own contracts.**

### How Rust and Go model it

`adapter/wit/world.wit` declares a `legacy` interface next to the same import-and-export symmetry used by the sidecar filter:

```wit
interface legacy {
    use patterncatalyst:cargo/types@0.1.0.{booking, cargo-error};

    /// Legacy service tiers. The adapter maps these onto the canonical model,
    /// which has no service-level concept (the field is translation-only).
    enum legacy-service-level {
        economy,
        priority,
    }

    /// The legacy booking request shape (flat strings, renamed fields, an extra
    /// enum). Deliberately NOT the canonical `route-spec`.
    record legacy-booking-request {
        origin-code: string,
        dest-code: string,
        cargo-weight: f64,
        needed-by: string,
        service-level: legacy-service-level,
    }

    /// Book a shipment from the legacy request shape. Translates to the canonical
    /// contract and delegates to the real provider.
    book-legacy: func(req: legacy-booking-request) -> result<booking, cargo-error>;
}
```

```wit
world cargo-adapter {
    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;

    export patterncatalyst:cargo/types@0.1.0;
    export patterncatalyst:cargo/booking@0.1.0;
    export patterncatalyst:cargo/handling@0.1.0;

    export legacy;
}
```

`patterncatalyst:cargo` is a path dependency, as for the filter. A world that imports and exports the same package gives `wit-bindgen` two Rust type trees, `up` (import side) and `dn` (export side), so the adapter has the same field-by-field `conv` module as the filter: `location_up`/`location_dn`, `route_spec_up`, `booking_dn`, `itinerary_up`/`itinerary_dn`, `err_dn` and a `match` per enum. Budget for it whenever a world declares a symmetric import and export.

The translation is two functions. `to_legacy` flattens a `RouteSpec` and picks a default service level:

```rust
fn to_legacy(spec: &RouteSpec, weight_kg: f64) -> LegacyBookingRequest {
    LegacyBookingRequest {
        origin_code: spec.origin.unlocode.clone(),
        dest_code: spec.destination.unlocode.clone(),
        cargo_weight: weight_kg,
        needed_by: spec.arrival_deadline.clone(),
        service_level: LegacyServiceLevel::Economy,
    }
}
```

`from_legacy` re-inflates the flat codes through a lookup that mirrors the front door's own name and country mapping for the two known codes, falling back to `(code, "")`:

```rust
fn location_for(unlocode: &str) -> Location {
    let (name, country) = match unlocode {
        "USNYC" => ("New York", "US"),
        "DEHAM" => ("Hamburg", "DE"),
        other => (other, ""),
    };
    Location {
        unlocode: unlocode.to_string(),
        name: name.to_string(),
        country: country.to_string(),
    }
}
```

```rust
fn from_legacy(req: &LegacyBookingRequest) -> (RouteSpec, f64) {
    let spec = RouteSpec {
        origin: location_for(&req.origin_code),
        destination: location_for(&req.dest_code),
        arrival_deadline: req.needed_by.clone(),
    };
    (spec, req.cargo_weight)
}
```

The canonical `book_cargo` round-trips every request through both functions before it calls the provider. For every field the cargo JSON surfaces, the round trip is lossless, so the provider's answer is the same as for the original request:

```rust
    fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
        // Round-trip the canonical request through the legacy shape and back,
        // then call the real provider with the re-inflated canonical request.
        let legacy = to_legacy(&spec, weight_kg);
        log(&format!(
            "book-cargo translate canonical -> legacy: origin_code={} dest_code={} cargo_weight={} service_level={:?}",
            legacy.origin_code, legacy.dest_code, legacy.cargo_weight, legacy.service_level
        ));
        let (round_spec, round_weight) = from_legacy(&legacy);
        log(&format!(
            "book-cargo translate legacy -> canonical: origin={} destination={} weight_kg={}",
            round_spec.origin.unlocode, round_spec.destination.unlocode, round_weight
        ));
        up_booking::book_cargo(&conv::route_spec_up(round_spec), round_weight)
            .map(conv::booking_dn)
            .map_err(conv::err_dn)
    }
```

The `legacy` interface's `book-legacy` export skips the first half and calls `from_legacy` directly, so a legacy-only caller drives the same provider through the same conversion code.

### Composed on minikube

`adapter/build.sh` uses the same two-step chain as the filter, provider into adapter and the result into the front door:

```bash
wac plug --plug "$PROVIDER" "$ADAPTER" -o "$TMP_PA"
wac plug --plug "$TMP_PA" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"
```

Deployed behind the `wasmtime` `RuntimeClass` and a `nip.io` Ingress as `cargo-http-adapted:minikube`, `/cargo/CARGO-USNYC-DEHAM` returns the exact cargo JSON that the plain deployment and the filtered composition return, and `/cargo/NOPE` returns the provider's 404. An adapter should be invisible when it succeeds.

### Linked on CRC

`openshift/wadm-adapted.yaml` deploys the same three-component link graph as the filter with the adapter in the interposer slot: `httpserver-adapted` to `cargo-adapted`, `cargo-adapted` to `cargo-adapter` (`booking`), and `cargo-adapter` to `cargo-provider-a` (`booking`, `handling`). The translation runs across the link exactly as it does in one process. Through the edge-TLS Route, `/cargo/NOPE` returns the provider's 404, and the valid `CARGO-USNYC-DEHAM` returns `{"error":"no cargo CARGO-USNYC-DEHAM"}` with status 404.

The cause is the provider's memory lifecycle. The front door calls `book-cargo` and then `get-cargo` as two wRPC calls, wasmCloud gives each invocation a fresh instance, and the booking that the first call wrote into its `thread_local` map is gone before the second runs. The adapter's translation is not at fault; whether provider state survives between two linked calls is the substrate property the sidecar filter already isolated.

## Pattern: Ambassador

### The problem

A service's own code would otherwise need retry loops, backoff and jitter for a dependency that fails, and an outbound network reach that every component receives by default.

### The solution

**An Ambassador owns a service's outbound calls to a dependency, retrying with backoff and jitter, and reaches it only through an explicit grant.**

### How Rust and Go model it

`ambassador/` builds nothing new. `ambassador/build.sh` builds `examples/part3-interfaces/sockets-rust`, the `wasi:sockets` command component, unedited, and copies it to `ambassador.wasm`. On `connection-refused` it backs off with `base * 2^min(attempt-1, 5)` plus up to 50% jitter from `wasi:random`, for a bounded number of attempts. It becomes an ambassador by where it is interposed and by the capability that gates its outbound reach.

{% include excalidraw.html file="21-ambassador-egress-grant" alt="Two bands. Top, CRC: the front door cargo-ambassador reaches cargo-provider-am over a wadm link and GET /cargo/NOPE returns the provider's own 404; with the link removed (cargo-ambassador-nogrant) the front door's cargo import is unsatisfied, the Service gets no endpoints and the Route returns a 5xx. Bottom, minikube: the containerd shim has no outbound-network setting, so the evidence is a local wasmtime run of sockets-rust: without the grant a connect is denied with access-denied on the first attempt, with the grant against a dead port four connection-refused attempts back off with growing jitter, and against a live listener it connects on the first attempt." caption="Figure 21.2: The ambassador's outbound call exists only through a grant: a 404 versus 5xx link contrast on CRC, and a local wasmtime capability and backoff run for minikube." %}

The local run covers three cases against `wasmtime run -S inherit-network`:

| Case | Grant | Target | Result |
| --- | --- | --- | --- |
| A | yes | dead port | four `connection-refused` attempts with growing backoff, then gives up |
| B | yes | live listener | connects on attempt 1, exit 0 |
| C | no | dead port | `access-denied` on attempt 1, no retry |

WASI's exit model is success or failure only, and `wasmtime` collapses any non-zero guest exit to `1`. A and C both exit `1`, so the exit code cannot tell "retried and gave up" from "denied before the first packet". Read the transcript instead: A prints four `attempt N/4 failed` lines with `connection-refused`, and C prints `access-denied` on attempt 1 and never reaches `attempt 2/4`. A capability denial that retried would be the one bug this component must not have. A bare exit code is evidence of almost nothing on a WASI component.

### On CRC: egress is a grant

`openshift/wadm-ambassador.yaml` deploys a front door and a provider linked by exactly one `link` trait; there is no interposer, and the front door's cargo call reaches the provider directly:

```yaml
    - name: cargo-ambassador
      type: component
      properties:
        image: __FRONTDOOR_REF__
      traits:
        - type: daemonscaler
          properties:
            replicas: 1
        # THE runtime-granted outbound link: front door's cargo IMPORT -> provider.
        - type: link
          properties:
            target: cargo-provider-am
            namespace: patterncatalyst
            package: cargo
            interfaces:
              - booking
```

On the lattice that link is the grant: an outbound call between components resolves only if the link exists at deploy time, the analog of `-S inherit-network` for a single process. Through the CA-verified Route, `/cargo/NOPE` returns the provider's own 404, which only a front door that reached the provider could produce.

`wadm-ambassador-nogrant.yaml` is the negative control: the same front door and provider with the one `link` removed. The front door's cargo import is unsatisfiable, so the host never admits it as a healthy backend, the operator-created Service gets no endpoints, and the Route answers with a router 5xx (500 in the captured run). One `link` trait is the only difference between 404 and 5xx.

The two denials differ in kind. In `wasi:sockets` the denial is an `access-denied` error code the component can read and log. On the lattice it happens a layer up, as a component the platform never admits, so no component code runs to report it. Authority comes only from what the host or runtime explicitly resolves, never from an ambient default.

### Why minikube cannot run it live

The shim runs one component behind a fixed `:8080` server and exposes no flag, environment variable or manifest field that grants a Pod outbound network access. The pattern cannot be expressed as a minikube Pod on that path. The minikube evidence is the local run above, the same kind of runtime gap TinyGo has for `wasi:sockets`.

## When not to use it

- **A runtime-linked adapter in front of a provider that keeps state between calls in one request.** The translation still runs, but the valid id returns 404 on CRC; compose in-process instead.
- **A platform without an outbound grant mechanism.** Name the missing mechanism and prove the pattern where the platform allows it; do not manufacture a deployment to make coverage look symmetric.

> **Decision**
>
> Use an adapter when both sides agree on the destination but disagree on the request shape: translate at the boundary in a component that imports and re-exports the canonical interface, and never rewrite the provider or the caller for a shape only one side still uses. Compose with `wac plug` when state must survive across calls in one request, and link at runtime when independent lifecycle matters more. Use an ambassador when a service would otherwise need to know its dependency is flaky: keep the retry loop inside it and gate its outbound reach with an explicit grant, a host capability for a process or a lattice link for a distributed deployment.

> **🤖 Explore with your agent**
>
> "In examples/part5-kubernetes/adapter/src/lib.rs, add a `priority` service level path: map a canonical booking above a weight threshold to `LegacyServiceLevel::Priority` in `to_legacy`, keeping `book_cargo` lossless for the fields the cargo JSON surfaces. Then review ambassador/build.sh and wadm-ambassador.yaml and tell me which outbound grant each cluster would need for a new dependency, using the rule that an outbound call must be reached through an explicit grant."
>
> Check: run `examples/part5-kubernetes/adapter/build.sh`; it must still compose `app-adapted.wasm` and pass `wasm-tools validate`.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s && ./verify-interposed-minikube.sh
cd ../ambassador && ./build.sh
```

The first script builds and deploys the filtered and adapted compositions as sibling Pods behind the `wasmtime` shim and `nip.io` Ingress hosts, and prints `PASS` when the adapter returns the exact cargo JSON and an unknown id returns 404. The second builds `ambassador.wasm` and runs the three local cases. On CRC, run `openshift/deploy-interposed.sh` and then `openshift/verify-interposed-crc.sh`: the adapter's valid id returns 404, the ambassador returns 404 through the granted link, and 5xx when the link is removed.

Experiments:

- After `build.sh`, run `wasmtime run -S inherit-network ambassador.wasm 34571 6 100` (port, attempts, base milliseconds): six `connection-refused` attempts with the backoff doubling from about 100ms. Drop `-S inherit-network`: `access-denied` on attempt 1 and no retry.
- Deploy `wadm-ambassador-nogrant.yaml` on CRC: the Route answers 5xx instead of 404.

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the Ambassador and Adapter patterns.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): Component Model composition and the import-and-export symmetry an interposer relies on.
- *Cloud Native Design Patterns*, "Failure Modes": the retry-with-backoff-and-jitter catalog the ambassador borrows.
- [wasmCloud components](https://wasmcloud.com/docs/overview/workloads/components/): the per-invocation statelessness behind the adapter's 404 on CRC.
- The execution model: the capability-based security model that the 404-versus-5xx contrast shows at the lattice-link layer.
- Networking, reconnect and resilience: the `sockets-rust` component, backoff formula and `access-denied` versus `connection-refused`.
- Wasm on Kubernetes and deploying on minikube: the containerd shim and its fixed listener.
- Deploying on OpenShift Local (CRC) and Wasm as a sidecar: the wasmCloud operator, links and the interposition structure.

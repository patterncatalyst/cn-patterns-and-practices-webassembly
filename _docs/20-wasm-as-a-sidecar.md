---
title: "Wasm as a Sidecar"
order: 20
part: "Deploying to Kubernetes"
description: "A Wasm component that imports and exports the same interfaces sits between a provider and its HTTP front door to enforce an embargo policy, composed at build time on minikube or linked at runtime on CRC."
duration: "18 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why an interposer both imports and exports the same `patterncatalyst:cargo` interfaces.
- Bridge the two Rust type trees `wit-bindgen` generates for such a world with a `conv` module.
- Compose provider, filter and front door with `wac plug`, and wire the same three components with `wadm` link traits.
- Predict why one valid tracking id returns 200 on minikube and 404 on CRC.
- Choose between compile-time composition and a runtime link for a cross-cutting concern.

## Why this matters

A cross-cutting concern such as a destination embargo or per-call logging should not require editing the provider or the front door. The Part 2 provider exports `types`, `booking` and `handling`, and the Part 3 HTTP front door imports them. A component that imports those three interfaces and exports them again looks like the provider to the front door and like an ordinary caller to the provider, so it can be spliced between them.

That is the Kubernetes sidecar idea at a different level. A container sidecar such as an Envoy proxy sits in the Pod and handles raw network bytes. A component interposer handles typed values (`RouteSpec`, `Booking`, `CargoError`), so the WIT contract has already validated the shape before the policy code runs; a malformed body or unexpected header never reaches it.

The same interposer deploys two ways, and the difference between them is the main lesson: build-time composition shares one instance per request, while runtime links give every call a fresh instance.

{% include excalidraw.html file="20-interposition-chain" alt="Two bands. Top, minikube: the provider, the sidecar-filter interposer and the http-rust front door are composed at build time with two wac plug steps into one app-filtered.wasm in a single Pod behind the containerd wasmtime shim, so one component instance serves both book-cargo and get-cargo. Bottom, CRC: the same three pieces run as three wasmCloud components wired by wadm link traits over wRPC, and each invocation gets a fresh instance, so the provider's in-memory map does not survive between linked calls." caption="Figure 20.1: The same interposer in two forms: wac plug composition with one shared instance on minikube, wadm runtime links with independent per-call instances on CRC." %}

## Pattern: Sidecar

### The problem

Policy and logging belong in every request path, but the provider and the front door are separate components owned elsewhere. Editing either one for each new concern couples them to concerns they should not know about.

Interposing at HTTP does not work in WASI 0.2. `incoming-handler.handle` takes an `incoming-request` and a `response-outparam`, both host resources that a component cannot construct. An HTTP-layer interposer would have to build a new request to forward, and no construction path exists; the composition issue is tracked in [`bytecodealliance/wac#149`](https://github.com/bytecodealliance/wac/issues/149). The cargo interfaces take and return plain WIT records and variants, which any component can build and pass along.

### The solution

**A Sidecar is a component placed transparently in the request path, speaking the same contract on both sides, to add policy and observability the primary component knows nothing about.**

Use compile-time composition or a runtime link depending on whether a request's calls need shared in-process state (see the decision below).

### How Rust and Go model it

The world is local to `sidecar-filter/`; `patterncatalyst:cargo` is a path dependency, so `contracts/wit/` is untouched:

```wit
world cargo-filter {
    import patterncatalyst:cargo/types@0.1.0;
    import patterncatalyst:cargo/booking@0.1.0;
    import patterncatalyst:cargo/handling@0.1.0;

    export patterncatalyst:cargo/types@0.1.0;
    export patterncatalyst:cargo/booking@0.1.0;
    export patterncatalyst:cargo/handling@0.1.0;
}
```

Three imports and the identical three exports, same package, same version: `wac plug` can satisfy the imports from the provider's exports, and the result can itself be plugged into the front door.

The symmetry has a cost in Rust. `wit-bindgen` generates one type tree for the import side and another under `bindings::exports::...` for the export side. `bindings::patterncatalyst::cargo::types::Booking` and `bindings::exports::patterncatalyst::cargo::types::Booking` are different types with the same fields. A `conv` module converts field by field in both directions, with `up` for the provider side and `dn` for the front-door side:

```rust
mod conv {
    use crate::bindings::exports::patterncatalyst::cargo::types as dn;
    use crate::bindings::patterncatalyst::cargo::types as up;

    // --- Location (both directions) ---
    pub fn location_up(l: dn::Location) -> up::Location {
        up::Location {
            unlocode: l.unlocode,
            name: l.name,
            country: l.country,
        }
    }
```

Every record that crosses the filter goes through a converter (`Location`, `Money`, `RouteSpec`, `Booking`, `Cargo`, `Leg`, `Itinerary`, `HandlingEvent`, `CargoError`), and each enum (`HandlingEventType`, `RoutingStatus`, `TransportStatus`) gets a variant-by-variant `match`: eighteen hand-written functions. Nothing generates them, because `wit-bindgen` cannot know two independently generated trees line up. Budget for this module whenever a world declares a symmetric import and export; it is the largest block of mechanical code in the file.

The embargo list is a constant, and `book_cargo` checks it before anything else:

```rust
const EMBARGOED: &[&str] = &["CUHAV", "IRTHR", "KPFNJ"];
```

```rust
    fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
        log(&format!(
            "book-cargo origin={} destination={} weight_kg={}",
            spec.origin.unlocode, spec.destination.unlocode, weight_kg
        ));
        if is_embargoed(&spec.destination.unlocode) {
            log(&format!(
                "POLICY DENY book-cargo: destination {} is under embargo",
                spec.destination.unlocode
            ));
            return Err(CargoError::InvalidLocation(format!(
                "destination {} is under embargo",
                spec.destination.unlocode
            )));
        }
        // Normal destination: delegate unchanged to the real provider.
        up_booking::book_cargo(&conv::route_spec_up(spec), weight_kg)
            .map(conv::booking_dn)
            .map_err(conv::err_dn)
    }
```

A normal destination calls straight through to the provider after conversion; an embargoed one never reaches it. `get_cargo` applies the same check to the destination segment of a `CARGO-{ORIGIN}-{DEST}` tracking id, so a direct lookup is rejected like a booking would be. Every call writes one line to stderr, which is how the filter shows it is in the path.

## minikube: compile-time composition with wac plug

The containerd shim runs one Wasm component per Pod behind a fixed `:8080` listener. It replaces `runc` for the whole Pod, so there is no second container to act as a sidecar. The interposer is spliced in before the image is built, with two `wac plug` steps:

```bash
trap 'rm -f "$TMP_PF"' EXIT
# Step 1: the provider's cargo exports satisfy the filter's cargo imports; the
# result still EXPORTS cargo (the filter's exports).
wac plug --plug "$PROVIDER" "$FILTER" -o "$TMP_PF"
# Step 2: the filtered cargo exports satisfy the http front door's cargo imports.
wac plug --plug "$TMP_PF" "$HTTP" -o "$OUT"
```

The first plug satisfies the filter's imports from the provider and still exports cargo. The second satisfies the front door's imports from that result. `app-filtered.wasm` exports `wasi:http/incoming-handler` and looks like the plain `app.wasm`, apart from its hash and its behavior on an embargoed destination. No upstream crate is forked.

Deployment is the same as the plain app: a `wasmtime` `RuntimeClass`, a Deployment with `command: ["/app.wasm"]`, a Service and an `nginx` Ingress on a `nip.io` host, using the image `cargo-http-filtered:minikube`. Through the Ingress:

| Request | Result |
| --- | --- |
| `/cargo/CARGO-USNYC-DEHAM` | 200 with the exact cargo JSON, identical to the uninterposed deployment |
| `/cargo/CARGO-USNYC-CUHAV` | 400 `destination CUHAV is under embargo`, returned by the filter |
| `/cargo/NOPE` | 404 from the provider |

## CRC: runtime links instead of composition

OpenShift Local runs the wasmCloud operator rather than the raw shim. `openshift/wadm-filtered.yaml` deploys the provider, the filter and the front door as three components, and "the filter sits between them" becomes `link` traits in the `wadm` Application, resolved at deploy time rather than baked into a `.wasm`:

```yaml
    - name: cargo-filter
      type: component
      properties:
        image: __FILTER_REF__
      traits:
        - type: daemonscaler
          properties:
            replicas: 1
        # interposer's cargo IMPORTS -> provider's EXPORTS
        - type: link
          properties:
            target: cargo-provider-f
            namespace: patterncatalyst
            package: cargo
            interfaces:
              - booking
              - handling
```

```yaml
    - name: cargo-filtered
      type: component
      properties:
        image: __FRONTDOOR_REF__
      traits:
        - type: daemonscaler
          properties:
            replicas: 1
        # front door's cargo IMPORT -> interposer's EXPORT (booking only)
        - type: link
          properties:
            target: cargo-filter
            namespace: patterncatalyst
            package: cargo
            interfaces:
              - booking

    # --- the httpserver capability provider -----------------------------------
```

A `link` is declared on the importing side, and `target` names the exporter. The front door's link targets `cargo-filter`, not the provider, so the lattice routes its cargo calls to the interposer; the interposer's own link routes on to the provider. Nothing in the front door changed. The front door's world imports the whole cargo package but only calls `booking` (`types` has no functions and `handling` is never invoked), so its link lists `booking` alone; the filter calls both `booking` and `handling`, so its link lists both. The routing lives in the manifest, resolved by `wadm` and carried over wRPC between hosts.

The resolved graph is `httpserver-filtered` to `cargo-filtered` (`wasi:http/incoming-handler`), `cargo-filtered` to `cargo-filter` (`booking`), and `cargo-filter` to `cargo-provider-f` (`booking`, `handling`). Through the CA-verified edge-TLS Route, the embargoed destination returns the same 400 and an unknown id traverses the whole chain to the provider's 404. The wasmCloud host log shows `cargo-filter: POLICY DENY book-cargo: destination CUHAV is under embargo`, so the decision is made inside the interposer, across the link. Policy and logging travel with the component; only the wiring changed.

## The valid id that returns 404

`GET /cargo/CARGO-USNYC-DEHAM` is a recognized, non-embargoed id. On minikube it returns the cargo JSON. On CRC it returns `{"error":"no cargo CARGO-USNYC-DEHAM"}` with status 404.

The cause is the instance lifecycle, not the wiring. The front door answers a `CARGO-{ORIGIN}-{DEST}` id by calling `book_cargo` and then `get_cargo` on the provider: two calls for one HTTP request. The provider keeps its bookings in process memory:

```rust
thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}
```

In the `wac plug` composite both calls are ordinary function calls into one instance, which shares one linear memory per invocation of the top-level export, so the map `book_cargo` wrote is the map `get_cargo` reads. **wasmCloud components are stateless by design: every invocation gets a fresh instance with reset linear memory.** `book_cargo` writes into instance A, which is then gone; `get_cargo` runs on instance B with an empty map and the provider correctly answers `NotFound`.

{% include excalidraw.html file="20-state-contrast" alt="Side by side for GET /cargo/CARGO-USNYC-DEHAM. On minikube one provider instance serves book-cargo (insert) and get-cargo (get) against the same memory and returns 200. On CRC book-cargo runs on fresh provider instance A and get-cargo on fresh instance B with an empty map, so the provider answers NotFound and the front door returns 404." caption="Figure 20.2: For the same request, one shared instance (minikube) returns 200; two independent fresh instances across a link (CRC) return 404." %}

Any chain that relies on in-process memory surviving between two calls needs the provider composed in-process, or its state kept somewhere that outlives an invocation: a capability provider backed by a key-value store, or a wasmCloud Service workload, which pins one long-lived instance. Neither is built here.

## When not to use it

- **A value that must survive between calls in one request.** Compose in-process, or move the state out of component memory.
- **A concern that must inspect and forward the HTTP request itself.** A component cannot construct an `incoming-request` to pass downstream (`wac#149`), so the interposer works only on the typed cargo interfaces.

> **Decision**
>
> Compose at build time with `wac plug` when the concern shares a request with a stateful provider. Link at runtime when independent lifecycle, independent scaling and swapping policy without rebuilding the provider matter more, and the concern reads its inputs and produces its output without needing anything the provider wrote on a previous call.

> **🤖 Explore with your agent**
>
> "In examples/part5-kubernetes/sidecar-filter/src/lib.rs, add a maximum `weight_kg` check to the `cargo-filter` world's `book_cargo` that returns `CargoError::InvalidBooking` before calling the provider. Then say whether it works unchanged in the `wac plug` composition from `sidecar-filter/build.sh` and in the `openshift/wadm-filtered.yaml` link graph, and whether a call counter in a `thread_local` would, using this rule: in-process state survives between calls only inside one composed instance, and wasmCloud gives every linked invocation a fresh instance."
>
> Check: the weight check needs no state and works on both substrates; the counter resets on every invocation under wadm links. Run `cargo component build --release` in `sidecar-filter/`.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s && ./verify-interposed-minikube.sh
```

The script starts the `part5` minikube profile (docker driver, containerd), builds and loads `app-filtered.wasm` and the adapter composition, installs the `containerd-shim-wasmtime` shim and deploys both behind `nip.io` Ingress hosts. It prints `PASS` when a normal id returns the exact cargo JSON, `CUHAV` returns the filter's 400 and an unknown id returns 404. On CRC, run `openshift/deploy-interposed.sh` then `openshift/verify-interposed-crc.sh`; there the valid id returns 404 by design.

Experiments:

- Add a UN/LOCODE to `EMBARGOED` in `sidecar-filter/src/lib.rs`, re-run `verify-interposed-minikube.sh` (it rebuilds the composition through `sidecar-filter/build.sh`), and request a cargo id with that destination on the filtered host: the filter now answers 400.
- Compare `GET /cargo/CARGO-USNYC-DEHAM` on both clusters: 200 on minikube, 404 on CRC.

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the Sidecar and Ambassador patterns, here at the component level.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): Component Model composition, `wac plug` and shared versus independent instances.
- *Cloud Native Design Patterns*: the Sidecar and Ambassador write-ups.
- [wasmCloud components](https://wasmcloud.com/docs/overview/workloads/components/) and [wasmCloud Services](https://wasmcloud.com/docs/overview/workloads/services/): per-invocation statelessness and the long-lived-instance alternative.
- [`bytecodealliance/wac#149`](https://github.com/bytecodealliance/wac/issues/149): why interposition happens at the cargo interface and not at `wasi:http/incoming-handler`.
- wasmtime and wasmCloud together: the single-process versus lattice trade-off.
- Deploying on minikube: the containerd shim and the plain `app.wasm`.
- Deploying on OpenShift Local (CRC): the wasmCloud operator, host and link model.
- Ambassador and adapter patterns with Wasm: the same structure with a shape adapter and an outbound-resilience ambassador.

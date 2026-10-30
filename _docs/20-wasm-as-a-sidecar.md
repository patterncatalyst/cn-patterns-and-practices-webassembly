---
title: "Wasm as a Sidecar"
order: 20
part: "Deploying to Kubernetes"
description: "A Wasm component interposed between a provider and its HTTP front door to add destination-embargo policy and logging, expressed two ways: compile-time wac plug composition on minikube, runtime wadm links on CRC, plus the one state behavior that tells them apart."
duration: "18 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what makes a component an interposer rather than an ordinary provider: it both imports and exports the identical `patterncatalyst:cargo` interfaces, so it is indistinguishable from the real provider to whatever calls it.
- Read `examples/part5-kubernetes/sidecar-filter/src/lib.rs` and point to the exact lines where the embargo policy short-circuits before the provider is ever called, and the `conv` module that bridges the two Rust type trees `wit-bindgen` generates for a world that both imports and exports the same interface.
- Build and trace the minikube composition (`wac plug` chaining provider -> filter -> front door into one `app-filtered.wasm`) and the CRC composition (three separate wasmCloud components wired by `wadm` link traits), and state which fields in each make the policy fire before the provider sees a request.
- Explain why the identical valid tracking id returns 200 on one substrate and 404 on the other, as a direct consequence of each substrate's linear-memory lifecycle.
- Decide, for a given cross-cutting concern, whether compile-time composition or a runtime link is the right placement, and name the one thing a runtime link does not give you automatically.

## Why this matters

Running a Wasm component on Kubernetes has four distinct deployment paths; the raw containerd shim on minikube and the wasmCloud operator on OpenShift Local are two of them, both already proved live against the identical `app.wasm`, unmodified. This chapter introduces a second component into the request path without touching the first one at all. `patterncatalyst:cargo` already has three canonical interfaces (`types`, `booking`, `handling`) that the Part 2 provider exports and the Part 3 HTTP front door imports. The sidecar-filter interposer built for this chapter imports those same three interfaces and exports them right back out, so from the front door's point of view it looks exactly like the provider, and from the provider's point of view it looks exactly like a normal caller. Nothing about the provider or the front door has to change for a cross-cutting concern, here a destination-embargo policy and per-call logging, to get spliced in between them.

The word "sidecar" in this chapter's title is doing specific work. A conventional Kubernetes sidecar is a second container in the same Pod, usually fronting or wrapping the primary container's network traffic: Envoy terms this a listener filter, a proxy standing between the client and the real workload. This chapter's interposer plays the identical structural role, a separate unit that sits transparently in the path to add policy and observability the primary component doesn't know about, but it does it at the Wasm **component** level, not the **container/network** level. It interposes on a typed value interface (`book-cargo`, `get-cargo`, `register-handling-event`) rather than on raw HTTP bytes, which is a stronger guarantee than a network-layer sidecar gets: a value-level interposer cannot be confused by an unexpected header or a malformed body, because the WIT contract has already validated the shape before the interposer's code ever runs. This chapter builds that interposer once, then deploys it two different ways, compile-time composition on minikube and a runtime-linked lattice on CRC, and the difference between those two substrates turns out to be the most important lesson in the chapter, not a footnote.

{% include excalidraw.html file="20-interposition-chain" alt="Two bands. Top: on minikube, the Part 2 provider, the sidecar-filter interposer, and the Part 3 http-rust front door are composed at build time with two wac plug steps into one app-filtered.wasm running as a single Pod behind the containerd wasmtime shim; one in-process component instance serves both the book-cargo and get-cargo calls for a request, so the shared in-memory HashMap survives between them. Bottom: on CRC, the same three logical pieces run as three separate wasmCloud components wired by wadm link traits over wRPC at deploy time; each component gets a fresh instance per invocation, so the provider's in-memory HashMap does not survive from one linked call to the next." caption="Figure 20.1: the same interposer, two substrate expressions: wac-plug composition (one shared instance) on minikube, wadm runtime links (independent per-call instances) on CRC." %}

## Why interposition happens at the cargo interface, not at HTTP

A natural first instinct is to interpose at the HTTP layer: wrap `wasi:http/incoming-handler` itself, inspect the request, forward or reject it, and let the real handler run underneath. WASI 0.2's `incoming-handler` makes that specific shape awkward in practice. Its `handle` function takes an `incoming-request` and a `response-outparam`, both of which are **non-constructible host resources**: a component cannot manufacture one of these values itself, only receive it from the host that invoked it. An HTTP-layer interposer would need to take the inbound `incoming-request`, construct a *new* one to forward downstream, and that construction path does not exist in the WASI HTTP world today; the composition tooling issue tracking it is [`bytecodealliance/wac#149`](https://github.com/bytecodealliance/wac/issues/149). Interposing at the `patterncatalyst:cargo` value interface sidesteps the problem entirely: `book-cargo`, `get-cargo`, and the handling-event functions all take and return ordinary WIT records and variants (`RouteSpec`, `Booking`, `CargoError`), which any component can construct, inspect, and pass along. The interposer in this chapter sits one layer below HTTP, between the front door and the domain provider, where the values crossing the boundary are plain data instead of host resources.

## The interposer's world: importing and exporting the same interface

`examples/part5-kubernetes/sidecar-filter/wit/world.wit` states the shape directly:

{% raw %}
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
{% endraw %}

This is a local world, defined inside `sidecar-filter/` itself, not an edit to `contracts/wit/`. The repository's contract package stays byte-for-byte pristine, exactly as the rules for composing components and WIT worlds require; `patterncatalyst:cargo` is pulled in as a path dependency, the same technique the gRPC-with-Wasm and networking-and-resilience components use for a component that needs the domain types without owning them. What makes this world an interposer rather than an ordinary component is the symmetry: three imports, the identical three exports, same package, same version. `wac plug` can satisfy the imports from the real provider's exports and, because the filter re-exports the identical interfaces, the result of that plug can itself be plugged into anything that expects the provider, including the HTTP front door that has no idea an interposer is now in the chain.

That symmetry has a cost on the Rust side. `wit-bindgen` generates one Rust module tree for the imported side of a world and a separate tree, nested under `bindings::exports::...`, for the exported side. For most components these never collide, because most components either import or export a given interface, never both. Here they both exist for the same `patterncatalyst:cargo::types` interface, structurally identical, nominally distinct: `bindings::patterncatalyst::cargo::types::Booking` and `bindings::exports::patterncatalyst::cargo::types::Booking` are two different Rust types that happen to have the same fields. `src/lib.rs` handles this with a dedicated `conv` module that converts field-by-field in both directions:

{% raw %}
```rust
mod conv {
    use crate::bindings::exports::patterncatalyst::cargo::types as dn;
    use crate::bindings::patterncatalyst::cargo::types as up;

    pub fn location_up(l: dn::Location) -> up::Location {
        up::Location { unlocode: l.unlocode, name: l.name, country: l.country }
    }
    pub fn location_dn(l: up::Location) -> dn::Location {
        dn::Location { unlocode: l.unlocode, name: l.name, country: l.country }
    }
    // ... booking_dn, cargo_dn, itinerary_up/dn, handling_event_dn, err_dn, ...
}
```
{% endraw %}

`up` names the import-side type tree (the real provider, upstream of the filter), and `dn` names the export-side tree: the front door, downstream of the filter. Every record that crosses the interposer passes through one of these converters: `Location`, `Money`, `RouteSpec`, `Booking`, `Cargo`, `Leg`, `Itinerary`, `HandlingEvent`, `CargoError`, and each enum (`HandlingEventType`, `RoutingStatus`, `TransportStatus`) gets its own `match` translating variant-by-variant. None of this is generic or macro-derived; it is eighteen small hand-written functions, because `wit-bindgen` has no way to know two independently-generated type trees happen to line up field-for-field. Any component that both imports and exports the same package needs this conversion module: budget for it the moment a world declares a symmetric import/export pair, and expect it to be the largest chunk of otherwise-mechanical code in the file.

Inside the `Guest` implementations, the policy itself is a handful of lines. `book_cargo` and `get_cargo` both check the destination UN/LOCODE against a fixed embargo list before doing anything else:

{% raw %}
```rust
const EMBARGOED: &[&str] = &["CUHAV", "IRTHR", "KPFNJ"];

fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
    if is_embargoed(&spec.destination.unlocode) {
        log(&format!("POLICY DENY book-cargo: destination {} is under embargo", spec.destination.unlocode));
        return Err(CargoError::InvalidLocation(format!(
            "destination {} is under embargo", spec.destination.unlocode
        )));
    }
    up_booking::book_cargo(&conv::route_spec_up(spec), weight_kg)
        .map(conv::booking_dn)
        .map_err(conv::err_dn)
}
```
{% endraw %}

A normal destination calls straight through to `up_booking::book_cargo` (the real provider), converting the request on the way in and the response on the way out; an embargoed one never reaches the provider at all. `get_cargo` applies the same check against the destination segment of the `CARGO-{ORIGIN}-{DEST}` tracking id shape, so a direct lookup of an already-booked embargoed cargo is rejected the same way a fresh booking attempt would be. Every call, policy hit or not, writes one line to stderr via a small `log` helper: the per-call logging half of the interposer's job, and the mechanism that later proves, on CRC, that the filter is in the request path rather than bypassed.

## minikube: compile-time composition with wac plug

The containerd shim proved live on minikube hosts exactly one Wasm component per Pod behind a fixed `:8080` listener; there is no mechanism on that path for a second component to ride along as a Kubernetes-level sidecar container, because the shim replaces `runc` for the whole Pod, not for one container inside it. `examples/part5-kubernetes/sidecar-filter/build.sh` applies the same component-composition approach already established for composing components and WIT worlds generally: two `wac plug` steps splice the interposer into the exact Part 2/Part 3 recipe at build time, before the image is ever built.

{% raw %}
```bash
wac plug --plug "$PROVIDER" "$FILTER" -o "$TMP_PF"
wac plug --plug "$TMP_PF" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"
```
{% endraw %}

The first `wac plug` satisfies the filter's three cargo imports from the provider's three cargo exports; the result still exports cargo (the filter's own exports), so it can be plugged again. The second `wac plug` satisfies the HTTP front door's cargo imports from that filtered result. `app-filtered.wasm` is the output: one component graph, `wasi:http/incoming-handler` exported at the top, nothing visible to the outside that distinguishes it from the plain `app.wasm` already deployed on minikube, except its sha256 and its behavior on an embargoed destination. None of the three upstream crates, provider, filter, http-rust, is forked or edited; the build script rebuilds each with its own `cargo component build --release` and composes the results.

Deployment follows the identical shape as `k8s/base`: a `wasmtime` `RuntimeClass`, a Deployment with `command: ["/app.wasm"]`, a Service, and an `nginx` Ingress on a `nip.io` host. `k8s/interposed/base/deployment-filtered.yaml` and `ingress-filtered.yaml` are byte-for-byte the same pattern already walked through for the minikube deployment, pointed at `cargo-http-filtered:minikube` instead of the plain image. `k8s/evidence/2026-10-21/12-interposed-pods.txt` shows the Pod running with the `wasmtime` `RuntimeClass` on the `part5` node, side by side with the shape-adapter's composed Pod built for the ambassador and adapter patterns:

{% raw %}
```
$ kubectl get pods -n part5-kubernetes            # IP + trailing columns trimmed for width
NAME                                   READY   STATUS    RESTARTS   AGE   NODE
cargo-http-adapted-5fc7597d97-ttzrr    1/1     Running   0          9s    part5
cargo-http-filtered-5cb7b64795-zwg8s   1/1     Running   0          9s    part5
$ kubectl describe pod ... | grep 'Runtime Class Name'
Runtime Class Name:  wasmtime                      # both pods
```
{% endraw %}

`13-filtered-http.txt` is the live curl transcript through the real Ingress path: `host -> ingress-nginx -> Service cargo-http-filtered:8080 -> Pod -> shim -> app-filtered.wasm`:

{% raw %}
```
$ curl -s http://cargo-filtered.192.168.49.2.nip.io/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -w %{http_code} http://cargo-filtered.192.168.49.2.nip.io/cargo/CARGO-USNYC-CUHAV
body: {"error":"destination CUHAV is under embargo"}
code: 400
$ curl -s -o /dev/null -w %{http_code} http://cargo-filtered.192.168.49.2.nip.io/cargo/NOPE
404
```
{% endraw %}

A normal destination (`DEHAM`, Hamburg) returns the exact cargo JSON already proved on minikube for the plain `app.wasm`; the embargoed destination (`CUHAV`, Havana) is rejected with the filter's own 400 before the provider is involved; an unrecognized id falls through to the provider's own 404. The interposer has added exactly the behavior it was supposed to add, and nothing else: the normal path is byte-for-byte identical to the uninterposed deployment.

## CRC: runtime links instead of compile-time composition

OpenShift Local runs the wasmCloud operator, not the raw shim, for the same `restricted-v2` constraints that already shaped the CRC deployment. That substrate change turns out to change more than the deployment mechanics: it changes how the interposer is wired in at all. `examples/part5-kubernetes/openshift/wadm-filtered.yaml` deploys the provider, the filter, and the front door as **three separate wasmCloud components**, and the policy of "the filter sits between provider and front door" is expressed as `link` traits in the `wadm` Application manifest, evaluated when the application is deployed to the lattice, not baked into any one `.wasm` file at build time:

{% raw %}
```yaml
- name: cargo-filter
  type: component
  properties:
    image: __FILTER_REF__
  traits:
    - type: link
      properties:
        target: cargo-provider-f
        namespace: patterncatalyst
        package: cargo
        interfaces: [booking, handling]

- name: cargo-filtered
  type: component
  properties:
    image: __FRONTDOOR_REF__
  traits:
    - type: link
      properties:
        target: cargo-filter
        namespace: patterncatalyst
        package: cargo
        interfaces: [booking]
```
{% endraw %}

A `link` trait is declared on the source (the component doing the importing), and `target` names the exporter it calls. The front door's link names `cargo-filter` as its target for `booking`, not `cargo-provider-f`: at deploy time, the lattice is told to route the front door's cargo calls to the interposer, and the interposer's own link in turn routes to the real provider. Nothing in the front door's compiled component changed to make this happen; the routing lives entirely in the manifest, resolved by `wadm` and carried over wRPC between hosts. The front door's world imports the full cargo package, but it only ever *calls* `booking` (the type-only `types` interface has no functions, and `handling` is never invoked), so only `booking` is linked and its link lists `booking` alone, while the interposer's link to the provider lists both, because the interposer itself calls both.

`evidence/2026-10-21/12-interposed-links.txt` records the resolved graph exactly as deployed:

{% raw %}
```
cargo-filtered (ch20):
  httpserver-filtered --wasi:http/incoming-handler--> cargo-filtered (front door)
  cargo-filtered      --patterncatalyst:cargo/booking--> cargo-filter (interposer)
  cargo-filter        --patterncatalyst:cargo/booking,handling--> cargo-provider-f
```
{% endraw %}

`14-filtered-http.txt` is the CA-verified curl transcript through the real edge-TLS Route, never `-k`, never a port-forward:

{% raw %}
```
$ curl -w ' [%{http_code}]' https://cargo-filtered-wasmcloud.apps-crc.testing/cargo/CARGO-USNYC-CUHAV
{"error":"destination CUHAV is under embargo"} [400]
$ curl -w ' [%{http_code}]' https://cargo-filtered-wasmcloud.apps-crc.testing/cargo/NOPE
{"error":"no cargo NOPE"} [404]
```
{% endraw %}

The embargo still fires, 400 on the same destination the minikube run rejected, and the unknown id still traverses the full chain to the provider's own 404. `17-interposer-in-path.txt`, the wasmCloud host pod's own stderr lines, is the proof that the policy decision happens *inside the interposer component*, across the link, and not somewhere else in the chain:

{% raw %}
```
cargo-filter: book-cargo origin=USNYC destination=CUHAV weight_kg=1200.5
cargo-filter: POLICY DENY book-cargo: destination CUHAV is under embargo
```
{% endraw %}

Those are the exact `eprintln!` lines from `src/lib.rs`, captured from a pod running a component built from the same source as the minikube composition, deployed via a completely different mechanism. The policy and the logging travel with the component; only the wiring mechanism changed.

## The headline finding: a valid id returns 404, not 200

Run the same request minikube answered with a 200, `GET /cargo/CARGO-USNYC-DEHAM`, a recognized, non-embargoed tracking id, against the CRC deployment, and the result is not the exact cargo JSON. `14-filtered-http.txt` records it:

{% raw %}
```
$ curl -w ' [%{http_code}]' https://cargo-filtered-wasmcloud.apps-crc.testing/cargo/CARGO-USNYC-DEHAM
{"error":"no cargo CARGO-USNYC-DEHAM"} [404]
```
{% endraw %}

The chain is fully wired, exactly as the embargo and unknown-id results already prove; the 404 traces to the provider's per-invocation memory lifecycle, not to the link configuration. `examples/part3-interfaces/http-rust/src/lib.rs` handles a `CARGO-{ORIGIN}-{DEST}`-shaped id by seeding a booking and reading it back: two calls, one HTTP request:

{% raw %}
```rust
match booking::book_cargo(&spec, DEFAULT_WEIGHT_KG) {
    Ok(b) => match booking::get_cargo(&b.cargo_id) {
        Ok(cargo) => { /* 200, exact cargo JSON */ }
        Err(e) => send_error(response_out, &e),
    },
    Err(e) => send_error(response_out, &e),
}
```
{% endraw %}

And the provider itself keeps its bookings in ordinary process memory:

{% raw %}
```rust
thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}
```
{% endraw %}

Under minikube's `wac plug` composite, `book-cargo` and `get-cargo` are both ordinary Rust function calls inside one component instance running inside one Pod for the duration of one HTTP request: the `thread_local` `HashMap` that `book-cargo` just wrote into is the exact same `HashMap` `get-cargo` reads a moment later. Under wasmCloud's runtime links, that guarantee does not hold. **wasmCloud components are stateless by design: every invocation gets a fresh component instance with its linear memory reset.** `book-cargo` runs on one instance of the provider, writes a booking into that instance's `HashMap`, and the instance is then gone; `get-cargo` runs on a new instance a moment later, whose `HashMap` was never touched, and the provider correctly answers `NotFound`. The front door, the interposer, and the provider all do exactly what their code says; the difference is entirely in what each substrate guarantees about instance lifetime between two linked calls in the same logical request.

{% include excalidraw.html file="20-state-contrast" alt="Side by side comparison for the same request, GET /cargo/CARGO-USNYC-DEHAM. On minikube, one provider component instance serves both the book-cargo call (HashMap.insert) and the get-cargo call (HashMap.get) against the same linear memory, returning 200 with the exact cargo JSON. On CRC, book-cargo runs on a fresh provider instance A that inserts into its own HashMap, then get-cargo runs on a separate fresh provider instance B whose HashMap is empty, so the provider answers its own NotFound and the front door returns 404." caption="Figure 20.2: the state contrast: one shared instance (minikube) returns 200; two independent fresh instances across a link (CRC) return 404." %}

This is the single biggest practical difference between the two substrate expressions of the same pattern, and it generalizes past this one demo: any interposition chain that relies on in-process memory surviving between two calls to the same logical provider needs that provider to either be composed in-process (the `wac plug` form) or to keep its state somewhere that outlives an individual invocation, a capability provider backed by a key-value store, or a wasmCloud **Service** workload, which pins one long-lived instance instead of spawning a fresh one per call. Neither of those exists in this chapter's components; the fix is named, not built, because building it would be new scope this chapter did not set out to cover. The working subset (embargo policy enforced across the link, an unknown id traversing the full chain to the provider's real 404, the interposer's own log lines proving it fires) is fully live and fully proven on both substrates. The 404-for-a-valid-id result on CRC confirms the same point: a runtime link gives an independent, resettable component lifecycle rather than a shared process, the tradeoff the next section names.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s && ./verify-interposed-minikube.sh
```

`verify-interposed-minikube.sh` starts the `part5` minikube profile (docker driver, containerd runtime), builds and loads both this chapter's `wac plug`-composed `app-filtered.wasm` and the ambassador-and-adapter patterns' `app-adapted.wasm`, installs the `containerd-shim-wasmtime` shim, and deploys both as sibling Pods behind their own `nip.io` Ingress hosts. For the filtered composition it asserts a normal tracking id returns the exact cargo JSON (200), the embargoed `CUHAV` destination is rejected with the interposer's own policy 400, and an unknown id falls through to the provider's 404, all through the real ingress-nginx edge with no port-forward and no NodePort. Expect `PASS` once both this chapter's and the ambassador-and-adapter patterns' assertions hold; `README.md` and `k8s/evidence/` record the version matrix each run confirms.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Choose compile-time composition (<code>wac plug</code>, the minikube form) when the cross-cutting concern needs to sit inside the same request's call graph as a stateful provider: any pattern where one call writes state another call in the same request reads back, the way this chapter's book-then-get round trip does. The composed component shares one linear memory per invocation of the top-level export, so in-process state survives automatically, with no extra plumbing. Choose a runtime link (the <code>wadm</code> form) when independent lifecycle, independent scaling, and the ability to inject or swap policy without rebuilding the provider matter more than shared memory: a policy or logging concern that reads its inputs and produces its output without needing anything the provider wrote on a previous call is a perfect fit, which is exactly why this chapter's embargo check and the ambassador-and-adapter patterns' shape-adapter both work unchanged on CRC. The moment a pattern needs state to survive across a link, move that state out of component memory entirely: a capability provider backed by a real store, or a wasmCloud Service workload pinning one instance, not a `thread_local` field inside a component that Wasm's own stateless-invocation model resets on the next call.</p></div>

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the sidecar and ambassador patterns this chapter's interposer plays the structural role of, translated from a container-level mechanism to a Wasm component-level one.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model composition guarantees (`wac plug`, shared versus independent instances) this chapter's two substrate expressions both rely on.
- *Cloud Native Design Patterns*: the Sidecar and Ambassador pattern writeups this chapter's embargo-policy interposer and the ambassador-and-adapter patterns' outbound-resilience component each instantiate for the cargo domain.
- [wasmCloud component lifecycle: Services vs. Components](https://wasmcloud.com/docs/overview/workloads/components/) and [wasmCloud Services](https://wasmcloud.com/docs/overview/workloads/services/): the per-invocation statelessness this chapter's 404 depends on, and the long-lived-instance alternative named as the fix for a stateful domain.
- [`bytecodealliance/wac#149`](https://github.com/bytecodealliance/wac/issues/149): the open composition-tooling issue behind this chapter's choice to interpose at the cargo value interface rather than at `wasi:http/incoming-handler` directly.
- wasmtime and wasmCloud together: the single-process-versus-lattice tradeoff this chapter's state contrast is a concrete, request-level instance of.
- Deploying on minikube: the raw containerd shim and the plain `app.wasm` this chapter's `wac plug` composition builds directly on top of.
- Deploying on OpenShift Local (CRC): the wasmCloud operator, the host, and the link model this chapter's `wadm-filtered.yaml` deploys into.
- Ambassador and adapter patterns with Wasm: the same provider and front door, interposed with a shape-translating adapter and an outbound-resilience ambassador instead of an embargo filter, built with the identical two-substrate structure this chapter establishes.

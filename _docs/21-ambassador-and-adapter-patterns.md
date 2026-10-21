---
title: "Ambassador and Adapter Patterns with Wasm"
order: 21
part: "Deploying to Kubernetes"
description: "Two more cross-cutting concerns interposed on the same cargo provider and front door: a shape-translating ADAPTER that round-trips every booking through a different legacy request shape, and an outbound AMBASSADOR that retries a flaky dependency behind a capability-scoped network grant, both verified live, with the ambassador's cluster expression differing for a real substrate reason."
duration: "22 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what distinguishes an adapter interposer from Chapter 20's filter: the same import-and-export symmetry on `patterncatalyst:cargo`, but the canonical `book-cargo` round-trips every request through a different "legacy" shape before calling the real provider, and the component also exports that legacy shape directly for a legacy-shaped caller.
- Read `examples/part5-kubernetes/adapter/wit/world.wit` and `src/lib.rs` to find the legacy request shape, the `to_legacy`/`from_legacy` conversions, and the `conv` module bridging the two Rust type trees the same way Chapter 20's filter does.
- Trace the adapter's proof on minikube (the round-trip is lossless, so the exact cargo JSON comes back) and on CRC (the round-trip still runs, but a valid tracking id hits the identical per-invocation state finding Chapter 20 documents), and explain why the same component source code produces two different results.
- State the ambassador's defining property: an outbound call reached only through an explicit grant, never a default, and name the concrete evidence that proves it on each cluster: CRC's 404-versus-5xx grant/no-grant pair over a wadm link, and a local `wasmtime run -S inherit-network` smoke reusing Chapter 13's `sockets-rust`.
- Decide, for a given resilience or shape-translation concern, whether an adapter or an ambassador interposition fits, and recognize when a pattern is substrate-asymmetric by the platform's own design rather than broken.

## Why this matters

Chapter 20 built one interposer, a destination-embargo filter, and proved it two ways: spliced into one component at build time on minikube, wired in as a runtime link between three separate wasmCloud components on CRC. This chapter reuses that exact structure (the same Part 2 cargo provider, the same Part 3 HTTP front door, `patterncatalyst:cargo` still untouched in `contracts/wit/`) for two more patterns that solve different problems than a policy check. The **adapter** translates between two incompatible request shapes so a legacy caller can drive a modern provider without either side changing. The **ambassador** owns a service's resilient outbound calls, retrying a flaky dependency with backoff and jitter behind a capability-scoped network grant, the same `wasi:sockets` component Chapter 13 built and proved from the command line, now interposed in front of a service instead of run standalone.

Both patterns come from the same place Chapter 20's sidecar framing did: Brendan Burns' catalog of multi-container Pod patterns, restated here at the Wasm component level instead of the container level. An adapter normalizes a non-conforming interface so the rest of the system can treat every caller uniformly; an ambassador represents an outbound dependency to the service that calls it, so the caller's code never has to know the dependency is flaky, slow, or reached over a network at all. Chapter 20 already showed that compile-time composition and runtime linking are not just two ways to deploy the same bytes, they produce different runtime behavior once a provider holds state across more than one call. The adapter inherits that finding unchanged. The ambassador adds a second, independent substrate difference: the raw containerd shim Chapter 18 proved live on minikube hosts exactly one component behind a fixed `:8080` listener and exposes no way to grant that component outbound network access, so the ambassador's defining property (reaching a dependency through a grant) can only run as a cluster workload on CRC. minikube's evidence for the ambassador is a local smoke of the same component, not a cluster deployment, and this chapter states that directly rather than treating the two as equivalent.

Both patterns are verified live, as of 2026-10-21: the adapter on minikube (`k8s/evidence/2026-10-21/14-adapted-http.txt`) and on CRC (`openshift/evidence/2026-10-21/15-adapted-http.txt`); the ambassador cluster-live on CRC (`openshift/evidence/2026-10-21/16-ambassador-http.txt`, plus the negative control in `wadm-ambassador-nogrant.yaml`) and as a local minikube-adjacent smoke (`k8s/evidence/2026-10-21/15-ambassador-localserve.txt`). Every transcript quoted below comes from one of those files.

{% include excalidraw.html file="21-adapter-shape-translation" alt="Two bands. Top: on minikube, the Part 3 http-rust front door, the cargo-adapter interposer, and the Part 2 cargo provider are composed at build time with two wac plug steps into one app-adapted.wasm running as a single Pod; book-cargo round-trips a request from the canonical shape to a legacy shape and back inside one in-process instance, and the exact cargo JSON comes back. Bottom: on CRC, the same three logical pieces run as three separate wasmCloud components wired by wadm link traits over wRPC; the round-trip still runs and is still lossless, but book-cargo and get-cargo land on two different fresh instances, so a valid tracking id now returns the provider's own 404, the same per-invocation statelessness finding Chapter 20 documents for its filter." caption="Figure 21.1 — the adapter's shape translation, two substrate expressions: lossless round-trip either way, but the valid-id state finding only shows up on CRC." %}

## The adapter's world: a legacy shape next to the canonical one

`examples/part5-kubernetes/adapter/wit/world.wit` declares the adapter's own `legacy` interface alongside the familiar import-and-export symmetry on `patterncatalyst:cargo` that makes it an interposer at all:

```wit
interface legacy {
    use patterncatalyst:cargo/types@0.1.0.{booking, cargo-error};

    enum legacy-service-level {
        economy,
        priority,
    }

    record legacy-booking-request {
        origin-code: string,
        dest-code: string,
        cargo-weight: f64,
        needed-by: string,
        service-level: legacy-service-level,
    }

    book-legacy: func(req: legacy-booking-request) -> result<booking, cargo-error>;
}

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

The `legacy` interface is not the canonical `route-spec`: flat UN/LOCODE strings instead of structured `location` records with a name and a country, renamed fields (`origin-code`/`dest-code`/`cargo-weight`/`needed-by` instead of `route-spec.origin`/`.destination`/`weight-kg`/`arrival-deadline`), and a `service-level` enum the canonical model has no concept of at all. This is the shape a real system carries forward from before a canonical contract existed: exactly the kind of pre-existing, non-conforming interface Kubernetes Patterns' adapter writeup describes normalizing at the boundary rather than rewriting at the source. Both `legacy` and the three canonical interfaces live entirely in the adapter's own `wit/world.wit`; `patterncatalyst:cargo` is pulled in as a path dependency the same way Chapter 20's filter does, and `contracts/wit/` never changes.

`src/lib.rs` keeps the translation in two small, symmetric functions. `to_legacy` flattens a canonical `RouteSpec` to the legacy shape, picking a default service level the canonical model has nowhere to carry:

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

`from_legacy` reverses it, re-inflating a flat UN/LOCODE back into a structured `Location` through a small lookup table that mirrors the HTTP front door's own name/country mapping for the demo's two known codes, and falling back to `(code, "")` for anything else:

```rust
fn location_for(unlocode: &str) -> Location {
    let (name, country) = match unlocode {
        "USNYC" => ("New York", "US"),
        "DEHAM" => ("Hamburg", "DE"),
        other => (other, ""),
    };
    Location { unlocode: unlocode.to_string(), name: name.to_string(), country: country.to_string() }
}

fn from_legacy(req: &LegacyBookingRequest) -> (RouteSpec, f64) {
    let spec = RouteSpec {
        origin: location_for(&req.origin_code),
        destination: location_for(&req.dest_code),
        arrival_deadline: req.needed_by.clone(),
    };
    (spec, req.cargo_weight)
}
```

The canonical `book-cargo` export round-trips every request through both functions before it ever calls the real provider (canonical to legacy, then straight back to canonical) and logs each half of the translation to stderr:

```rust
fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {
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

That round trip is the proof this component exists to offer: for every field the cargo JSON surfaces, translating canonical to legacy and back is lossless, so calling the real provider with the re-inflated request produces the exact same result as calling it with the original one would have. The `legacy` interface's own `book-legacy` export skips the first half of that trip and calls `from_legacy` directly, so a caller who only ever spoke the old shape can drive the same modern provider through the identical conversion code.

<div class="callout callout--warn"><p class="callout__title">Gotcha</p><p>A world that both imports and exports <code>patterncatalyst:cargo/*</code> gives <code>wit-bindgen</code> two separate Rust type trees for the same logical interface: <code>bindings::patterncatalyst::cargo::types</code> (the import side, aliased <code>up</code> here, same as Chapter 20's filter) and <code>bindings::exports::patterncatalyst::cargo::types</code> (the export side, aliased <code>dn</code>). They are structurally identical and nominally distinct Rust types, so every value crossing the adapter needs a field-by-field converter in its own <code>conv</code> module: <code>location_up</code>/<code>location_dn</code>, <code>route_spec_up</code>/<code>route_spec_dn</code>, <code>booking_dn</code>, <code>cargo_dn</code>, <code>itinerary_up</code>/<code>itinerary_dn</code>, <code>handling_event_dn</code>, <code>err_dn</code>, and a <code>match</code> arm per enum variant for <code>HandlingEventType</code>, <code>RoutingStatus</code>, and <code>TransportStatus</code>. This is the identical gotcha Chapter 20 names for its filter, not a new one: budget for this conversion module the moment any world declares a symmetric import/export pair, whether or not the component also does a second, domain-level translation on top like this one does.</p></div>

## Composing and running the adapter: wac plug, same recipe as Chapter 20

`examples/part5-kubernetes/adapter/build.sh` splices the adapter into the identical Part 2/Part 3 recipe with the same two-step `wac plug` chain Chapter 20's filter uses, provider plugged into adapter, then that result plugged into the HTTP front door:

```bash
wac plug --plug "$PROVIDER" "$ADAPTER" -o "$TMP_PA"
wac plug --plug "$TMP_PA" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"
```

No upstream crate is forked or edited; `app-adapted.wasm` exports `wasi:http/incoming-handler` at the top of the graph, deployed through the same `wasmtime` `RuntimeClass`, Deployment, Service, and `nip.io` Ingress pattern as every other component in this part. The live curl transcript through that Ingress, `k8s/evidence/2026-10-21/14-adapted-http.txt`:

{% raw %}
```
$ curl -s http://cargo-adapted.192.168.49.2.nip.io/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -o /dev/null -w %{http_code} http://cargo-adapted.192.168.49.2.nip.io/cargo/NOPE
404
```
{% endraw %}

That is the exact same cargo JSON Chapter 18 and Chapter 20 each returned for this tracking id through the plain and the filtered compositions, byte for byte, round-tripped through a legacy shape and back with nothing lost. An unknown id falls through to the provider's own 404, same as the filter's uninterposed path. The adapter has added a translation layer with zero visible effect on a normal request. For a shape adapter that is exactly the point: it should be invisible when it succeeds.

## The adapter on CRC: the round-trip runs, and the Chapter 20 state finding returns

`openshift/wadm-adapted.yaml` deploys the identical three-component link graph Chapter 20 uses for its filter, with the shape-translation adapter standing in the interposer slot:

```
httpserver   --wasi:http/incoming-handler-->  cargo-adapted (front door)
cargo-adapted  --patterncatalyst:cargo/booking-->  cargo-adapter (interposer)
cargo-adapter  --patterncatalyst:cargo/booking,handling-->  cargo-provider-a
```

Deployed on the lattice, the translation runs across the link exactly as it does inside one process on minikube. There is nothing about `to_legacy`/`from_legacy` that depends on where the caller lives. `openshift/evidence/2026-10-21/15-adapted-http.txt` is the CA-verified curl transcript through the real edge-TLS Route:

```
$ curl -w ' [%{http_code}]' https://cargo-adapted-wasmcloud.apps-crc.testing/cargo/NOPE
{"error":"no cargo NOPE"} [404]
# valid id: the canonical->legacy->canonical translation runs, then book+get;
# same per-invocation state gotcha -> provider NotFound (404), not 200.
$ curl -w ' [%{http_code}]' https://cargo-adapted-wasmcloud.apps-crc.testing/cargo/CARGO-USNYC-DEHAM
{"error":"no cargo CARGO-USNYC-DEHAM"} [404]
```

A valid, non-embargoed tracking id (the same one that returned the exact cargo JSON on minikube a moment ago) now returns the provider's own `NotFound`. This is not a translation bug, and it is not specific to the adapter: it is the identical finding Chapter 20 names for its filter, applying unchanged to a different interposer. The HTTP front door answers a valid id by calling `book-cargo` and then `get-cargo`, two separate wRPC calls across the link; because wasmCloud gives every invocation a fresh component instance with reset linear memory, the provider instance that wrote the booking into its `thread_local` `HashMap` is gone by the time `get-cargo` runs on a new one, and the provider correctly answers that it has no record of a cargo it never actually persisted anywhere durable. The round trip through the legacy shape is lossless either way; what differs between the two clusters is not the adapter's translation, it is whether the provider's in-memory state survives between two linked calls: exactly the substrate property Chapter 20 already isolated, now confirmed a second time against a component that does more than a filter ever did.

## Ambassador: an outbound call reached only through a grant

The ambassador pattern is a different shape of interposer entirely: instead of standing between a caller and a provider translating or policing requests, it owns a service's *outbound* calls to a dependency, retrying failures with backoff and jitter so the caller's own code never has to. `examples/part5-kubernetes/ambassador/` builds nothing new for this; it reuses `examples/part3-interfaces/sockets-rust`, the exact `wasi:sockets` command component Chapter 13 built and proved, unedited, as the resilience artifact standing in for an ambassador's outbound hop:

{% include excalidraw.html file="21-ambassador-egress-grant" alt="Two bands. Top: on CRC, the front door component cargo-ambassador reaches cargo-provider-am across a runtime-granted wadm link, and GET /cargo/NOPE returns the provider's own 404, proving the outbound call landed; the same deployment with the link removed (cargo-ambassador-nogrant) leaves the front door's cargo import unsatisfiable, so the operator-created Service gets no endpoints and the edge Route fails with a 5xx. Bottom: on minikube, the raw containerd shim exposes no outbound-network knob, so the evidence is a local wasmtime smoke against the reused sockets-rust component: without the grant, a connect attempt is denied with access-denied on the first try; with the grant against a dead port, four connection-refused attempts back off with growing jitter before giving up; with the grant against a live listener, the component connects on the first attempt." caption="Figure 21.2 — the ambassador's outbound call reached only through a grant: CRC's cluster-live 404-versus-5xx link contrast, and minikube's local wasmtime capability/backoff smoke." %}

```bash
echo "ambassador/build.sh: [1/2] building the Part 3 sockets-rust resilience component (reused, not edited) ..."
( cd "$SOCKETS" && cargo component build --release )
cp "$WASM" "$OUT"
```

`sockets-rust` already does everything an ambassador's resilience half needs: it attempts an outbound TCP connect, and on `connection-refused` it backs off with the exponential-plus-jitter formula Chapter 13 derives (`base * 2^min(attempt-1, 5)`, plus up to 50% jitter from `wasi:random`), retrying up to a bounded number of attempts. What makes it an ambassador rather than a standalone client in this chapter is where it gets interposed: in front of a service's dependency, with its outbound reach gated by a capability the host or the lattice grants, not a default every component receives automatically.

`build.sh`'s local smoke proves three properties of that gate in one run: a capability denial, a failed-but-retried connection, and a succeeded one, all against `ambassador.wasm` (a copy of `sockets-rust`), captured in `k8s/evidence/2026-10-21/15-ambassador-localserve.txt`:

```
=== SMOKE A: retry + exponential backoff with jitter (dead port 34571, WITH network grant) ===
sockets-rust: connecting to 127.0.0.1:34571 (up to 4 attempts, base 50ms backoff)
sockets-rust: attempt 1/4 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: backing off 64ms before retry
sockets-rust: attempt 2/4 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: backing off 122ms before retry
sockets-rust: attempt 3/4 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: backing off 225ms before retry
sockets-rust: attempt 4/4 failed: ErrorCode { code: 14, name: "connection-refused", message: "The TCP connection was forcefully rejected" }
sockets-rust: giving up after 4 attempts
ambassador/build.sh: smoke A exit code = 1 (expected 1 — gave up after retries)

=== SMOKE B: connects on attempt 1 (live listener 34572, WITH network grant) ===
sockets-rust: connecting to 127.0.0.1:34572 (up to 4 attempts, base 50ms backoff)
sockets-rust: connected to 127.0.0.1:34572 on attempt 1
ambassador/build.sh: smoke B exit code = 0 (expected 0 — connected)

=== SMOKE C: capability boundary (dead port 34571, WITHOUT network grant) ===
sockets-rust: connecting to 127.0.0.1:34571 (up to 4 attempts, base 50ms backoff)
sockets-rust: attempt 1/4 failed: ErrorCode { code: 1, name: "access-denied", message: "Access denied.\n\n            POSIX equivalent: EACCES, EPERM" }
sockets-rust: network access DENIED by the host capability boundary — grant it with `wasmtime run -S inherit-network`
ambassador/build.sh: smoke C exit code = 1 (non-zero — failed fast, no retries)
```

Smoke A and smoke C both end with the wasmtime process exiting `1`, and that collapse is worth stopping on directly.

<div class="callout callout--warn"><p class="callout__title">Gotcha</p><p>Smoke A gives up after four separate <code>connection-refused</code> retries and exits <code>1</code>; smoke C is denied on the very first attempt with <code>access-denied</code> and also exits <code>1</code>. WASI's process-exit model is success or failure only: <code>wasmtime</code> collapses any non-zero guest exit to the single process code <code>1</code>, so the exit code alone cannot distinguish "retried and gave up" from "denied before the first packet moved." <code>build.sh</code> never asserts on the numeric exit code to tell these apart; it asserts on the transcript text instead, smoke A's assertion checks for four distinct <code>attempt N/4</code> lines, and smoke C's checks for <code>access-denied</code> on attempt 1 and explicitly checks that <code>attempt 2/4</code> never appears, because a capability denial that retried would be the one bug this component must never have. Treat a bare process exit code as evidence of almost nothing on a WASI component; the real signal is always in the recorded output.</p></div>

Smoke B is the control: with the grant and a listener actually present, the connect succeeds on the first attempt and the process exits `0`, exactly as Chapter 13's own `sockets-rust` transcripts already showed in isolation. Nothing in `sockets-rust` changed to serve as an ambassador instead of a standalone client; the pattern lives entirely in how and where the component is interposed, which is the same lesson Chapter 20's filter and this chapter's own adapter both teach about Wasm components generally: the component is reusable scope, the interposition is the pattern.

## The ambassador on CRC: egress is a grant

CRC is where the ambassador's cluster-live property actually runs. `openshift/wadm-ambassador.yaml` deploys a front door and a cargo provider as two separate wasmCloud components, linked by exactly one `link` trait; no interposer this time, the front door's outbound cargo call reaches the provider directly across the link:

```
httpserver     --wasi:http/incoming-handler-->  cargo-ambassador (front door)
cargo-ambassador  --patterncatalyst:cargo/booking-->  cargo-provider-am
                     ^^^^^ the runtime-granted outbound link (the "grant")
```

On the wasmCloud lattice, that `link` trait is the grant: a component's outbound call to another component only resolves if the link exists at deploy time, the lattice-level analog of `wasmtime run -S inherit-network` granting `wasi:sockets` to a single process. `openshift/evidence/2026-10-21/16-ambassador-http.txt` is the CA-verified curl proof that the outbound hop actually lands:

```
$ curl -w ' [%{http_code}]' https://cargo-ambassador-wasmcloud.apps-crc.testing/cargo/NOPE
{"error":"no cargo NOPE"} [404]
```

A 404 here is a positive result, not a failure: it is the provider's own `NotFound`, which only a component that successfully reached the provider and got an answer back could return. `wadm-ambassador-nogrant.yaml` is the negative control, the same front door and provider with the one `link` trait removed, deployed transiently by `verify-interposed-crc.sh` and torn down immediately after:

```
# NO patterncatalyst:cargo link here on purpose — the grant is absent.
```

Without that link, the front door's cargo import is unsatisfiable, so the wasmCloud host never admits the component as a healthy backend at all: the operator-created Service gets no endpoints, and the edge Route in front of it fails fast rather than reaching anything. The captured result from the same verification pass:

```
✓ AMBASSADOR no-grant GET /cargo/NOPE -> 500 (ungranted outbound call denied; the unlinked front door is not served)
```

404 with the link, a router 5xx (500 in this captured run) without it, for the identical request against the identical front door and provider images: the only difference between the two deployments is the presence of one `link` trait in the manifest. That contrast is the same capability-boundary distinction Chapter 2 draws at the Core-spec level and Chapter 13 makes concrete against a raw socket: authority comes only from what the host or the runtime explicitly resolves, never from an ambient default. Chapter 13's `wasi:sockets` denial surfaces as an `access-denied` `ErrorCode` the component itself can read and log; the lattice's denial surfaces one layer higher, as a component the platform never finishes admitting, which is why the visible symptom is a Service with no endpoints and a Route answering for nobody rather than an error message any component code ever runs to produce. Two different mechanisms, the same principle: egress is a grant, not a default, at every layer this book has shown it operating at.

## Why minikube can't run the ambassador live

The raw containerd shim Chapter 18 proved live hosts exactly one component behind a fixed `:8080` hyper server and exposes no flag, environment variable, or manifest field that grants a running Pod outbound network access the way `wasmtime run -S inherit-network` grants it to a single process invocation. An ambassador's defining property is precisely that outbound reach, so there is no way to express this pattern as a minikube Pod on the shim path at all. That is not a bug in this chapter's examples; it is a real gap in what that specific runtime surface exposes, stated the same way Chapter 13 states TinyGo's `wasi:sockets` runtime gap, with the exact mechanism named, rather than worked around with something that would not actually prove the pattern.

The minikube-side evidence for the ambassador is therefore the local `wasmtime run -S inherit-network` smoke already quoted above, run against the host directly rather than through a scheduled Pod. That smoke is not a lesser proof of the pattern; it is the same `sockets-rust` binary, the same backoff formula, the same capability grant mechanism Chapter 13 verified in isolation, now run through the three-smoke sequence an ambassador specifically needs: denied without the grant, retried-then-exhausted with the grant against a dead dependency, and connected on the first attempt with the grant against a live one. What minikube's shim cannot do is host that component as a cluster workload reachable through a Service and an Ingress the way every other component in this part runs; CRC's wasmCloud lattice can, because granting an outbound link is a property of the lattice's own link graph, not of the node's container runtime.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for an ADAPTER when two sides of a call already agree on the destination (a modern provider, a modern caller) but disagree on the shape of the request: translate at the boundary, in a component that imports the canonical interface and exports it back out, the way <code>examples/part5-kubernetes/adapter</code> does here; never rewrite the provider or the caller to accommodate a shape only one side still uses. Place that translation with compile-time <code>wac plug</code> composition when the request needs to survive as in-process state across more than one call to the same provider within a single invocation, and accept a runtime link when independent lifecycle and deploy-time rewiring matter more: the exact choice Chapter 20 already names, and this chapter's valid-id 404 on CRC confirms it applies to a shape adapter exactly as it applies to a policy filter. Reach for an AMBASSADOR whenever a service's own code would otherwise need to know a dependency is flaky, slow, or reached over a network at all; keep the retry loop inside the ambassador component, gated by an explicit grant (a host capability for a single process, a lattice link for a distributed one), and never let an outbound call default to reachable. When a pattern cannot be expressed identically on every target platform, as the ambassador cannot on the minikube shim, name the missing mechanism precisely, prove the pattern wherever the platform actually allows it, and do not manufacture a deployment that does not exist just to make the coverage look symmetric.</p></div>

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023) — the Ambassador and Adapter multi-container Pod patterns this chapter restates at the Wasm component level, continuing Chapter 20's Sidecar treatment of the same catalog.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning) — the Component Model composition guarantees (`wac plug`, the import/export symmetry an interposer relies on) both of this chapter's patterns build on.
- *Cloud Native Design Patterns*, "Failure Modes" chapter — the retry-with-backoff-and-jitter catalog this chapter's ambassador borrows directly from Chapter 13 rather than reinventing.
- [wasmCloud component lifecycle: Services vs. Components](https://wasmcloud.com/docs/overview/workloads/components/) — the per-invocation statelessness behind this chapter's adapter hitting the same 404 Chapter 20's filter hits on CRC.
- Chapter 2, "The Execution Model" — the capability-based security model this chapter's 404-versus-5xx grant contrast makes concrete a second time, at the lattice-link layer instead of the host-capability layer.
- Chapter 13, "Networking, Reconnect, and Resilience" — the exact `sockets-rust` component, backoff formula, and `access-denied`/`connection-refused` distinction this chapter's ambassador reuses unedited.
- Chapter 17, "Wasm on Kubernetes" and Chapter 18, "Deploying on minikube" — the raw containerd shim and its fixed-listener, no-outbound-grant shape this chapter's ambassador section names as the reason the pattern cannot run there as a cluster workload.
- Chapter 19, "Deploying on OpenShift Local (CRC)" and Chapter 20, "Wasm as a Sidecar" — the wasmCloud operator, the link model, and the interposition structure (import-and-export symmetry, the `conv` module, the per-invocation state finding) this chapter's adapter and ambassador both build on directly.

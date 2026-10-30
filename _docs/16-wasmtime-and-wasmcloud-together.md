---
title: "wasmtime and wasmCloud Together"
order: 16
part: "Runtimes: wasmtime & wasmCloud"
description: "One WIT-contract-conformant component, built once, running byte-for-byte identical on wasmtime and on wasmCloud: the portability payoff this site's contract-first chapters were building toward, plus the one real behavioral gap between the two runtimes and when to pick each."
duration: "15 min read"
---

## Learning objectives

By the end of this chapter you can:

- State this site's portability claim precisely: `app.wasm`, built once by `examples/part4-runtimes/wasmcloud/build.sh`, has the identical sha256 whether it runs under `wasmtime serve -S cli`'s single-process runtime or is deployed into a wasmCloud lattice by `wadm`, and explain why the Component Model's WIT contract is what makes that identity possible rather than accidental.
- Read `examples/part4-runtimes/wasmcloud/prove-same-bytes.sh` and `capture-evidence.sh` together and point to the exact lines that record a sha256 on each side, plus the two curl results each script asserts.
- Choose between wasmtime and wasmCloud for a given component by naming what each runtime makes you own: a single process and its host code on one side, a lattice of hosts, providers, and links reconciled by `wadm` on the other.
- Name the one real behavioral difference between the two runtimes for this site's domain (wasmCloud ignores exported component resources, wasmtime does not), and explain why it does not show up in this chapter's HTTP path but would show up in a component that exported one.
- Place this choice correctly relative to Part 5: deploying a runtime inside Kubernetes is a separate, later decision from which runtime a given component should run under.

## Why this matters

This site has been building toward a specific claim since the Component Model and WIT first appeared, and this chapter is where that claim gets proven with a command instead of asserted with prose. The Component Model and WIT pinned `patterncatalyst:cargo@0.1.0` down as a WIT contract that exists independently of any implementation. The first Rust component and the first Go component each built that contract once, and composing those components into WIT worlds then combined the two by WIT identifier, not by source language. Serving HTTP from a component put an HTTP front door in front of the composed component. wasmtime ran the result embedded and then served directly. wasmCloud moved the same artifact into a lattice, replacing direct host wiring with a capability provider and a declarative link. At no point in that sequence did the component's bytes change because the runtime around it changed, and this chapter is where that fact stops being an implication of the architecture and becomes something you can check with `sha256sum`.

The check is almost anticlimactic, which is the point. `examples/part4-runtimes/wasmcloud/build.sh` produces one file, `app.wasm`, by wac-plugging the Part 2 Rust `cargo` provider under the Part 3 `http-rust` front door. That one file is what `examples/part4-runtimes/wasmcloud/prove-same-bytes.sh` runs under `wasmtime serve -S cli`, and it is also the exact `file://./app.wasm` reference that `wadm.yaml` deploys into the wasmCloud lattice via `capture-evidence.sh`. Two runtimes, two completely different execution models (one a single process linking a component directly, the other a distributed set of hosts coordinated by NATS and reconciled by `wadm`), and the artifact crossing into both of them is the same file, not a rebuild, not a recompile with different flags, not a runtime-specific variant. The sha256 the two scripts each record is not a coincidence the chapter is pointing out after the fact; it is the direct, mechanical consequence of the Component Model's boundary between contract and implementation: a component's exports are defined by WIT, a runtime's job is to satisfy a component's imports and call its exports, and nothing about satisfying imports requires the runtime to see, let alone change, the component's own bytes.

That payoff is also exactly why this chapter is a comparison and not just a longer version of the wasmCloud chapter. The wasmtime chapter taught wasmtime on its own terms: embedding, `Store`/`Engine` controls, fuel and epoch metering, resource limits. The wasmCloud chapter taught wasmCloud on its own terms: the lattice, capability providers, links, `wadm`'s declarative reconciliation and self-healing. Neither needed the other to make its point. This chapter's entire job is the comparison those two did not make: the same artifact, side by side, under both runtimes, with the one place they diverge named precisely rather than glossed over. A reader who has been through both runtime chapters already knows how each one works; what they don't yet have is a basis for choosing, for a specific component in front of them, which one to run it under. The sections below give them that basis.

{% include excalidraw.html file="16-same-bytes-two-runtimes" alt="A single app.wasm artifact box at the top, labeled 'built once by build.sh, sha256 eff7f5ee81db5f9f...4c9909b3', with two arrows fanning down into two bands. Left band, wasmtime serve -S cli, single-process runtime: single process, wasmtime loads the component directly, no lattice; GET /cargo/CARGO-USNYC-DEHAM; 200 with the tracking_id/origin/destination/weight JSON; GET /cargo/NOPE returns 404. Right band, wasmCloud lattice: httpserver provider linked to the cargo-http component via wadm.yaml; the identical GET request; the identical 200 JSON; the identical 404 for the unknown ID. Both bands' results feed into a bottom banner: identical JSON on both sides, identical sha256 on both sides, one build, two runtimes, no rebuild in between. A note below states the one caveat: wasmCloud ignores exported component resources (the cargo-tracker resource), logging a WARN at start, harmless here because the HTTP path only uses booking, while wasmtime serve runs the component as-is, resource and all." caption="Figure 16.1: one app.wasm, two runtimes, byte-for-byte identical behavior on the path this component exercises." %}

## Reading the proof, not just the claim

The proof lives in two scripts that were written to be read side by side, and `examples/part4-runtimes/wasmcloud/README.md` says so directly: "The deployed artifact (`app.wasm`) is byte-for-byte the same component that `wasmtime serve` runs in Part 3 and in `prove-same-bytes.sh` (ch16)." Start with `build.sh`, which is the single source of truth for the artifact both sides consume:

```bash
echo "build.sh: [1/3] building the Part 2 Rust cargo provider (reused, not edited) ..."
( cd "$PART2/rust" && cargo component build --release )
PROVIDER="$(find "$PART2/rust/target" -name cargo_rust.wasm -not -path '*/deps/*' | head -1)"
...
echo "build.sh: [2/3] building the Part 3 http-rust front door (reused, not edited) ..."
( cd "$PART3/http-rust" && cargo component build --release )
HTTP="$(find "$PART3/http-rust/target" -name cargo_http_rust.wasm -not -path '*/deps/*' | head -1)"
...
echo "build.sh: [3/3] composing app.wasm (wac plug: provider -> http front door) ..."
wac plug --plug "$PROVIDER" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"
```

Nothing here is new machinery. This is the `wac plug` composition step from composing components into WIT worlds, run once, against the exact Part 2 and Part 3 crates those earlier chapters already built; the comment in the script is explicit that it does "NOT fork or edit the component; it rebuilds the upstream crates with their own recipes and plugs them together." The output, `app.wasm`, exports `wasi:http/incoming-handler`, which is the one interface both runtimes in this chapter need to satisfy to serve HTTP traffic over it.

`prove-same-bytes.sh` is the wasmtime side of the proof. It hashes the artifact, serves it, and asserts against it in a few lines:

```bash
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

SHA="$(sha256sum "$APP" | awk '{print $1}')"
echo "app.wasm sha256: $SHA"

PORT=18210
wasmtime serve -S cli "$APP" --addr "127.0.0.1:$PORT" >"$SCRIPT_DIR/.serve.log" 2>&1 &
...
BODY="$(curl -s "http://127.0.0.1:$PORT/cargo/CARGO-USNYC-DEHAM")"
assert_eq "$EXPECTED_JSON" "$BODY" "wasmtime serve GET /cargo/CARGO-USNYC-DEHAM"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/cargo/NOPE")"
assert_eq "404" "$CODE" "wasmtime serve GET /cargo/NOPE"
```

`wasmtime serve -S cli` is the one-process path the wasmtime chapter introduced: no embedding host code to write, just a CLI invocation that serves `wasi:http/incoming-handler` directly over a real socket. The committed evidence from a verified 2026-10-21 run against this exact script shows both asserts passing:

```
$ curl -s http://127.0.0.1:8000/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8000/cargo/NOPE
404
```

(That evidence file, `examples/part4-runtimes/wasmcloud/evidence/2026-10-21/04-http.txt`, is captured against the wasmCloud side by `capture-evidence.sh` on port 8000; `prove-same-bytes.sh` asserts the identical two results against `wasmtime serve` on its own port, 18210: two different ports, same JSON, same status codes, because it's the same component answering both.)

`capture-evidence.sh` is the wasmCloud side, run against the identical file, through `wash app deploy wadm.yaml`:

```
$ wash app deploy wadm.yaml

Deployed application "cargo-http", version "v0.0.1"
```

```
$ wash app status cargo-http

cargo-http@ - Deployed

  Name                                     Kind           Status
  cargo_http                               SpreadScaler   Deployed
  httpserver -(wasi:http)-> cargo_http     LinkScaler     Deployed
  httpserver                               SpreadScaler   Deployed
```

The `wadm.yaml` manifest driving that deploy names the same file the wasmtime side reads, with a comment that states the point directly: "The same bytes also run under `wasmtime serve`, see ch16 / prove-same-bytes.sh." against `image: file://./app.wasm`. And the sha256 captured on this side closes the loop:

```
$ sha256sum app.wasm
eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3  app.wasm
```

That hash is recorded in `examples/part4-runtimes/wasmcloud/evidence/2026-10-21/06-sha256.txt`, committed alongside the rest of the captured run. `prove-same-bytes.sh` computes the identical hash from the identical file on the wasmtime side before it ever starts `wasmtime serve`; both scripts are reading the same `app.wasm` on disk, in the same checkout, which is the simplest possible proof that the bytes match: there is only one file, and both runtimes point at it. The README's "Verified run (2026-10-21)" section states the finding in one line: "`app.wasm` sha256 `eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3`, identical under wasmCloud and `wasmtime serve`." The curl results on both sides are not merely similar; they are the identical JSON string and the identical HTTP status, because the handler answering the request is the identical set of instructions on both sides of the comparison.

## What each runtime asks you to own

The sha256 match answers whether the artifact is portable. It does not answer which runtime to run it under, and that is a different question with a different answer depending on what you're deploying and who operates it afterward.

`wasmtime` asks you to own a process. The wasmtime chapter covered the embedding path in depth: your own host binary links `wasmtime` as a library, builds an `Engine` and a `Store`, satisfies whatever imports the component declares (host-provided capabilities, fuel and epoch budgets, a `ResourceLimiter`), and calls into the component's exports directly from your own code. `wasmtime serve -S cli`, the path this chapter's proof uses, is the version of that same idea with the host code already written for you: point the CLI at a component that exports `wasi:http/incoming-handler`, grant it the capabilities it needs with `-S` flags, and it serves HTTP on a socket with no Rust or Go host code to write at all. Either way, the operational unit is one process. There is no lattice to bring up, no NATS to run, no `wadm` reconciliation loop watching your component's instance count. If that process dies, nothing in wasmtime itself restarts it; that's a property of whatever supervises the process from outside (`systemd`, a container runtime's restart policy, a Kubernetes `Deployment`, which Part 5 covers). The operational surface is the smallest it can be: one binary, one thing to monitor, one thing to restart.

wasmCloud asks you to own a lattice instead of a process, and gets something back for the extra surface. The wasmCloud chapter built this out: `wash up` brings up NATS and the wasmcloud host; `wash app deploy` applies a `wadm.yaml` manifest declaring components, capability providers, and the links between them; the `httpserver` provider in this chapter's example is a separate, independently versioned piece (`ghcr.io/wasmcloud/http-server:0.27.0`) that opens the actual TCP listener and translates inbound HTTP into calls on the component over `wasi:http/incoming-handler`; the component itself never touches a socket. That indirection is what buys the resilience property the wasmCloud chapter demonstrated, and this chapter's evidence confirms it happened again on the same deploy: scaling the component to zero instances with `wash scale component ... --max-instances 0` leaves the `httpserver` provider's listener running, so traffic fails loudly (`500`, "failed to invoke `wrpc:http/incoming-handler`") rather than silently dropping, and `wadm`'s `SpreadScaler` reconciles the component back to its declared instance count without anyone running a redeploy:

```
$ wash scale component <host> file:///…/app.wasm cargo_http-cargo_http --max-instances 0
Component [cargo_http-cargo_http] (ref: [file:///…/app.wasm]) scaled on host [...] to 0 max concurrent instances

500
fail_observed=1

recovered after 2s

GET /cargo/CARGO-USNYC-DEHAM -> 200  {"tracking_id":"CARGO-USNYC-DEHAM",...}
fail_observed=1 recovered=1
```

Two seconds from forced failure to recovered `200`, with no human or external automation involved, is `wadm`'s declarative reconciliation working exactly as designed, and it is not something `wasmtime serve` running alone gives you. The cost of that property is the lattice itself: a wasmCloud host, NATS, `wadm`, and however many capability providers a given application needs are all now things that exist, run, and can themselves need upgrading or monitoring, on top of whatever components they're hosting. A single-instance proof-of-concept gets little benefit from that machinery and pays its full operational cost; a service that needs to survive instance failure, scale across multiple hosts, or swap a capability provider (a different `httpserver` implementation, a message-queue provider instead of HTTP) without touching component code is the case that justifies running the lattice.

{% include excalidraw.html file="16-single-process-vs-lattice-matrix" alt="A comparison matrix with two columns, wasmtime (single process, you own the host) and wasmCloud (distributed lattice, wadm owns placement), across four row axes. Control: wasmtime embeds it or serves it directly, you write the host code; wasmCloud declares it in wadm.yaml, the lattice places and links it. Operational surface: wasmtime is one binary, one process, lowest surface to operate; wasmCloud is NATS plus wadm plus host(s) plus providers, more moving parts to run. Resilience: wasmtime has no built-in restart, whatever supervises the process; wasmCloud's SpreadScaler self-heals, scale-to-0 recovered in about 2 seconds per the wasmCloud chapter's evidence. Scale: wasmtime scales by running more processes, your own orchestration; wasmCloud's multi-host lattice scale-out is built into the platform. A closing banner spanning both columns: Part 5 adds a third, orthogonal axis, Kubernetes schedules either runtime as a pod, same choice, one layer up. A note states neither column is the default; pick the row that matches what this deployment needs to own." caption="Figure 16.2: four axes for choosing a runtime per component; Kubernetes in Part 5 is a separate axis on top of this one, not a replacement for it." %}

This is also the right place to name where Part 5 fits, because it's a question that comes up the moment someone reads this comparison and asks "but don't we run everything on Kubernetes anyway?" The answer is that Kubernetes is a third axis, not a resolution of this one. Part 5 covers running either runtime's workload as a pod: `wasmtime` behind a `RuntimeClass` using a Wasm-aware shim, or a wasmCloud host itself scheduled as a workload in the cluster. That's a scheduling and packaging decision: where does the process (or the lattice's hosts) physically run, under whose orchestration, with whose resource limits. It does not change anything this chapter's comparison covers. A single-process `wasmtime serve` component scheduled onto a Kubernetes pod is still a single process with no lattice underneath it; a wasmCloud lattice running across pods is still a lattice with `wadm` reconciling it, just with Kubernetes also supervising the pods the hosts run in. Decide the runtime question this chapter poses first, on its own merits for the component in front of you, then decide separately in Part 5 whether and how that choice gets scheduled onto a cluster.

## The caveat the "same bytes" claim needs

"Same bytes, two runtimes" is true and verified, but incomplete without the one real exception this site's own evidence surfaced. The artifact is identical; the two runtimes executing it are not behaviorally identical in every respect, and the wasmCloud chapter's capture run hit the gap directly, as a host WARN logged the moment the component started:

> `exported component resources are not supported in wasmCloud runtime and will be ignored`

The Component Model and WIT introduced `resource` as WIT's one vocabulary item for a handle to stateful, identity-bearing state rather than a plain value: `handling.wit`'s `cargo-tracker`, constructed once from a `tracking-id` and then queried repeatedly for its status and history. `app.wasm`'s `handling` interface exports that resource. `wasmtime serve` runs the component exactly as built: every export, including `cargo-tracker`, is live and callable, because `wasmtime` doesn't selectively drop pieces of a component's export surface. wasmCloud's runtime does something different: it logs that WARN and ignores the exported resource outright, rather than making it reachable through the lattice.

That gap does not surface anywhere in this chapter's proof, and understanding exactly why matters more than the gap itself. The HTTP path this chapter's `curl` requests exercise goes through `wasi:http/incoming-handler`, which the `http-rust` front door, built for serving HTTP from a component, implements by calling into the composed component's `booking` interface, `get-cargo` in particular, for the `GET /cargo/{id}` route this chapter's evidence asserts against. `booking`'s functions all operate on plain `record` values (a `cargo`, a `booking`, an `itinerary`); nothing on the path this chapter tests touches `cargo-tracker` at all. The resource being ignored and the HTTP path being unaffected are two separate, true facts about the same deploy, not one fact papering over the other: a component built to expose the `handling` interface's resource directly to a lattice consumer, rather than only through HTTP handlers that happen not to need it, would behave differently on wasmCloud than on wasmtime, and that difference would be a real functional gap, not a cosmetic one. The fix for that shape of component, named in the wasmCloud chapter, is to put the stateful behavior behind a capability provider instead of an exported resource; a provider is wasmCloud's own mechanism for stateful, identity-bearing state in the lattice, and it's the idiomatic place for this exact pattern to live once a deployment needs it reachable from outside the component.

The general rule applies beyond `cargo-tracker`: "the same component model, portable by construction" is a true statement about the Component Model's compilation and linking story, proven concretely by this chapter's matching sha256, and it is not automatically a true statement about every runtime behaving identically against every corner of a component's export surface. Read a target runtime's own documentation and startup logs for a component before assuming full fidelity, especially for WIT features, resources chief among them in this site's experience, that describe identity and lifecycle rather than plain data. The win this chapter demonstrates is real and large: build once, validate the contract once, and nearly all of a typical component's behavior, certainly everything this HTTP-fronted domain uses, travels unchanged between a single process and a distributed lattice. The remaining caveat is narrow, named precisely, and worth checking for, not worth hedging about in general terms.

## Build, run, observe

```bash
cd examples/part4-runtimes/wasmcloud && ./build.sh && ./prove-same-bytes.sh
```

`build.sh` produces `app.wasm` by `wac plug`-composing the Part 2 Rust cargo provider under the Part 3 http-rust front door, the same artifact `capture-evidence.sh` deploys into wasmCloud's lattice. `prove-same-bytes.sh` then takes that exact file, hashes it with `sha256sum`, starts `wasmtime serve -S cli` against it on a local port, and asserts the same two HTTP checks the wasmCloud lattice run makes: `GET /cargo/CARGO-USNYC-DEHAM` returns the cargo JSON and `GET /cargo/NOPE` returns `404`. A successful run prints the sha256 once and both assertions passing; comparing that hash against the one `capture-evidence.sh` records under `evidence/<date>/06-sha256.txt` is the chapter's whole proof that one build runs unchanged under both runtimes. See `examples/part4-runtimes/wasmcloud/README.md` for the full script table.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Default to <code>wasmtime</code>, embedded via its library API or invoked directly with <code>wasmtime serve</code> as this chapter's proof does, when a single process is the correct operational unit: a proof of concept, a component with no requirement to survive instance failure on its own, or a deployment where something above wasmtime (a container restart policy, a Kubernetes <code>Deployment</code>, Part 5's scheduling) already supplies the restart and scale-out behavior a lattice would otherwise provide. Reach for wasmCloud when the component needs the lattice's own properties as first-class behavior: self-healing without an external restart policy (this chapter's scale-to-0 recovery in roughly two seconds, reconciled by <code>wadm</code>'s <code>SpreadScaler</code> with no redeploy), multi-host scale-out coordinated declaratively rather than by hand, or capability providers that let you swap an HTTP server, a message queue, or a key-value store underneath a component without touching or rebuilding the component itself. Before deploying any component to wasmCloud, check its WIT surface for exported resources the way this chapter's <code>cargo-tracker</code> check did: a component whose domain logic depends on a lattice consumer calling an exported resource directly needs that state moved behind a capability provider first, because wasmCloud will ignore the resource export rather than refuse to start. Make the runtime choice on these four axes before Part 5's Kubernetes scheduling question, not instead of it: the two decisions compose, they don't substitute for each other.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model's portability guarantees across hosts and runtimes, the structural claim this chapter's sha256 match makes concrete.
- Shashank Jain, *WebAssembly for Cloud* (Apress): operational trade-offs between embedding a Wasm runtime directly and running it under a distributed orchestration layer, covered at the scale this chapter's control/ops-surface/resilience/scale axes summarize.
- [Bytecode Alliance, WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): the canonical ABI both `wasmtime` and the wasmCloud host implement, which is what makes one artifact's bytes meaningful to both without a runtime-specific rebuild.
- [wasmCloud documentation](https://wasmcloud.com/docs/): the lattice, `wadm` application manifests, and capability-provider model this chapter's "own a lattice" side draws on, including provider-based alternatives to an exported resource.
- The Component Model and WIT: the `resource` vocabulary item and the `cargo-tracker` definition this chapter's caveat section depends on directly.
- HTTP from a component: the `http-rust` front door and its `wasi:http/incoming-handler` implementation that both runtimes in this chapter serve identically.
- wasmtime: embedding, `Store`/`Engine` controls, and `wasmtime serve`, the single-process side of this chapter's comparison.
- wasmCloud: the lattice, `wadm`, capability providers, and the self-healing scale-to-0 demonstration this chapter's resilience row cites directly.
- Part 5, "Wasm on Kubernetes": scheduling either runtime as a cluster workload, the orthogonal third axis this chapter's closing section places relative to the wasmtime/wasmCloud choice.

---
title: "wasmtime and wasmCloud Together"
order: 16
part: "Runtimes: wasmtime & wasmCloud"
description: "One WIT-conformant component, built once, runs byte-for-byte identical on wasmtime and on wasmCloud. This covers the portability payoff of contract-first design, the one real behavioral gap between the runtimes, and when to pick each."
duration: "11 min read"
---

## Learning objectives

By the end of this chapter you can:

- State the portability claim precisely: `app.wasm`, built once, has the identical sha256 whether it runs under `wasmtime serve -S cli` or is deployed into a wasmCloud lattice by `wadm`, and explain why the WIT contract makes that identity structural and not accidental.
- Find where the two scripts record a sha256 on each side and the two curl results each asserts.
- Choose between wasmtime and wasmCloud by naming what each makes you own: a process and its host code, or a lattice of hosts, providers and links reconciled by `wadm`.
- Name the one behavioral difference that matters for this domain (wasmCloud ignores exported component resources, wasmtime does not) and say why the HTTP path never shows it.
- Place the runtime choice relative to Kubernetes scheduling: a separate, later decision.

## Why this matters

A WIT contract exists independently of any implementation. A Rust component and a Go component each build against it once, composition joins them by WIT identifier and not by source language, and an HTTP front door sits in front of the result. Wasmtime then runs that artifact embedded or served directly, and wasmCloud moves it into a lattice, replacing direct host wiring with a capability provider and a declarative link. The component's bytes never change because the runtime around them does. `sha256sum` turns that from an implication into a check.

The check is anticlimactic, which is the point. `build.sh` produces one file, `app.wasm`, by plugging the Rust `cargo` provider under the `http-rust` front door. `prove-same-bytes.sh` runs that file under `wasmtime serve -S cli`, and `wadm.yaml` deploys the same `file://./app.wasm` into the lattice through `capture-evidence.sh`. The two execution models differ completely, one process linking a component directly and the other a set of hosts coordinated over NATS, yet the artifact entering both is the same file. This is a consequence of the Component Model's boundary between contract and implementation: a component's exports are defined by WIT, a runtime satisfies imports and calls exports, and nothing in that requires the runtime to see or change the component's bytes.

Knowing how each runtime works does not say which to run a given component under. The comparison below uses the same artifact and names the one place the runtimes diverge.

{% include excalidraw.html file="16-same-bytes-two-runtimes" alt="One app.wasm box at the top, built once by build.sh with sha256 eff7f5ee81db5f9f...4c9909b3, fans out into two bands. The left band, wasmtime serve -S cli, is a single process that loads the component directly; GET /cargo/CARGO-USNYC-DEHAM returns 200 with the cargo JSON and GET /cargo/NOPE returns 404. The right band, the wasmCloud lattice, has the httpserver provider linked to the cargo-http component by wadm.yaml and returns the identical 200 JSON and the identical 404. A bottom banner reads: identical JSON, identical sha256, one build, two runtimes, no rebuild. A note gives the one caveat: wasmCloud ignores exported component resources (the cargo-tracker resource) with a WARN at start, harmless here because the HTTP path uses only booking, while wasmtime serve runs the resource as built." caption="Figure 16.1: one app.wasm on two runtimes with identical behavior on the path the component exercises." %}

## The same bytes, checked

`build.sh` is the single source of truth for the artifact both sides consume. Its last step composes the provider and the front door:

```bash
echo "build.sh: [3/3] composing app.wasm (wac plug: provider -> http front door) ..."
wac plug --plug "$PROVIDER" "$HTTP" -o "$OUT"
wasm-tools validate "$OUT"
```

The output exports `wasi:http/incoming-handler`, the one interface both runtimes need to serve HTTP over it. `prove-same-bytes.sh` is the wasmtime side: it hashes the artifact and serves it with `wasmtime serve -S cli "$APP" --addr "127.0.0.1:$PORT"`, the single-process path with no host code to write.

```bash
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

SHA="$(sha256sum "$APP" | awk '{print $1}')"
echo "app.wasm sha256: $SHA"
```

```bash
BODY="$(curl -s "http://127.0.0.1:$PORT/cargo/CARGO-USNYC-DEHAM")"
assert_eq "$EXPECTED_JSON" "$BODY" "wasmtime serve GET /cargo/CARGO-USNYC-DEHAM"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/cargo/NOPE")"
assert_eq "404" "$CODE" "wasmtime serve GET /cargo/NOPE"
```

The wasmCloud side deploys the same file through `wash app deploy wadm.yaml`, and the manifest's `image: file://./app.wasm` points at it. The recorded run on that side returns the identical response and the hash:

```
$ curl -s http://127.0.0.1:8000/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8000/cargo/NOPE
404
```

```
$ sha256sum app.wasm
eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3  app.wasm
```

Both scripts read the same `app.wasm` in the same checkout, so there is one file and both runtimes point at it. The two curl runs use different ports (8000 under wasmCloud, 18210 under `wasmtime serve`) and return the same JSON and status codes, because the same component answers both.

## What each runtime asks you to own

The sha256 match settles portability. It does not say which runtime to run, which depends on what you deploy and who operates it.

| | wasmtime | wasmCloud |
|---|---|---|
| **Control** | Embed the crate or serve with the CLI; you write or choose the host | Declare components, providers and links in `wadm.yaml`; the lattice places and links them |
| **Operational surface** | One binary, one process | NATS, wadm, host(s) and providers |
| **Resilience** | None built in; whatever supervises the process restarts it (`systemd`, a container restart policy, a Kubernetes `Deployment`) | The SpreadScaler self-heals; scale-to-zero recovered in about two seconds |
| **Scale** | Run more processes under your own orchestration | Multi-host lattice scale-out is part of the platform |

{% include excalidraw.html file="16-single-process-vs-lattice-matrix" alt="A comparison matrix with two columns, wasmtime (single process, you own the host) and wasmCloud (distributed lattice, wadm owns placement), across four rows. Control: wasmtime embeds or serves directly and you write the host code; wasmCloud declares everything in wadm.yaml. Operational surface: wasmtime is one binary and one process; wasmCloud is NATS plus wadm plus hosts plus providers. Resilience: wasmtime has no built-in restart; wasmCloud's SpreadScaler self-heals, with scale-to-0 recovered in about 2 seconds. Scale: wasmtime scales by running more processes; wasmCloud scales out across a multi-host lattice. A closing banner says Kubernetes adds a third, orthogonal axis, scheduling either runtime as a pod. Neither column is the default." caption="Figure 16.2: four axes for choosing a runtime per component; Kubernetes scheduling is a separate axis on top of this one." %}

Wasmtime asks you to own a process. `wasmtime serve -S cli` is the embedding idea with the host code already written: point it at a component that exports `wasi:http/incoming-handler`, grant capabilities with `-S` flags, and it serves on a socket. The operational surface is the smallest it can be.

wasmCloud asks you to own a lattice. `wash up` brings up NATS and the host, and `wash app deploy` applies a manifest of components, providers and links. The `httpserver` provider (`ghcr.io/wasmcloud/http-server:0.27.0`) is a separate, independently versioned process that opens the listener and translates HTTP into calls on the component, which never touches a socket. That indirection buys the resilience property: scaling the component to zero with `wash scale component ... --max-instances 0` leaves the provider's listener up, so traffic fails loudly with a `500` ("failed to invoke `wrpc:http/incoming-handler`") instead of dropping, and `wadm`'s `SpreadScaler` restores the declared instance count with no redeploy:

```
# scale the component to 0 instances (provider/listener stays up)
$ wash scale component <host> file://<repo>/examples/part4-runtimes/wasmcloud/app.wasm cargo_http-cargo_http --max-instances 0
Component [cargo_http-cargo_http] (ref: [file://<repo>/examples/part4-runtimes/wasmcloud/app.wasm]) scaled on host [NCQR6FIQCONSILLUFUMAENAPFDCRP223B53PRVRR42HSOA4NYFW3SYPC] to 0 max concurrent instances

# burst while the component is gone: the provider answers but the
# invoke fails (no component to handle it) -> non-200
500 
fail_observed=1

# wadm reconciles the SpreadScaler back to 1 instance; poll to recovery
recovered after 2s

# after: service healthy again
GET /cargo/CARGO-USNYC-DEHAM -> 200  {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
fail_observed=1 recovered=1
```

The cost is the lattice itself: a host, NATS, `wadm` and every provider are things that run and need upgrading and monitoring. A single-instance proof of concept pays that cost for little. A service that must survive instance failure, scale across hosts, or swap a capability provider (another HTTP server, a message-queue provider) without touching component code is what justifies it.

Kubernetes is a third axis, not a resolution of this one. It can run either runtime's workload as a pod: wasmtime behind a `RuntimeClass` with a Wasm-aware shim, or a wasmCloud host scheduled as a workload. That decides where the process or the lattice's hosts run and under whose limits. A `wasmtime serve` pod is still one process with no lattice; a lattice across pods is still reconciled by `wadm`. Decide the runtime on its merits for the component first, then decide separately how to schedule it.

## The caveat the same-bytes claim needs

The artifact is identical, but the runtimes do not behave identically in every respect. The wasmCloud host logs a WARN as the component starts:

> `exported component resources are not supported in wasmCloud runtime and will be ignored`

WIT's `resource` is a handle to stateful, identity-bearing state, and `handling.wit` exports one: `cargo-tracker`, constructed once from a `tracking-id` and then queried for status and history. `wasmtime serve` runs every export, resource included. wasmCloud ignores the resource export instead of making it reachable through the lattice.

The gap does not show in the HTTP path. The `http-rust` front door serves `GET /cargo/{id}` by calling `get-cargo` on the `booking` interface, which operates on plain `record` values and never touches `cargo-tracker`. A component built to expose the resource directly to a lattice consumer would behave differently on wasmCloud, and that would be a functional gap, not a cosmetic one. The fix is to put the stateful behavior behind a capability provider, wasmCloud's own mechanism for identity-bearing state.

The general rule goes beyond `cargo-tracker`. Portable by construction is true of the Component Model's compile and link story; it is not automatically true of every runtime against every corner of a component's export surface. Read the target runtime's documentation and startup logs before assuming full fidelity, especially for WIT features that describe identity and lifecycle, resources above all. The caveat is narrow, named precisely and worth checking for.

> **Decision**
>
> Default to wasmtime, embedded or via `wasmtime serve`, when one process is the right operational unit: a proof of concept, a component with no requirement to survive instance failure by itself, or a deployment where something above wasmtime (a restart policy, a Kubernetes `Deployment`) already supplies restart and scale-out. Choose wasmCloud when you need the lattice's properties as first-class behavior: self-healing without an external restart policy, declarative multi-host scale-out, or providers that let you swap an HTTP server, queue or key-value store beneath an unchanged component. Before deploying any component to wasmCloud, check its WIT for exported resources: state a lattice consumer needs through a resource must move behind a capability provider first, because wasmCloud ignores the export instead of refusing to start. Decide the runtime on these four axes before the Kubernetes scheduling question, not instead of it.

> **🤖 Explore with your agent**
>
> "In examples/part4-runtimes/wasmcloud, run `./build.sh`, then `sha256sum app.wasm`, and compare it with the hash `prove-same-bytes.sh` prints. Then list every exported interface of `app.wasm` with `wasm-tools component wit app.wasm`, find which export is a WIT `resource`, and tell me whether the `GET /cargo/{id}` path would break under wasmCloud if it called that resource, using the decision rule above."
>
> Check: the two sha256 values are equal, and the reply names `cargo-tracker` in the `handling` interface as the resource wasmCloud ignores.

## Build, run, observe

```bash
cd examples/part4-runtimes/wasmcloud && ./build.sh && ./prove-same-bytes.sh
```

`build.sh` writes `app.wasm` by plugging the Rust cargo provider under the `http-rust` front door, the same artifact `capture-evidence.sh` deploys into the lattice. `prove-same-bytes.sh` hashes that file, starts `wasmtime serve -S cli` against it on a local port, and checks `GET /cargo/CARGO-USNYC-DEHAM` returns the cargo JSON and `GET /cargo/NOPE` returns `404`. A passing run prints the sha256 once and a `PASS` line. Compare the hash with the one `capture-evidence.sh` records under `evidence/<date>/06-sha256.txt`. The README has the full script table.

Experiments:

- Change `EXPECTED_JSON` in `prove-same-bytes.sh`: the `wasmtime serve` check fails.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model's portability guarantees across hosts and runtimes.
- Shashank Jain, *WebAssembly for Cloud* (Apress): operational trade-offs between embedding a Wasm runtime and running it under a distributed orchestration layer.
- [Bytecode Alliance, WebAssembly Component Model documentation](https://component-model.bytecodealliance.org/): the canonical ABI both `wasmtime` and the wasmCloud host implement.
- [wasmCloud documentation](https://wasmcloud.com/docs/): the lattice, `wadm` manifests and the provider model, including provider-based alternatives to an exported resource.

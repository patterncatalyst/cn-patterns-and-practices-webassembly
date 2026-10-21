---
title: "Build & Iteration Plan"
layout: plan
render_with_liquid: false
---

# Build & Iteration Plan — API Patterns and Practices: Server-Side WebAssembly

Fifth site in the series (REST → gRPC → GraphQL → WebSockets → this one). A
deliberate deviation from the first four: this site teaches a **runtime and
deployment target**, not an API style. Kubernetes deployment is the point of
the book, not an appendix bolted on at the end.
This document tracks the build iteration by iteration, starting from **r01 —
bootstrap scaffold** (site chrome, the locked outline, and the plans ledger;
no chapter prose, no runnable examples, no WIT contract body) through **r02 —
Foundations + WIT contract** (below).

Repo: `patterncatalyst/cn-patterns-and-practices-webassembly` (public,
remote-first). The `cn-` (cloud-native) prefix marks the
deviation from the four `api-` siblings — this is a runtime/deployment site,
not an API style — while the hub still places it under Cloud Native / API
design alongside REST/gRPC/GraphQL/WebSockets (DRQ-001).

## r01 scope (this iteration)

- Site chrome copied from `api-patterns-and-practices-websockets`: layouts,
  includes, CSS, codetabs JS, `.gitignore`, `.gitattributes`, `Gemfile`,
  `Gemfile.lock`, `LICENSE`, the Pages CI workflow.
- `_config.yml` and `index.html` adapted for identity only (title,
  description, emoji, repo name, baseurl, hero copy, stat tiles).
- The outline locked: 8 Parts (`_parts/`), 30 `_docs/` files (the outline
  page plus Ch0–Ch28), front matter only except Part 0 and Part 1, which
  carry section headings with no prose.
- `scripts/generate_diagram.py` copied with the light-ink emphasis-box
  palette already correct (DRQ-008) — no dark-fill bug to carry forward from
  this source, unlike the gRPC-to-WebSockets handoff.
- `scripts/wordcount.sh` (warn above 2,500 prose words, fail below 2,000),
  copied from the WebSockets sibling.
- Nav stub pages (`_example_pages/index.md`, `bibliography.md`) so the header
  and footer links resolve to a real, if empty, page.
- `contracts/` reserved with a `README.md` placeholder only — the WIT world
  body and its drift-gate CI land in r02+.
- This plan, the decisions log, and a dated placeholder version matrix.

No chapter prose, no runnable examples, and no WIT contract body are written
in r01.

## Locked outline

**Part 0 — Prerequisites**: Ch0 Setup and the lab.
**Part 1 — Foundations**: Ch1–Ch5.
**Part 2 — Building Components in Rust & Go**: Ch6–Ch10.
**Part 3 — Interfaces: HTTP & gRPC**: Ch11–Ch13.
**Part 4 — Runtimes: wasmtime & wasmCloud**: Ch14–Ch16.
**Part 5 — Deploying to Kubernetes**: Ch17–Ch24. Ch19 is OpenShift Local
(CRC) as a **numbered chapter inside this Part**, not an appendix. Ch22 is
HPA/scaling patterns; Ch23 is serverless scale-to-zero with KEDA.
**Part 6 — Deviations**: Ch25 Istio + Wasm, Ch26 other backend architectures
(a survey, anchored on Spin), Ch27 wasi-nn.
**Part 7 — Final Project**: Ch28.

29 chapters, numbered **0–28, gap-free** — no `99-appendix` file. CRC is a
numbered chapter because deploying to Kubernetes is this book's whole point,
a deliberate divergence from the four `api-` siblings, where CRC is a
non-numbered appendix (DRQ-007).

## r02 — Foundations + WIT contract

Part 1 Foundations written to the house depth standard, the cargo-domain WIT
contract authored and validated, and a validate-only contract CI gate wired
up.

- Part 1 Foundations, Ch1–Ch5, written to the house depth standard: Ch1 Why
  server-side Wasm, Ch2 The execution model, Ch3 The Component Model and WIT,
  Ch4 WASI Preview 2, Ch5 The shared cargo domain as components. Each chapter
  carries the house spine (Learning objectives + Why this matters at the top,
  For deeper coverage at the end), paired SVG+Excalidraw diagrams, a concrete
  box, and a Decision callout.
- The cargo-domain WIT world authored at `contracts/wit/` — package
  `patterncatalyst:cargo@0.1.0` split across `types.wit`, `bookings.wit`,
  `handling.wit`, and `world.wit` — validating under wasm-tools 1.262.0
  (DRQ-015).
- A validate-only contract CI gate (`.github/workflows/contracts.yml`)
  running `wasm-tools component wit contracts/wit`, with wasm-tools installed
  from a pinned, checksummed GitHub release binary rather than built from
  source on every run (DRQ-016, DRQ-017).
- The version matrix surveyed and pinned (2026-10-20).
- The hub entry on `patterncatalyst/workshops-tutorials-list`, added at the
  end of r02 now that there is real content to point to: five chapters and a
  validated contract (DRQ-019).

## r03a — Building Components: the build spine

Part 2's first half: Ch0 Setup, Ch6 (Rust), and Ch7 (Go), backed by the
site's first runnable examples — one shared WIT world implemented in both
languages under `examples/part2-building-components/` (`rust/` + `go/` +
`host/` + `fixtures/` + `verify.sh`) — plus the full WIT-drift CI gate
promised at DRQ-016, now landed as an extension of `contracts.yml`: an
examples build+run job, a bindings-regeneration diff check, and a
world-conformance diff against `contracts/wit` (DRQ-022, DRQ-024).

The headline finding is a reversal. DRQ-013 assumed standard `go build`
would be the primary Go path, with TinyGo as an optional sidebar; r03a
proved that wrong. Standard Go cannot emit Component Model exports at all,
and **TinyGo 0.43.0 is the Go compiler** this site builds on from here out
(DRQ-021). Go source and the generated `wit-bindgen-go` bindings stay
ordinary, idiomatic Go — only the compiler differs.

The native Rust `wasmtime` host that drives both components to
byte-identical output (DRQ-023) doubles as the seed for Ch8's
polyglot/compose chapter.

## r03b — Part 2 completion: composition, debugging, errors

Ch8 (composing and polyglot components), Ch9 (debugging), and Ch10 (error
handling), all written against an extended version of the r03a example tree
rather than new ones: the Rust and Go **provider** components from r03a gain
two new **consumer** components (Rust and Go, both `wasi:cli/run` COMMAND
components, DRQ-028) plus a 4-way `wac plug` composition across every
{Rust, Go} consumer × {Rust, Go} provider pairing (DRQ-027, DRQ-030), and the
error/trap test paths that back Ch10's taxonomy (DRQ-034). The CI drift gate
in `contracts.yml` (DRQ-024) is extended to install `wac` and regenerate the
consumer-side bindings alongside the existing provider bindings check.

The headline build finding is the command-adapter/Go-heap `cabi_realloc`
early-init trap (DRQ-032): the COMMAND adapter calls `cabi_realloc` during
`_start`, before TinyGo's heap is ready, so the Go consumer needs a static
bump-arena allocator rather than the heap-backed one providers use. Related
findings recorded for Ch8–Ch10: `wac` composes across WASI 0.2.x minor-version
skew without a workaround (DRQ-033); composed-artifact bytes are
non-deterministic upstream (wac#216), so equivalence is asserted on runtime
output, never on bytes (DRQ-031); and TinyGo's one-shot `-target=wasip2`
remains unusable for the consumer for the same adapter-pinning reason Ch7
found for the provider (DRQ-035).

**Part 2 (Building Components, Ch6–Ch10) is now COMPLETE.** Combined with
Ch0 Setup, which shipped in r03a, every chapter in Parts 0–2 has prose, a
runnable example, and a passing CI gate.

## r04 — Part 3: Interfaces (HTTP & gRPC)

Ch11 (HTTP from a component), Ch12 (gRPC with Wasm), and Ch13
(wasi-sockets: networking, reconnect, resilience), backed by a **new**
example tree, `examples/part3-interfaces/`, that depends on the pristine
`contracts/wit` package and builds on — without editing — the Rust and Go
provider components from Part 2 (DRQ-036).

- **Ch11 wasi-http**: components export `wasi:http/incoming-handler` under
  the `wasi:http/proxy` world, wac-composed with the Part 2 provider, served
  with `wasmtime serve -S cli`. Both the Rust (`cargo-component`) and TinyGo
  (reactor) builds run and return byte-identical JSON (DRQ-037). Two build
  gotchas recorded for the chapter: `wasmtime serve` needs `-S cli`, because
  the proxy-world linker otherwise omits `wasi:cli/environment` and
  `wasi:filesystem`; and `cargo-component` does not auto-scan `wit/deps`, so
  every `wasi:*` interface and the cargo contract itself need an explicit
  path dependency.
- **Ch12 gRPC** ships two artifacts (DRQ-038): protobuf running
  server-side **inside** a component — `prost` in Rust (runnable), and a
  hand-written reflection-free wire codec in TinyGo, byte-identical to the
  Rust output, because `google.golang.org/protobuf` compiles under TinyGo
  0.43 but traps at runtime (`reflect.Type.MethodByName` unimplemented);
  and a host-mediated **tonic bridge**, because a fully in-component gRPC
  server isn't possible today (no Wasm runtime exposes an HTTP/2 server
  surface) — the bridge terminates gRPC/HTTP/2 on the host and calls the
  unchanged Wasm provider, the "gRPC in front of Wasm" pattern. Both
  artifacts are runnable.
- **Ch13 wasi-sockets**: an outbound TCP client with reconnect and
  exponential-backoff-with-jitter, demonstrating capability-scoped
  networking (`wasmtime -S inherit-network`; `access-denied` without it).
  Rust is the live, running proof. TinyGo's `wasi:sockets` support has no
  clean runtime path on 0.43 — command-world traps on a `random_get`
  adapter assertion at `_start`, reactor-world's asyncify `pollable.block`
  never resolves `connect`/timer calls under a hand-rolled host — so the Go
  side stays build-and-validate only (DRQ-039). wasmCloud link/lattice
  resilience is deferred to Part 4, cross-referenced here only.
- CI: `contracts.yml` extended with a pinned protoc 36.2, the Part 3
  `verify.sh`, and the Part 3 bindings added to the drift gate; job timeout
  raised to 60 minutes (DRQ-040).

**Part 3 (Interfaces, Ch11–Ch13) is now COMPLETE.**

## r05 — Part 4: Runtimes (wasmtime & wasmCloud)

Ch14 (wasmtime embedding, CLI, and the host API), Ch15 (wasmCloud lattice,
providers, and links), and Ch16 (wasmtime and wasmCloud together), backed by
a new `examples/part4-runtimes/` tree: a `wasmtime-host/` component + native
Rust host, CI-gated like Part 2/3, and a `wasmcloud/` application (wadm
manifest + the same cargo component, httpserver provider 0.27.0 linked over
`wasi:http/incoming-handler`), verified live rather than in CI (DRQ-042).

- **Ch14 wasmtime-host**: the native host demonstrates three host-provided
  controls, each proven against a clean contrast run — fuel exhaustion
  (`OutOfFuel`), an epoch deadline (`Interrupt`), and a `ResourceLimiter`
  denying `memory.grow` (DRQ-043).
- **Ch15 wasmCloud**: `wash up` launches nats-server 2.11.3 + wadm 0.21.1 +
  wasmcloud host 1.9.1 (DRQ-041); the wadm manifest links the httpserver
  provider 0.27.0 to the cargo component's `wasi:http/incoming-handler`
  export at `0.0.0.0:8000` (DRQ-044). The orchestrator ran `wash up` → `wash
  app deploy` → the httpserver link → a curl against the running component →
  a resilience check headless, and committed the run as evidence under
  `examples/part4-runtimes/wasmcloud/evidence/2026-10-21/` (DRQ-042).
- **Ch16 wasmtime and wasmCloud together**: one `app.wasm` (sha256
  `eff7f5ee…`) runs unmodified under `wasmtime serve -S cli` and on
  wasmCloud — the same-bytes proof (DRQ-046). This also delivers the
  wasmCloud resilience story deferred from Ch13 (DRQ-039). A real behavior
  difference surfaced in the process: wasmCloud ignores the cargo domain's
  exported component resource, documented upstream as unsupported; the HTTP
  path is unaffected, so Ch16 carries this as a caveat, not a blocker
  (DRQ-045).
- wasmCloud CLI pin corrected during this iteration: **wash 0.43.0 stable**,
  not the docs' phantom "2.10.1" and not the 2.0 release-candidate line
  (DRQ-041).
- Build gotchas recorded for Ch14–16: `wasmtime::Error` needs a `.wc()` shim
  plus a `Trap` downcast, not `anyhow`; a denied `memory.grow` surfaces as a
  trap, not a clean `Err`; `wash app status: deployed` means accepted, not
  ready — the gate is an HTTP 200; and `file://./app.wasm` resolves against
  `wash`'s working directory (DRQ-047).

**Part 4 (Runtimes, Ch14–16) is now COMPLETE.**

## r06 — Part 5: Deploying to Kubernetes

The big cluster Part — Kubernetes deployment is this book's subject, not an
appendix (DRQ-010). Ch17 (Wasm on Kubernetes: the containerd Wasm shim /
runwasi, and a `RuntimeClass`), Ch18 (deploying on minikube: docker driver +
containerd runtime + the Wasm shim, plus the wasmCloud operator), Ch19
(OpenShift Local / CRC, a numbered chapter per DRQ-007), Ch20 (sidecar),
Ch21 (ambassador/adapter), Ch22 (HPA scaling), Ch23 (serverless
scale-to-zero with KEDA — the HTTP add-on plus the Kafka scaler, per
DRQ-006), and Ch24 (observability: OTel + the LGTM stack). Both the minikube
and CRC paths are verified live headless (DRQ-010); minikube and CRC are
already installed on this box (both currently stopped).

## r06a — Part 5: Deploying to Kubernetes (minikube substrate)

Ch17 (Wasm-on-Kubernetes concepts: the containerd Wasm shim landscape,
`RuntimeClass`, and workload placement) and Ch18 (a live minikube deploy
through the raw runwasi shim, verified), backed by a new
`examples/part5-kubernetes/` tree: build/package the component as a `FROM
scratch` OCI image (DRQ-051), the Kubernetes manifests (base + a minikube
kustomize overlay), an `install-shim` step that installs
`containerd-shim-wasmtime` directly on the node, a verify step that exercises
the real `nip.io` Ingress path (DRQ-049), and evidence capture.

- **Ch17** covers the shim landscape (runwasi's `containerd-shim-wasmtime`
  alongside the wasmer/wasmedge/wamr siblings), how a `RuntimeClass` routes a
  Pod to a non-OCI shim, and where a Wasm workload fits in a cluster's
  placement story relative to an ordinary container Pod.
- **Ch18** deploys the cargo component live on minikube, go/no-go'd against
  the raw runwasi shim rather than reaching for the wasmCloud operator:
  runwasi#1004 did not reproduce, so the operator fallback wasn't needed
  (DRQ-048). Verified over the real Ingress path, never a port-forward or
  tunnel (DRQ-049), and verified headless with evidence committed before the
  footer flips to "verified live" (DRQ-050).
- Build gotchas recorded for the chapters: the shim binary is a containerd
  shim, not a CLI; `minikube ssh` can't take a piped heredoc, so the shim
  install uses `minikube cp` + `sudo bash`; the shim installs (and bounces
  every Pod on the node) before the ingress addon goes in; and readiness
  gates on a real HTTP 200, not rollout-Ready (DRQ-052).
- CI stays a static manifest gate only — `kubectl kustomize | kubeconform
  -strict` over the Part 5 manifests — never a live cluster bring-up
  (DRQ-053).
- The version matrix's Part 5 minikube tier (runwasi shim v0.6.1, minikube
  v1.39.0, Kubernetes v1.37.1, containerd v2.3.4, ingress-nginx v1.15.1,
  kubeconform v0.8.0) is now FIRM, re-surveyed and verified live rather than
  a snapshot.

**Ch17 and Ch18 are COMPLETE. Part 5 (Ch17–Ch24) is IN PROGRESS.**

## r06b — Part 5: Deploying to Kubernetes (OpenShift Local / CRC)

Ch19, OpenShift Local (CRC) — the numbered chapter inside Part 5 per
DRQ-007 — deploying the same cargo component to a second cluster target
through the **wasmCloud operator** rather than the raw runwasi shim Ch18
used on minikube (DRQ-054), backed by the new
`examples/part5-kubernetes/openshift/` tree: the v1 wasmCloud platform Helm
chart, the `WasmCloudHostConfig` and OAM `Application` manifests, a
`ghcr-pull` image-pull Secret, and evidence capture.

- The CRC path diverges from minikube by design, not by default: the raw
  containerd Wasm shim needs a privileged RHCOS MachineConfig that doesn't
  fit the `restricted-v2` SCC these chapters hold to, so Ch19 installs the
  **wasmCloud operator** (v1 chart `0.1.2`) instead, pinning the host to
  **1.9.1** over the chart's stale 1.2.1 default (DRQ-054).
- The same `app.wasm` (sha256 `eff7f5ee…`) that ran on minikube and under
  the Part 4 wasmtime/wasmCloud pair deploys here too, delivered through a
  **private** `ghcr.io/patterncatalyst/cargo-http:crc` image and a
  `ghcr-pull` docker-registry Secret rather than a direct node-image load
  (DRQ-055).
- Live verification is a **CA-verified curl** through an edge-TLS Route —
  no `-k`, no `oc port-forward`, no NodePort — holding the DRQ-049
  no-port-forward rule on OpenShift the same way Ch18 held it on minikube's
  Ingress path (DRQ-056).
- Eight CRC-specific gotchas recorded for the chapter, covering the
  EndpointSlice RBAC grant, the host/provider wRPC version pin, standalone
  NATS, disabling `nats-box`, the OAM-application namespace requirement,
  stale-APIService teardown, HTTP-200 readiness, and the chart's NATS DNS
  repoint (DRQ-057).
- `restricted-v2` compliance required nulling the wadm subchart's
  hard-coded `runAsUser`/`runAsGroup: 1000` so OpenShift assigns a
  platform UID instead; every other chart component already runs
  platform-assigned non-root (DRQ-058).
- CI stays a static manifest gate — `kubeconform -ignore-missing-schemas`
  against the raw OpenShift CRD manifests — with the live CRC bring-up and
  verification captured by hand as evidence, never run inside CI (DRQ-059).
- The version matrix's Part 5 CRC/OpenShift tier (wasmcloud-platform chart
  0.1.2, operator 0.1.5, host 1.9.1, httpserver provider 0.27.0, CRC 2.64.0
  / OCP 4.22.14) is now FIRM, re-surveyed and verified live rather than a
  snapshot.

**Ch19 is COMPLETE. Part 5 is now Ch17–Ch19 done, Ch20–Ch24 remaining.**

## Deferred to later iterations (r07+)

- Part 6–Part 7 chapter prose (Ch25–Ch28), to the house depth standard:
  paired SVG+Excalidraw diagrams, the house chapter spine (Learning
  objectives + Why this matters at the top, For deeper coverage at the end).
- Runnable examples for Part 6 onward, each with its own verify step,
  following the Part 2/3/4 pattern of one shared WIT world built in both
  Rust and Go.
- A dev compose for supporting services plus the LGTM observability stack.
- The companion deck(s) — built LAST, after every chapter and example.

## Release cadence

Iterations ship by Part, never by stack, so the Rust and Go implementations
never diverge. Each iteration ends on a clean `bundle exec jekyll build`.

Roadmap sketch:

- **r01** — scaffold.
- **r02** — Part 1 Foundations prose (Ch1–Ch5) + the cargo-domain WIT
  contract + validate-only contract CI (this iteration).
- **r03a** — Ch0 Setup + Ch6–Ch7 (Rust, Go) + the first runnable examples +
  the full WIT-drift gate (regenerate both bindings, fail on drift).
- **r03b** — Ch8–Ch10 (composing/polyglot, debugging, error handling), on
  the r03a components extended with two consumer components and a 4-way wac
  composition. **Part 2 (Ch6–Ch10) is now COMPLETE** (this iteration).
- **r04** — Part 3 Interfaces: HTTP & gRPC — Ch11 wasi-http, Ch12 gRPC
  (in-component protobuf + a host-mediated tonic bridge), Ch13
  wasi-sockets/reconnect/resilience, on a new `examples/part3-interfaces/`
  tree. **Part 3 (Ch11–Ch13) is now COMPLETE** (this iteration).
- **r05** — Part 4 Runtimes: wasmtime & wasmCloud — Ch14 wasmtime embedding,
  CLI, and the host API; Ch15 wasmCloud lattice, providers, and links
  (`wash` installed here, pinned at 0.43.0, DRQ-041); Ch16 wasmtime and
  wasmCloud together, including the wasmCloud resilience story deferred from
  Ch13 (DRQ-039). **Part 4 (Ch14–Ch16) is now COMPLETE** (this iteration).
- **r06** — Part 5 Kubernetes deployment tiers: Ch17 Wasm on Kubernetes
  (runwasi/containerd shim, `RuntimeClass`), Ch18 minikube, Ch19 OpenShift
  Local/CRC (numbered per DRQ-007), Ch20 sidecar, Ch21 ambassador/adapter,
  Ch22 HPA, Ch23 KEDA scale-to-zero, Ch24 observability (OTel+LGTM) — both
  minikube and CRC verified live headless.
- **r06a** — Ch17 (Wasm-on-Kubernetes concepts) + Ch18 (live minikube deploy
  via the raw runwasi shim, verified over the real Ingress path, no
  port-forwarding) + `examples/part5-kubernetes/`. **Ch17/Ch18 COMPLETE, Part
  5 IN PROGRESS (this iteration).**
- **r06b** — Ch19 OpenShift Local/CRC (wasmCloud operator, `restricted-v2`,
  edge-TLS Routes, verified live headless). **Ch19 COMPLETE, Part 5 at
  Ch17–Ch19 done (this iteration).**
- **r06c** — Ch20 sidecar + Ch21 ambassador/adapter. **Next up.**
- **r06d** — Ch22 HPA + Ch23 KEDA scale-to-zero + Ch24 observability
  (OTel+LGTM). **Part 5 (Ch17–Ch24) COMPLETE** at the end of r06d.
- **r0N** — Part 6 Deviations: Istio+Wasm, the backend-architecture survey
  (Spin), wasi-nn.
- **r0N** — Part 7 Final project.
- **final** — companion decks, mined from the finished chapters and examples.

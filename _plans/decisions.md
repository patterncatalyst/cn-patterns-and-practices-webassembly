---
title: "Decisions Log"
layout: plan
render_with_liquid: false
---

# Decisions Log — API Patterns and Practices: Server-Side WebAssembly

A running log of design-relevant decisions (DRQ = Decision Request/Question),
seeded at r01 bootstrap. Later iterations append; nothing here is renumbered
or deleted.

## DRQ-001 — Repo, prefix, license, and bootstrap posture

Public GitHub repo `patterncatalyst/cn-patterns-and-practices-webassembly`,
MIT license, remote-first: create the GitHub repo first, then branch, then
work — off-device durability from the first commit, matching the four `api-`
sibling sites. User-confirmed 2026-10-20 over the `api-` alternative: the
`cn-` (cloud-native) prefix signals that this is a
runtime/deployment site, not an API style, while the hub entry still lands
under Cloud Native / API design alongside REST/gRPC/GraphQL/WebSockets.

## DRQ-002 — Stack deviation: Rust and Go, not Quarkus/Python

Every hands-on chapter and example ships in **Rust** and **Go**, not the
Quarkus/Python stack the four `api-` siblings use. The reason: the subject
is a runtime/deployment target (WebAssembly
components on Kubernetes), and Rust and Go are the two toolchains with
mature Component Model support (`cargo-component`, standard Go's `wasip1` +
`go:wasmexport`, TinyGo as a sidebar).

## DRQ-003 — Runtimes: wasmtime and wasmCloud, shown separately then together

Two runtimes are taught: **wasmtime** (the reference single-process Wasm
runtime) and **wasmCloud** (the distributed actor/capability runtime). Part 4
introduces them separately, one chapter each, before a third chapter shows
them together in the deployment context the later chapters build on.

## DRQ-004 — Contract spine: WIT / Component Model; drift-gate deferred

**WIT** (the WebAssembly Interface Types language) and the **Component
Model** are this site's contract language — the Wasm analog of the REST
site's OpenAPI, the gRPC site's Protobuf, and the WebSockets site's AsyncAPI.
Authored before any chapter example, used to generate bindings for both the
Rust and Go stacks. r01 reserves `contracts/` with a placeholder `README.md`
only; the WIT world body and its CI drift gate (regenerate both language
bindings, fail on drift) are deferred to r02+.

## DRQ-005 — Shared domain: shipping/cargo

This site carries forward the same shipping/cargo domain and glossary
(Booking, Cargo, Location/UN-LOCODE, Route, Leg, Operation,
Money-as-decimal-string) used by the REST, gRPC, GraphQL, and WebSockets
sibling sites, so the series stays continuous even though the subject matter
here is a runtime, not an API style.

## DRQ-006 — KEDA elevated to first-class: split HPA and scale-to-zero chapters

The PRD's single Ch22 scaling chapter is split into **two numbered
chapters**: **Ch22** (HPA basics and request/CPU-driven scaling patterns) and
**Ch23** (serverless scale-to-zero with **KEDA**: the HTTP add-on for
request-driven scale-from-zero, plus the Kafka scaler for event/lag-driven
scaling). This pays off the fast-cold-start argument that is Wasm's headline
advantage over container cold starts — a component that scales to true zero
and back in milliseconds is a materially different story from HPA alone.
KEDA is a CNCF project, consistent with the house vendor-neutral policy.
User directive 2026-10-20.

## DRQ-007 — CRC as a NUMBERED chapter, not an appendix

Ch19, **OpenShift Local (CRC)**, is a numbered chapter inside Part 5
(Deploying to Kubernetes), not a `99-appendix` file. This is a deliberate
divergence from the four `api-` sibling sites, where CRC is a non-numbered
appendix: on this site, deploying Wasm components to Kubernetes IS the book's
subject, so the second cluster target earns a number in the main sequence
rather than being relegated to back matter. Numbering stays clean and
gap-free, Ch0–Ch28, no gaps.

## DRQ-008 — Diagram convention

Every diagram ships as a paired SVG + `.excalidraw` source via
`scripts/generate_diagram.py`. Emphasis/ink boxes are **light fill, dark
text** (`#f1f5f9` fill, `#64748b` border) — never a dark-filled box — matching
the house diagram standard. Copied forward correctly from the WebSockets
sibling, which already carries the DRQ-008 fix; no dark-fill bug to correct
in this handoff.

## DRQ-009 — The outline is not a scope cap

29 chapters is the **current** locked outline, not an upper limit. Later
iterations may add chapters if the material warrants it; the sibling
per-style sites are reference-only for pacing and depth, never a hard cap.

## DRQ-010 — Kubernetes is central: minikube primary, CRC a separate section

Kubernetes deployment is this book's point, not an appendix. **minikube**
(docker driver, containerd runtime, Wasm shim) is the primary deployment
target; **OpenShift Local (CRC)** is a separate, later section (Ch19) inside
the same Part rather than folded into the minikube chapters. Both verified
live headless when the deploy chapters land (DRQ-007).

## DRQ-011 — Companion decks: the FINAL deliverable

Companion deck(s) are built only after every chapter and every runnable
example is complete — the same posture as the REST/gRPC/WebSockets sibling
sites. Decks are mined from finished content, never written ahead of it.

## DRQ-012 — Icon and hub placement

The site uses the ⚡ icon (consistent with the series' lightning-fast /
low-level performance thread). Hub placement is under **Cloud Native / API
design** on `patterncatalyst/workshops-tutorials-list`, alongside
REST/gRPC/GraphQL/WebSockets, even though the `cn-` prefix marks this as a
deployment-target site rather than an API-style site (DRQ-001).

## DRQ-013 — Go path: standard Go primary, TinyGo an optional sidebar

The **standard Go toolchain** (official `go` compiler, `go1.26.9`) is the
primary Go path for Component Model targets: `GOOS=wasip1 GOARCH=wasm` for
the Wasm core module, `go:wasmexport` directives for host-exported functions,
and the `wasm-tools` adapter to lift the core module into a component.
**TinyGo** is documented as an optional sidebar for size-critical or
edge-constrained builds, not the primary path — standard Go's Component
Model support has matured enough to lead with it.

## DRQ-014 — Settled examples: wasi-nn cargo-classification, Spin for the survey

Two example anchors are settled ahead of their chapters:

- **Ch27 wasi-nn**: a `cargo-classification` example — image-based
  cargo damage/anomaly detection — carrying the shipping/cargo domain into
  the wasi-nn chapter, backed by the **OpenVINO** reference inference
  backend.
- **Ch26 backend-architecture survey**: **Spin** (Fermyon) is the example
  anchor for the "other backend architectures" survey chapter, contrasted
  against the wasmtime/wasmCloud pair taught in Part 4.

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

## Deferred to later iterations (r03+)

- Ch0 Setup and the lab, deferred to r03 so it lands alongside the first real
  toolchain install and the first Rust and Go builds it documents (DRQ-018).
- Chapter prose for Ch6–Ch28, to the house depth standard: paired
  SVG+Excalidraw diagrams, the house chapter spine (Learning objectives +
  Why this matters at the top, For deeper coverage at the end).
- Runnable examples under `examples/`, every example built in **both Rust and
  Go** against one shared WIT world, each with its own verify step.
- The full WIT-drift CI gate: regenerate both language bindings from
  `contracts/wit/` and fail the build on drift. Deferred to r03 — there are
  no bindings yet to diff against (DRQ-016).
- minikube manifests (containerd Wasm shim + wasmCloud operator + Istio) and
  the CRC deployment tier — both verified live headless.
- A dev compose for supporting services plus the LGTM observability stack.
- The companion deck(s) — built LAST, after every chapter and example.

## Release cadence

Iterations ship by Part, never by stack, so the Rust and Go implementations
never diverge. Each iteration ends on a clean `bundle exec jekyll build`.

Roadmap sketch:

- **r01** — scaffold.
- **r02** — Part 1 Foundations prose (Ch1–Ch5) + the cargo-domain WIT
  contract + validate-only contract CI (this iteration).
- **r03** — Part 2 Building Components (Ch6–Ch10) + Ch0 Setup + the first
  Rust and Go examples + the full WIT-drift gate (regenerate both bindings,
  fail on drift).
- **r04** — Part 3 Interfaces: HTTP & gRPC.
- **r05** — Part 4 Runtimes: wasmtime & wasmCloud.
- **r06+** — Part 5 Kubernetes deployment tiers: minikube first, then CRC,
  both verified live headless; HPA, then KEDA scale-to-zero.
- **r0N** — Part 6 Deviations: Istio+Wasm, the backend-architecture survey
  (Spin), wasi-nn.
- **r0N** — Part 7 Final project.
- **final** — companion decks, mined from the finished chapters and examples.

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

## DRQ-015 — WIT package layout: a directory, not a flat file

The cargo-domain contract lives at `contracts/wit/` as a **package
directory** — `types.wit`, `bookings.wit`, `handling.wit`, `world.wit` — under
package `patterncatalyst:cargo@0.1.0`, not a single flat `.wit` file. This
lets `wasm-tools component wit contracts/wit` validate the whole package in
one pass and gives Ch3 a real multi-interface world to teach from instead of
a single-file toy. The package is dependency-free — no `wasi:*` imports — so
the validate gate needs no dependency fetch step.

## DRQ-016 — Contract CI posture: validate-only for r02

The r02 contract CI gate (`.github/workflows/contracts.yml`) runs
`wasm-tools component wit contracts/wit` and nothing else. The full drift
gate — regenerate Rust and Go bindings from the WIT world and fail the build
if either has drifted — is deferred to r03, when the first bindings exist to
diff against.

## DRQ-017 — wasm-tools install method in CI: pinned release binary

CI installs wasm-tools from a **pinned GitHub release binary verified by a
SHA-256 checksum**, not `cargo install wasm-tools`, which compiles from
source on every run. Pinned at **1.262.0**.

## DRQ-018 — Ch0 Setup deferred to r03

Ch0 Setup and the lab is deferred from r02 to r03. User-confirmed 2026-10-20:
a setup chapter is most accurate written alongside the first real toolchain
install and the first Rust and Go builds it walks through, not ahead of them.

## DRQ-019 — Hub card timing: add at the end of r02

The hub entry on `patterncatalyst/workshops-tutorials-list` is added at the
end of r02, not at r01 bootstrap. User-confirmed 2026-10-20: wait until there
is real content to point to — five Foundations chapters and a validated
contract — rather than linking an empty scaffold.

## DRQ-020 — Diagram density: two figures is a floor, not a cap

Two diagram pairs per chapter is the minimum, not a ceiling. Chapters where
the material is inherently diagram-heavy — the execution model, the
Component Model and WIT — carry more figures when the material warrants it.
This matches the chapter-word-target posture: value-driven work over a
target is fine, padding is not.

## DRQ-021 — Go path reversed: TinyGo is the compiler, not a sidebar (supersedes DRQ-013)

DRQ-013 is reversed. Standard `go build` (Go 1.26.9) cannot emit Component
Model exports: `go:wasmexport` rejects the pointerful result and parameter
types (`*cm.Result`, `*cm.List`, `*string`, record pointers) that the
`wit-bindgen-go`/`cm` ABI produces, confirmed building the r03a examples.
**TinyGo 0.43.0 is the working Go compiler** for every Go component example
on this site from here forward. Go source and the generated
`wit-bindgen-go` bindings stay standard, idiomatic Go — only the compiler
that turns them into a component differs. User-confirmed 2026-10-20.

## DRQ-022 — Examples layout: one shared Part 2 tree, two languages, one world

Part 2 (Ch6–Ch10) examples live under a single shared tree,
`examples/part2-building-components/` (`rust/` + `go/` + `host/` +
`fixtures/` + `verify.sh`), implementing one WIT world in both languages and
reused across all five chapters rather than forking a new tree per chapter.

## DRQ-023 — Host/driver: a native Rust wasmtime host runs both components

A native Rust host built on the `wasmtime` crate (`component::bindgen!` on
`world cargo`) runs the Rust component and the Go component to
byte-identical results. A provider component has no `_start`, so something
has to host it; building that host in Rust now also seeds Ch8's
polyglot/compose chapter rather than being throwaway test scaffolding.

## DRQ-024 — Drift gate extends `contracts.yml`, not a new workflow

The full WIT-drift gate deferred at DRQ-016 lands as an extension of the
existing `contracts.yml` workflow rather than a new one: an examples
build+run job, a bindings-regeneration `git diff --exit-code` check, and a
world-conformance diff (`wasm-tools component wit <wasm>` against
`contracts/wit`). Rust bindings regenerate on every build and the generated
`src/bindings.rs` is committed; Go bindings are committed under
`go/internal`.

## DRQ-025 — Go build gotchas recorded for Ch7

Several TinyGo/Go build quirks are recorded here so Ch7 can teach them
directly rather than send readers rediscovering them: `//export
cabi_realloc` is required; `-buildmode=c-shared` (the reactor target, which
exports `_initialize`) is not a TinyGo build command, so the equivalent
explicit flags are used instead; `go.bytecodealliance.org/cm` is pinned at
v0.3.0 (DRQ-021's matrix entry); and the WIT path passed to
`go:generate`/embed must be relative, because wasmtime's filesystem sandbox
rejects an absolute path. A single direct `-target=wasip2` TinyGo build
fails on an adapter wasi-version mismatch, which is why the explicit
wasip1-plus-reactor-adapter path is used instead.

## DRQ-026 — cargo-component output lands on wasm32-wasip1, not wasip2

`cargo-component` 0.21.1's compiled artifact lands under the `wasm32-wasip1`
target triple, not `wasm32-wasip2` — the tool adapts a wasip1 core module
into a component internally. Recorded here so Ch6 doesn't present the
`wasm32-wasip2` rustup target as the whole build story.

## DRQ-027 — Composition tool: wac 0.12.0

**wac** (0.12.0, the prebuilt `wac-cli` release binary) is the composition
tool for Ch8, driven as `wac plug --plug <provider> <consumer-socket> -o
composed.wasm` to wire a provider component's export into a consumer
component's matching import. `wac compose` against a `.wac` script is noted
as the escape hatch for a composition graph with more than two components,
but is not exercised in r03b.

## DRQ-028 — Consumer components are COMMAND components

Both consumer components (Rust and Go) are `wasi:cli/run` **command**
components, not reactors, so the composed artifact runs directly under
`wasmtime run` with no native host required to exercise a composition. The
native Rust `wasmtime` host from Ch6/Ch7 (DRQ-023) is retained alongside the
command consumers — Ch9/Ch10 need it to drive the error and trap taxonomy
test cases directly.

## DRQ-029 — Consumer WIT homes: Rust gets a local world, Go reuses the existing one

The Rust consumer defines a **local** `world cargo-cli` (imports the three
provider interfaces, exports `wasi:cli/run`) with the pristine `contracts/wit`
pulled in as a `cargo-component` path dependency. The Go consumer reuses the
contract's existing `world cargo-consumer` as-is. `contracts/wit` stays
**pristine** — the fallback considered going into r03b, adding a
`cargo-cli`-shaped world directly to the contract package, turned out not to
be needed.

## DRQ-030 — Polyglot scope: all four consumer×provider pairs, asserted on runtime output

The composition scope for Ch8 is all **four** pairings of {Rust, Go}
consumer × {Rust, Go} provider, each composed with `wac plug` and run to
completion. Equivalence between pairings is asserted on **runtime output**,
not on the composed artifact's bytes (see DRQ-031).

## DRQ-031 — wac upstream issue #216: composed bytes are non-deterministic

Two `wac plug` invocations over the same inputs do not produce byte-identical
`composed.wasm` output (tracked upstream as wac#216). `verify.sh` and Ch8's
teaching material assert the four compositions' **runtime output**, never
the composed artifact's bytes — a lesson that generalizes to any Component
Model tool chain that touches section ordering or custom-section metadata
during composition.

## DRQ-032 — Command-adapter + Go-heap `cabi_realloc` early-init trap

The key r03b build finding: the wasip1→COMMAND adapter calls the module's
`cabi_realloc` from inside `_start`, before the TinyGo runtime and its
garbage collector have finished initializing. A heap-backed `cabi_realloc` —
fine in a reactor, where `_initialize` completes first — aborts when called
this early from a command component. The fix is a **static bump-arena**
`cabi_realloc` in the Go consumer (`consumer-go/cabi_realloc.go`) that
doesn't touch the TinyGo heap. Providers keep the heap-backed `cabi_realloc`
from Ch7, since `_initialize` always completes before a provider's exports
are called.

## DRQ-033 — WASI minor-version skew composes fine

The Rust provider pins WASI **0.2.3** and the Go provider pins WASI
**0.2.12** (DRQ-013's matrix entries); `wac` leaves both as unresolved
imports on the composed component, and wasmtime v50 satisfies either at
instantiation time through semver-compatible component linking. No
chapter-level workaround is needed for the skew — it's recorded here so Ch8
can call it out as expected behavior rather than a bug to route around.

## DRQ-034 — Error/trap taxonomy: recoverable result vs. a poisoning trap

Ch10's error taxonomy distinguishes two failure shapes: a **recoverable**
`result<_, cargo-error>` returned from a component call, which the native
host sees as `Ok(Err(..))` and can continue past; and a **trap** raised by a
Rust `panic!` or a Go `panic()` inside the component, which the host sees as
a wasmtime `Err` and which **poisons the Store** — no further calls succeed
against that instance. Because the trap poisons the Store, the sentinel trap
test case runs **last** in the test sequence, after every recoverable-error
case. A shared sentinel tracking ID, `__TRAP__`, is added in lockstep to both
the Rust and Go components so the host-side test harness can recognize which
call is expected to trap.

## DRQ-035 — TinyGo one-shot `-target=wasip2` is unusable; explicit wasip1+adapt stays the path

A single-step `tinygo build -target=wasip2` fails for the command consumer
the same way DRQ-025 found for the provider: the wasip2 target's bundled
adapter is pinned to WASI 0.2.0, older than the WIT world's imports. The
working path stays the explicit two-step one from DRQ-025 — build for
wasip1, embed the WIT world, then `wasm-tools component new
--adapt=command.wasm` using the wasmtime v50 COMMAND adapter recorded in the
version matrix — substituting the command adapter for the reactor adapter
since the consumer exports `wasi:cli/run`, not a reactor interface.

## DRQ-036 — Part 3 examples: a new tree, depending on the pristine contract and reusing the Part 2 providers

Part 3 (Ch11–Ch13) examples live under a **new** `examples/part3-interfaces/`
tree rather than extending `examples/part2-building-components/` in place.
The new tree depends on the pristine `contracts/wit` package (DRQ-015,
DRQ-029) and **builds on, without editing,** the Rust and Go provider
components from Part 2 — Part 3 is about putting new interfaces in front of
an unchanged provider, not about changing the provider itself.

## DRQ-037 — Ch11 wasi-http: `wasi:http/proxy` world, wac-composed, served with `wasmtime serve -S cli`

Ch11's components export `wasi:http/incoming-handler` under the
`wasi:http/proxy` world, composed with the Part 2 provider via `wac plug`
(DRQ-027), and served with `wasmtime serve -S cli`. Both the Rust
(`cargo-component`) and TinyGo (reactor) builds run and return
byte-identical JSON. Two build gotchas recorded for the chapter:
`wasmtime serve` needs the `-S cli` flag, because the proxy-world linker
otherwise omits `wasi:cli/environment` and `wasi:filesystem`; and
`cargo-component` does **not** auto-scan `wit/deps` — every `wasi:*`
interface plus the cargo contract itself must be declared as an explicit
path dependency.

## DRQ-038 — Ch12 gRPC: two-pronged — in-component protobuf wire codec, host-mediated gRPC bridge

Ch12 ships **two** artifacts, both user-directed, because neither alone
tells the whole story:

1. **Protobuf runs server-side inside a component.** The Rust side uses
   `prost` directly (runnable, see version-matrix for the 0.14.4/0.14.6
   pins). The Go side cannot use `google.golang.org/protobuf` the same way —
   it **compiles** under TinyGo 0.43 but **traps at runtime**
   (`reflect.Type.MethodByName` is unimplemented in TinyGo's reflection
   support) — so the Go component ships a hand-written, reflection-free wire
   codec instead, verified byte-identical to the Rust `prost` output.
2. **A fully in-component gRPC server is not possible today**: no Wasm
   component runtime exposes an HTTP/2 server surface a component can bind
   to. The chapter instead builds a host-mediated **tonic bridge** — a
   native Rust process using `tonic`/`tonic-prost` that terminates gRPC and
   HTTP/2 on the host side, then calls into the unchanged Wasm provider
   component over its existing WIT interface. The house framing for this is
   "gRPC in front of Wasm," not "gRPC inside Wasm."

Both artifacts are runnable and both ship in the example tree.

## DRQ-039 — Ch13 wasi-sockets: Rust is the live proof, TinyGo stays build-and-validate only

Ch13's outbound TCP client (reconnect with exponential backoff and jitter)
demonstrates **capability-scoped networking**: it requires wasmtime's
`-S inherit-network` flag and returns `access-denied` without it. The Rust
build is the chapter's live, running proof. TinyGo's `wasi:sockets` bindings
have no clean runtime path on TinyGo 0.43: the command-world build traps on
a `random_get` adapter assertion at `_start`, and the reactor-world build's
asyncify-based `pollable.block` never resolves a `connect` or timer call
under a hand-rolled host. The Go side is therefore kept at
build-and-validate (compiles, type-checks against the WIT world) rather than
claimed as a second live runtime proof. wasmCloud's link/lattice-level
resilience story is **deferred to Part 4** and only cross-referenced here,
not built in Ch13.

## DRQ-040 — CI: `contracts.yml` extended for Part 3

The `contracts.yml` examples job is extended to install a pinned **protoc
36.2** alongside the existing pinned wasm-tools/wac binaries, run
`examples/part3-interfaces/verify.sh`, and add the Part 3 Rust/Go bindings
to the existing drift gate (DRQ-024). The job timeout is raised to 60
minutes to accommodate the added build and serve steps.

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

## DRQ-041 — wasmCloud CLI: wash 0.43.0 stable, not the 2.0 RC; "2.10.1" is a phantom version

The wasmCloud CLI for Part 4 is **wash 0.43.0 (stable)**, chosen over the
2.0 release-candidate line per the latest-stable/never-prerelease policy.
The docs install page's "2.10.1" does not correspond to any real wash
release artifact on GitHub or crates.io — it's a phantom version number, not
a release this site can pin to. The 2.x rewrite (built-in host, no more
bundled nats-server/wadm) is release-candidate only
(`wash-v2.0.0-rc.8`) as of 2026-10-21; revisit when it reaches GA.

## DRQ-042 — wasmCloud verification: live evidence, not a CI gate

wasmCloud verification follows the headless-cluster-verification house rule,
not the contracts.yml CI gate: the lattice is brought up and exercised by
hand — `wash up` → `wash app deploy` → the httpserver link → a curl against
the running component → a resilience check, headless — and the output is
committed as evidence under
`examples/part4-runtimes/wasmcloud/evidence/2026-10-21/`. CI continues to
gate only what it already gated: the buildable component and the native
wasmtime-host from Ch14, never a lattice — standing up NATS, wadm, and the
host inside a CI runner each run adds flake risk disproportionate to what it
would catch.

## DRQ-043 — Ch14 wasmtime-host: fuel, epoch, and ResourceLimiter, each proven against a clean contrast run

Ch14's native wasmtime host demonstrates three host-provided controls over a
guest component, each asserted against a clean run with the control
disabled so the chapter shows cause and effect rather than asserting a
single pass/fail: **fuel** (an `OutOfFuel` trap when the fuel budget is
exhausted mid-call), **epoch deadlines** (an `Interrupt` trap when an epoch
tick fires past the deadline), and a **`ResourceLimiter`** (a denied
`memory.grow` request when the configured cap is hit).

## DRQ-044 — Ch15/16 wadm manifest and the httpserver link

Ch15's wasmCloud application is a wadm manifest wiring the
**httpserver capability provider 0.27.0** to the cargo component over the
`wasi:http/incoming-handler` export, with the link's address set to
`0.0.0.0:8000` — provider as the link source, component as the link target.

## DRQ-045 — Finding: wasmCloud ignores exported component resources

The cargo-domain's exported component resource (`cargo-tracker`) is silently
ignored by the wasmCloud runtime — wasmCloud's own documentation states that
exported component resources are not supported. The HTTP path (booking,
exercised through `wasi:http/incoming-handler`) is unaffected, so the same
`app.wasm` serves identically under both runtimes, but this is a real
wasmtime-vs-wasmCloud behavior difference and Ch16 calls it out as a caveat
rather than leaving it to be rediscovered.

## DRQ-046 — Ch16 same-bytes proof: one app.wasm, two runtimes

Ch16's headline proof is a single component artifact — `app.wasm`, sha256
`eff7f5ee…` — run unmodified under `wasmtime serve -S cli` and deployed as-is
onto wasmCloud. Same bytes, same WIT world, two runtimes, modulo the
exported-resource gap recorded at DRQ-045.

## DRQ-047 — Part 4 build gotchas recorded for Ch14–16

Four gotchas recorded so the chapters teach them directly: wasmtime 50's
`wasmtime::Error` is not `anyhow::Error`, so the host code needs a `.wc()`
shim plus a downcast to `wasmtime::Trap` to read the trap reason; a denied
`memory.grow` from a `ResourceLimiter` surfaces to the guest as an ordinary
trap, not a clean `Err` return; `wash app status` reporting `deployed` means
the manifest was accepted, not that the HTTP endpoint is answering — the
gate is an HTTP 200, not the status string; and `file://./app.wasm` in a
wadm manifest resolves against `wash`'s current working directory, not the
manifest file's directory.

## DRQ-048 — Part 5 minikube deploy mechanism: raw runwasi shim + RuntimeClass, confirmed live

Part 5's minikube deployment path is the **raw runwasi
`containerd-shim-wasmtime`**, installed directly on the node and exposed to
Kubernetes through a `RuntimeClass` named `wasmtime` — not the wasmCloud
operator. This passed its go/no-go live on minikube r06a: the open upstream
regression tracked as runwasi#1004 did not reproduce, so the
wasmCloud-operator fallback considered for r06a was not needed. CRC (r06b)
takes the opposite path — the **wasmCloud operator** — because the raw shim
needs privileged RHCOS node surgery that doesn't fit the `restricted-v2` SCC
the CRC chapters hold to.

## DRQ-049 — No port-forwarding for live verification: always the real ingress path

User-confirmed house rule, binding for every cluster chapter from here
forward: live verification goes through the **real ingress path**, never
`kubectl port-forward`, `minikube tunnel`, or a NodePort. On minikube that's
a `nip.io` Ingress; on CRC (r06b) that's an edge-TLS Route. Bypassing the
ingress layer for convenience would verify the pod, not the deployment —
the thing the live check exists to prove.

## DRQ-050 — Headless verification stays the gate; footer only flips on a live PASS

Both cluster paths (minikube r06a, CRC r06b) are verified **headless** with
committed evidence, per the existing house rule
([[feedback_headless_cluster_verification]]). A chapter's footer moves to
"verified live <date>" only when the automated headless check actually
passes — never set ahead of a real run.

## DRQ-051 — Component packaging: FROM scratch + COPY app.wasm, built without provenance, loaded directly

The Wasm component ships as a `FROM scratch` OCI image with a single `COPY
app.wasm /app.wasm` layer, built with `docker build --provenance=false`.
BuildKit's default provenance attestation manifest confuses image load and
the shim's platform resolution — without the flag, the shim can't find the
actual Wasm layer behind the attestation manifest. The image is loaded
straight onto the minikube node with `minikube image load`; no registry is
involved.

## DRQ-052 — Part 5 live-run gotchas recorded for Ch17/Ch18

Four gotchas recorded so Ch17/Ch18 teach them directly rather than send
readers rediscovering them: the `containerd-shim-wasmtime` binary is a
**containerd shim, not a CLI** — it cannot be invoked directly to run or test
a component; `minikube ssh`'s PTY hangs on a piped heredoc, so the install
step uses `minikube cp` to stage the script and a `sudo bash <file>` instead;
the shim has to be installed — which restarts containerd and bounces every
Pod on the node — **before** the ingress addon is enabled, or the addon's own
pods can land ahead of the shim; and readiness is gated on a real HTTP 200,
not a rollout-Ready status, because `ingress-nginx`'s default backend 404s
for a window during its own async reload — the check waits on the affinity
cookie plus an actual 200.

## DRQ-053 — CI stays a static manifest gate; live cluster bring-up is evidence-only

Part 5's CI contribution holds to the same static-only posture as Parts
2–4's contract gates: `kubectl kustomize | kubeconform -strict` against the
Kubernetes manifests, nothing more. Standing up minikube or CRC inside a CI
runner is never a CI step — the live bring-up and verification happen by
hand (the same posture DRQ-042 set for wasmCloud) and the result is
committed as evidence, matching the headless-verification house rule
(DRQ-050).

## DRQ-054 — Ch19 CRC deploy mechanism: the wasmCloud operator (v1 chart 0.1.2), not the raw runwasi shim

Ch19's OpenShift Local (CRC) deployment path is the **wasmCloud operator**,
installed via the v1 Helm chart
`oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2` — the opposite
choice from Ch18's minikube path (DRQ-048). The raw
`containerd-shim-wasmtime` used on minikube needs a privileged RHCOS
MachineConfig to install on the node, which does not fit the
`restricted-v2` SCC the CRC chapters hold to; the operator model stays
inside `restricted-v2` with no node-level surgery. Confirmed live on CRC
2.64.0 / OCP 4.22.14.

## DRQ-055 — Same app.wasm ships to CRC via a private registry, not a direct node load

The same `app.wasm` (sha256 `eff7f5ee…`, the same-bytes artifact from
DRQ-046) deploys to OpenShift. It is pushed to a **private**
`ghcr.io/patterncatalyst/cargo-http:crc` image rather than loaded directly
onto the node the way minikube's `minikube image load` does (DRQ-051) — CRC
has no equivalent. The in-cluster wasmCloud host pulls it through a
`ghcr-pull` docker-registry Secret, referenced by
`WasmCloudHostConfig.spec.registryCredentialsSecret`.

## DRQ-056 — Ch19 verification: CA-verified curl through an edge-TLS Route, never -k/port-forward/NodePort

Ch19's live check is a **CA-verified** `curl` — using a combined bundle of
the system trust store plus the cluster's ingress CA — through an edge-TLS
Route. No `curl -k`, no `oc port-forward`, and no NodePort: the DRQ-049
no-port-forward rule holds on OpenShift the same way it does on minikube's
Ingress path, and skipping certificate verification would leave the same
gap a port-forward does — it would prove the pod answers, not that the
Route does.

## DRQ-057 — Eight CRC live gotchas recorded for Ch19

1. The operator's manually created EndpointSlice is rejected by
   `RestrictedEndpointsAdmission`; the fix is a narrow
   `endpoints`/`endpointslices` `restricted` RBAC grant scoped to the
   operator's service account — a network RBAC grant, not an SCC exception.
2. Host-to-provider wRPC version skew: the chart's default host 1.2.1 is too
   old for the httpserver provider 0.27.0 and surfaces as an HTTP 500; the
   fix is pinning the host to **1.9.1** via `WasmCloudHostConfig.spec.version`.
3. NATS has to run standalone (`cluster.enabled: false`) on a single-node
   CRC — the chart's default clustered NATS never reaches quorum.
4. `nats-box` CrashLoops under `restricted-v2` and is disabled.
5. The OAM application has to live in the same namespace as the
   `WasmCloudHostConfig`.
6. Teardown has to delete the stale `v1beta1.core.oam.dev` APIService first,
   or namespace deletion stalls waiting on it.
7. Readiness is gated on a real HTTP 200 from the Route, not a pod-Ready
   status.
8. The chart's NATS DNS needs repointing to `*.wasmcloud.svc`.

## DRQ-058 — restricted-v2: nulling the wadm subchart's hard-coded runAsUser/runAsGroup

The wadm subchart hard-codes `runAsUser`/`runAsGroup: 1000` in its pod spec,
which falls outside the namespace's platform-assigned UID range under
`restricted-v2` and is rejected. The fix is nulling both fields in the Helm
values so OpenShift assigns a UID from the namespace range itself. Every
other component in the chart already runs platform-assigned non-root with
no override needed.

## DRQ-059 — CI for Ch19 stays a static manifest gate; the live CRC run is evidence-only

Consistent with DRQ-053's static-only posture for Part 5's other chapters,
Ch19's CI contribution is static too: the raw OpenShift CRD manifests
(`WasmCloudHostConfig`, the OAM `Application`, etc.) are validated with
`kubeconform -ignore-missing-schemas`, since the CRDs ship no published
OpenAPI schema for strict mode to check against. Standing up CRC inside a CI
runner is not a CI step; the live run is evidence-only, captured by hand and
committed, matching DRQ-042's wasmCloud posture and DRQ-050's
headless-verification gate.

## DRQ-060 — Interposition at the cargo domain interface, not the HTTP incoming-handler

Ch20's sidecar-filter and Ch21's adapter interpose at the
`patterncatalyst:cargo/*` domain interfaces (plain value records), not at
WASI's `wasi:http/incoming-handler`. WASI 0.2's `incoming-handler` takes
non-constructible host resources (`incoming-request`/`response-outparam`),
which a component-side interposer cannot fabricate, and `wac` itself rejects
the attempt as a resource mismatch (wac#149). Each interposer gets a local
WIT world that imports and exports the cargo interfaces as a path
dependency; `contracts/wit` stays pristine and unmodified.

## DRQ-061 — Two substrate expressions of the same pattern on Ch20/Ch21: compile-time wac vs. runtime wadm links

minikube and CRC realize sidecar/adapter interposition through two different
mechanisms, not through one portable manifest. On minikube, interposition is
compile-time: `wac plug` composes provider → interposer → HTTP front door
into one `app-*.wasm`, because the raw containerd shim can only host a
single pod-scoped `RuntimeClass` workload on a fixed `:8080` and cannot host
a pod sidecar (runwasi#1004). On CRC, interposition is a runtime concern:
three separate components — provider, interposer, front door — are linked
on `patterncatalyst:cargo/booking` (and `handling`) over wRPC through wadm
links, which custom-interface component-to-component linking supports on
wasmCloud host 1.8 and up (verified here on 1.9.1).

## DRQ-062 — The state-across-links finding: wasmCloud components are stateless per invocation

The headline finding for Ch20/Ch21, verified live on both clusters. A
wasmCloud component gets a fresh instance with reset linear memory on every
invocation, so the front door's two-call round trip (book, then get) loses
the in-memory booking it just wrote once that round trip crosses a runtime
link: a valid booking ID returns 404 on CRC. Under minikube's `wac plug`
composite, the same two calls run inside one in-process instance, so the
booking survives and the same ID returns 200. Compile-time composition
shares state across calls; runtime links give independent lifecycle and let
the host inject policy or shape changes per hop, but they do not carry
in-memory state — that has to move to a capability provider or an external
service. A fallback to a two-component wac-plus-link hybrid would not fix
this: the front door still issues two calls across the link either way. The
finding is reported as-is, fully evidenced on both clusters, not as a
failure to work around.

## DRQ-063 — What each interposer does, and the adapter/ambassador substrate split

Ch20's sidecar-filter enforces a destination-embargo policy plus logging;
the embargo firing across the CRC runtime link is proven by a host-log
`POLICY DENY` line at the point of denial. Ch21 ships two interposers: the
adapter translates a legacy request shape into the canonical cargo shape,
lossless for every JSON-surfaced field, and the ambassador adds outbound
calls with backoff and jitter. The ambassador is substrate-asymmetric by the
user's own confirmation: CRC runs it live, with outbound reachability
granted (or denied, returning 500) by a runtime lattice link — egress is
itself a grant — while minikube's raw shim exposes no outbound-network knob,
so the minikube side is a local `wasmtime run -S inherit-network` smoke
test, documented as a substitute rather than presented as a live cluster
run.

## DRQ-064 — Interposer build gotcha: importing and exporting the same interface forks the generated types

A component that both imports and exports the same WIT interface — the
shape every interposer here takes — gets two distinct generated Rust type
trees for that interface, one per direction, with no implicit conversion
between them. Each interposer carries a small, mandatory field-by-field
`conv` module to cross that boundary. Links are scoped to only the
interfaces a component actually imports — the front door imports `booking`
only, not `handling` — keeping the lattice link graph matched to real
dependencies. CRC readiness for the interposed chain is a 404 from the
provider on an unknown ID, not a 200, since 200 would mean the chain isn't
wired through the interposer at all. Separately, wasmtime collapses any
non-zero guest exit code to host process exit code 1, so a guest-side
distinction between failure modes is not visible from the shell exit code
alone.

## DRQ-065 — CI for Ch20/Ch21: interposition examples join the build+drift gate, manifests join the static kubeconform gate

The new `examples/part5-kubernetes/{sidecar-filter,adapter,ambassador}`
components join the existing examples build job and the bindings-drift
check already running for the other example trees (DRQ-024), so the
interposer's local WIT worlds are regenerated and diffed like every other
component's bindings. The interposed minikube kustomize overlay
(`k8s/interposed/`) and the OpenShift `wadm-*.yaml` manifests join the
static kubeconform gate (DRQ-053, DRQ-059) rather than getting a parallel
gate of their own. No cluster runs inside CI for Ch20/Ch21, matching the
static-only posture already set for the rest of Part 5.

## DRQ-066 — Ch22 autoscaling is a per-substrate asymmetry, not one mechanism

On minikube the component runs as an ordinary Pod under RuntimeClass
`wasmtime`, so it exposes normal cgroup CPU to the kubelet → metrics-server → a
standard `autoscaling/v2` HorizontalPodAutoscaler (CPU utilization, the base
Deployment's `requests.cpu: 50m` makes it sensitive). On CRC the app is a
wasmCloud-operator-managed OAM Application, **not** a plain Deployment, so a
K8s HPA has nothing correct to target — an HPA on the host Deployment would
fight the operator's reconcile loop. The CRC lever is the wadm **spreadscaler**
`instances` count, which changes the wasmCloud instance count with **zero
Kubernetes Pod churn** (the asymmetry `verify-scaling-crc.sh` proves). The
httpserver provider trait stays a `daemonscaler` so the operator keeps creating
the Service the Route targets. Same honest-asymmetry teaching style as DRQ-062.

## DRQ-067 — Ch23 HTTP scale-to-zero: KEDA drives the plain Wasm Deployment

The KEDA HTTP add-on (0.16.0) is the one genuine "KEDA scales the Wasm
workload" case: on minikube the raw-shim `cargo-http` Deployment carries an
`HTTPScaledObject` (field is `spec.replicas.{min,max}` — `minReplicaCount` does
**not** exist on the 0.16 CRD; HTTPScaledObject is deprecated toward
`InterceptorRoute` but still functional, used as the documented stable path).
Idle → 0; a cold request through the real nip.io Ingress → the interceptor
(reached via an `ExternalName` Service + an Ingress backend rewire, because
Ingress backends can't cross namespaces) → 0→1 cold start → 200, with the Wasm
fast-cold-start latency as the payoff. On CRC the HTTP half is CMA/KEDA
installed + the wadm spreadscaler 0↔N (same operator-owns-replicas reason as
DRQ-066).

## DRQ-068 — Ch23 Kafka scaler ELEVATED to a live demo (user Decision A)

Original plan covered the Kafka scaler conceptually; the user chose a live
demo. **Decision A = wasmCloud-on-minikube**: no in-component hand-rolled Kafka
client and no feasibility spike. The wasmCloud first-party `messaging-kafka`
provider plus ONE `kafka-handler` component run on **both** clusters; the
provider speaks the Kafka protocol and pushes deliveries over wRPC (the honest
Wasm-consumes-Kafka mechanism — the raw shim has no messaging binding, and Spin
is ruled out because it has no Kafka trigger). A KEDA `kafka` ScaledObject reads
consumer-group lag, but the wadm **spreadscaler owns** the handler's replica
count — so the teaching is "KEDA observes, wadm acts," the same
substrate-owns-the-lifecycle lesson as DRQ-062, consistent across both clusters.
Kafka source = Strimzi 1.3.0 (single-node KRaft, a multi-partition topic so 0→N
is real under KEDA's partition ceiling); the burst is produced via exec into a
Strimzi client Pod, never port-forward.

## DRQ-069 — Ch23 adds ONE new crate; contracts/wit stays pristine; CI moves

`kafka-handler` is one new Rust component crate with a LOCAL wit world
(exports `wasmcloud:messaging/handler@0.2.0`, imports `patterncatalyst:cargo`
via a path dependency; the messaging package is vendored under `wit/deps/`) —
the r06c interposer pattern, so `contracts/wit` is unchanged. Unlike the
earlier r06d assumption of "no CI change," the `examples` job now gains one
`cargo component build --release` step and `kafka-handler/src/bindings.rs` joins
the drift gate's `ALL_BINDINGS`; the `k8s-manifests` job gains the ch22/ch23/ch24
minikube overlays (scaling, keda, kafka/base, observability) plus the standalone
KEDA kafka ScaledObject and the minikube wasmCloud CRD instances, and four more
OpenShift manifests (wadm-scaled, wadm-kafka, wasmcloud-host-otel, otel-collector).

## DRQ-070 — wasmCloud-on-minikube is introduced for the Ch23 Kafka half only

The Kafka half needs a capability runtime, so it brings the wasmCloud platform
onto minikube too (reusing the r06b pins: chart
`oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2`, host 1.9.1) via a new
`k8s/wasmcloud/` setup on plain k8s — no Routes, no SCC, evidence via nip.io
Ingress / `kubectl exec`, never port-forward. This is a deliberate
mixed-substrate-within-minikube shape: Ch22 HPA and the Ch23 HTTP add-on stay on
the raw containerd shim (the HTTP/request-response substrate); the Ch23 Kafka
half runs on wasmCloud (the messaging substrate). The chapter names the split
and why. Replaces the dropped in-component-Kafka-client spike/fallback.

## DRQ-071 — Ch24 on-cluster telemetry is substrate-provided, not guest-authored

Guest-emitted spans via `wasi-otel` are RC-only and not in the pinned stable
toolchain (wasmtime 50 / shim v0.6.1 / wasmCloud host 1.9.1), so on-cluster Wasm
observability today is substrate-provided. minikube: the
containerd-shim-wasmtime v0.6.1 emits OTel traces on by default (since v0.5.0),
configured by env in containerd's environment on the node (a systemd drop-in;
endpoint = the otel-lgtm Service ClusterIP, routable from the node host netns
via kube-proxy; restarting containerd bounces Pods) → `grafana/otel-lgtm:0.33.1`
in-cluster; spans are container/task lifecycle, not guest code. CRC: the
wasmCloud host 1.9.1 emits OTLP natively (`spec.observability` on the
WasmCloudHostConfig) → richer traces + the `wasmcloud_host.handle_rpc_message.duration`
metric + logs. Evidence on both is read via exec (Tempo/Prometheus/Loki queries
on minikube; the collector's own debug/file exporter on CRC), never a
port-forward, never the Grafana UI.

## DRQ-072 — Ch24 CRC holds restricted-v2 with NO SCC exception (user Decision B)

`grafana/otel-lgtm` is a dev image that will not run under restricted-v2
(writable data dirs under a fixed uid/home) and `anyuid` is barred, so it is
**not** used on CRC. Instead the wasmCloud host emits OTLP to a minimal ROOTLESS
`otel/opentelemetry-collector-contrib:0.163.1` Deployment under full
restricted-v2 (runAsNonRoot, no fixed uid, drop ALL, seccomp RuntimeDefault),
and evidence is read from the collector itself (debug + file exporters via
`oc logs`/`oc exec`). minikube keeps otel-lgtm (Decision B constrains CRC only).
Note: the `WasmCloudHostConfig.spec.observability` schema was confirmed against
the operator's current source, not the exact installed operator (0.1.5), so an
`oc explain wasmcloudhostconfig.spec.observability` spot-check precedes the live
CRC run.

## DRQ-073 — r06d version pins (surveyed 2026-10-21, confirmed-live-at-kickoff)

KEDA core **2.21.0** (Helm `kedacore/keda`); KEDA HTTP add-on **0.16.0** (Helm
`keda-add-ons-http`); metrics-server via the minikube `metrics-server` addon
(record the bundled tag at kickoff, ~v0.9.0); Strimzi **1.3.0** with Apache
**Kafka 4.3.1** / `metadataVersion: 4.3-IV0` — **corrected**: Strimzi 1.3.0 does
NOT support Kafka 4.1.0 (supports 4.2.x–4.3.x; 4.3.1 is its own tested pairing);
wasmCloud `messaging-kafka` provider pinned to the commit-SHA build
`ghcr.io/wasmcloud/messaging-kafka:6c67eb2` (**no semver release exists
upstream** — only commit-SHA builds aliased `canary`; re-check for a newer SHA +
confirm the `source_config` key names at kickoff — TBD); wasmcloud-platform
chart **0.1.2** / host **1.9.1** (reused r06b pins, now also on minikube);
`grafana/otel-lgtm:0.33.1` (minikube); `otel/opentelemetry-collector-contrib:0.163.1`
(CRC, rootless); CRC KEDA = Custom Metrics Autoscaler operator, pinned CSV
(TBD-confirm-at-kickoff via `oc get packagemanifest`). Reused firm: shim
v0.6.1, minikube v1.39.0 / Kubernetes v1.37.1, kubeconform v0.8.0, httpserver
provider 0.27.0.

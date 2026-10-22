---
title: "Version Matrix"
layout: plan
render_with_liquid: false
---

# Version Matrix

> Surveyed: 2026-10-20 (r02 foundations). The authoring-box toolchain and the
> Part 2/4 Wasm toolchain rows below are now confirmed against upstream
> release pages — checked against the vendor's own release notes, not
> memory. The Kubernetes deployment tier and wasi-nn rows carry a
> current-stable snapshot taken on the same date for reference, but stay
> marked TBD-at-kickoff: each gets its own live, dated re-survey and gets
> pinned as a firm version when the chapter or example that depends on it is
> written. **Updated 2026-10-21 (r06a):** the Part 5 minikube tier (runwasi
> shim, minikube, Kubernetes, containerd, ingress-nginx, kubeconform) is now
> FIRM, re-surveyed and verified live on minikube rather than a snapshot.
> **Updated 2026-10-21 (r06b):** the Part 5 CRC/OpenShift tier (wasmCloud
> platform Helm chart, operator, host, httpserver provider, CRC itself) is
> now also FIRM, re-surveyed and verified live on CRC. Istio and KEDA stay
> TBD-at-kickoff until their own chapters land.

The Wasm toolchain and WASI/Component Model rows are the r02 pins. The Part 5
minikube tier is the r06a pins and the Part 5 CRC/OpenShift tier is the r06b
pins, both verified live. The remaining Kubernetes deployment-tier rows
(Istio, KEDA) and the wasi-nn rows are not pins yet — they are a snapshot to
plan against, re-verified live when their chapter lands.

| Component | Version |
|---|---|
| **Authoring box (confirmed, installed)** | |
| Rust | 1.99.1 — installed and confirmed on the authoring box |
| cargo | 1.99.1 — ships with the Rust toolchain above |
| Go | 1.26.9 — installed and confirmed on the authoring box; source language and `wit-bindgen-go` bindings stay standard Go (DRQ-013, reversed on the compiler choice by DRQ-021) |
| TinyGo | 0.43.0 — installed and confirmed working against Go 1.26.9 / LLVM 22.1.4; **the compiler** that produces Component Model exports, not a sidebar (DRQ-021 reverses DRQ-013) |
| Rust nightly | Not used for r02. Stable Rust 1.99.1 covers `wasm32-wasip2` and `cargo-component` without a nightly toolchain. Any future chapter that needs a nightly-only Wasm feature gets its own pinned, dated nightly (e.g. `nightly-2026-MM-DD`) at the point it's introduced — never a floating `nightly` channel. |
| **Wasm toolchain (r02 pins, verified 2026-10-20)** | |
| wasm-tools | **1.262.0**, released 2026-10-13. Linux x86_64 release tarball `wasm-tools-1.262.0-x86_64-linux.tar.gz`, SHA-256 `655b8df67d54c3ef9b52fc237c4e94bbfbb5f5f43825245cb0940a7002a9ed65`. This is the version the r02 contracts CI gate pins. Source: https://github.com/bytecodealliance/wasm-tools/releases/tag/v1.262.0 |
| cargo-component | **0.21.1**, released 2025-04-07; still the latest stable tag as of 2026-10-20 (confirmed against crates.io `max_stable_version`, no newer release since). Installed via `cargo install --locked cargo-component`; unlike wasm-tools and wasmtime, there is no prebuilt release binary. Source: https://github.com/bytecodealliance/cargo-component/releases/tag/v0.21.1 |
| wasmtime | **v50.0.0**, released 2026-10-20. Wasmtime ships a new major monthly; v50 is the current latest. r03 also pins the `wasmtime` and `wasmtime-wasi` **50** Rust crates for the native host that drives the examples. Source: https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.0 |
| wash (wasmCloud CLI) | **0.43.0** — re-verified 2026-10-21 for r05: still the current stable wasmCloud CLI (crates.io default, package `wash`; GitHub release `wash-v0.43.0`, linux x86_64 asset `wash-x86_64-unknown-linux-musl`, SHA-256 `cf4d2cd801de892dd8d130c356c85a484c2c261a51863c6e8874423790becbe9`). `wash up` bundles and launches nats-server 2.11.3 + wadm 0.21.1 + wasmcloud host 1.9.1 together (DRQ-041). **CORRECTED 2026-10-21**: the `wash` 2.x rewrite (built-in host) is release-candidate only (`wash-v2.0.0-rc.8`), no GA — the "2.10.1"/"2.11.0" figures that appear on the docs install page do not correspond to any real wash release artifact on GitHub or crates.io (phantom versions; the v2.10.3 standalone-host figure previously recorded on this row was also stale). Per the never-a-prerelease policy the book pins stable **0.43.0**; the 2.x rewrite is noted as forthcoming. Source: https://github.com/wasmCloud/wasmCloud/releases/tag/wash-v0.43.0 |
| wasmCloud host (bundled by `wash up`) | **1.9.1** — launched by `wash up` alongside nats-server 2.11.3 + wadm 0.21.1 (see wash row above); the host version this site's examples actually run against, replacing the standalone v2.10.3 figure recorded here at r02. Source: `wash up` output, confirmed 2026-10-21 |
| **WASI / Component Model status (verified 2026-10-20)** | |
| WASI Preview 2 (0.2.x line) | Current patch is **v0.2.12**, released 2026-06-02 — stable and released. The `wasm32-wasip2` Rust target and `cargo-component` both target this line as of this survey. Source: https://github.com/WebAssembly/WASI/releases/tag/v0.2.12 |
| WASI Preview 3 (0.3.x line) | Now also released: v0.3.0 (2026-06-11, first stable), v0.3.1 (2026-08-11), **v0.3.2** (2026-10-13, latest overall). Adds native async. Most toolchains, including the Rust/Go paths used in this site, still target 0.2 as of this survey; 0.3 is noted here as a known option for a future chapter to evaluate on its own merits. Source: https://github.com/WebAssembly/WASI/releases and https://wasi.dev/releases |
| Component Model | Pre-1.0. Still a Phase 2/3 W3C proposal, not yet supported in browsers. A Component Model 1.0 roadmap was discussed publicly in 2026 (Wasm I/O 2026, Barcelona) but is not finalized as of this survey. Tooling (wasm-tools, wasmtime, wit-bindgen) tracks the proposal directly rather than a finished spec. Source: https://component-model.bytecodealliance.org/ and https://bytecodealliance.org/articles/the-road-to-component-model-1-0 |
| **r03 build toolchain (confirmed/installed, 2026-10-20)** | |
| Rust target `wasm32-wasip2` | Added via `rustup target add wasm32-wasip2` on Rust **1.99.1** stable — no nightly needed for this target. `cargo-component` 0.21.1 still compiles to `wasm32-wasip1` internally and adapts the result forward; see DRQ-026. Source: `rustup target list` |
| TinyGo (Go component compiler) | **0.43.0** — see the Authoring box row above. DRQ-021 reverses DRQ-013: TinyGo, not standard `go build`, is the compiler for every Go component example on this site. Source: https://github.com/tinygo-org/tinygo/releases |
| wit-bindgen-go | **v0.7.0** (`go.bytecodealliance.org/cmd/wit-bindgen-go`) — generates the Go-side WIT bindings TinyGo builds against. Source: https://github.com/bytecodealliance/go-modules/releases |
| go.bytecodealliance.org/cm | Pinned at **v0.3.0**. The `v0.4.0+` tags were cut on the root module path and are unusable for the `/cm` import — do not take a newer tag until upstream fixes the module layout. Source: https://pkg.go.dev/go.bytecodealliance.org/cm |
| wasip1→p2 reactor adapter | `wasi_snapshot_preview1.reactor.wasm`, shipped inside the wasmtime **v50.0.0** release artifacts, SHA-256 `73b01f85e42e99c890efbbf619cd765e04e5809da36d976b87fc64abd87f5812` — adapts TinyGo's wasip1 reactor output forward into the wasip2 Component Model world. Source: https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.0 |
| **r03b build toolchain (confirmed/installed, 2026-10-20)** | |
| wac | **0.12.0** — the prebuilt `wac-cli-x86_64-unknown-linux-musl` release binary, SHA-256 `7cd490edbd452221ef89e6750fc43eacc9b71b1242095eb577cb9a3bf0d3beda`. The component composition tool, driven via `wac plug --plug <provider> <consumer-socket> -o composed.wasm` (DRQ-027); `wac compose`/a `.wac` script is noted as the multi-component escape hatch for later Parts. Source: https://github.com/bytecodealliance/wac/releases |
| wasi command adapter | `wasi_snapshot_preview1.command.wasm`, shipped inside the same wasmtime **v50** release artifacts as the reactor adapter above, SHA-256 `b3de00ac47528237211c6404b4a7e4235a67878665dc3e8853071908c3127a85` — adapts the TinyGo wasip1 COMMAND output forward into wasip2 for the Go **consumer**; the reactor adapter recorded above stays the one for provider components. Source: https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.0 |
| **r04 build toolchain (confirmed, 2026-10-21)** | |
| wasi WIT (http/sockets) | **0.2.8** for the Rust http/sockets crates — vendored from the `WebAssembly/wasi-http` v0.2.8 `wit/` tree. **0.2.12** for the TinyGo Go components — taken from the `wasmtime-wasi` **50** crate, to match the reactor adapter. wasmtime **v50** satisfies either via semver-compatible component linking, same skew tolerance recorded at DRQ-033. |
| prost / prost-build | **=0.14.4** (exact pin on both). Source: https://crates.io/crates/prost |
| tonic / tonic-prost / tonic-prost-build | **=0.14.6** (exact pin on all three). tonic 0.14 split the prost integration out of the core `tonic` crate into `tonic-prost` and `tonic-prost-build`. Source: https://crates.io/crates/tonic |
| protoc | **36.2** (`protocolbuffers/protobuf` v36.2) — required on PATH for `prost-build` and `tonic-prost-build` codegen. Source: https://github.com/protocolbuffers/protobuf/releases/tag/v36.2 |
| `wasmtime serve` | Built into wasmtime **50** — no separate tool to install; served with `wasmtime serve -S cli` for the Ch11 wasi-http components (see DRQ-037). |
| **r05 runtimes toolchain (confirmed, 2026-10-21)** | |
| wash (wasmCloud CLI) | **0.43.0** — see the corrected row above for the full pin, the bundled nats-server/wadm/host versions, and the wash-2.x-RC correction. |
| httpserver capability provider | **`ghcr.io/wasmcloud/http-server:0.27.0`** — latest released semver tag, compatible with wasmCloud host 1.9.1 + wasi:http 0.2.x. Links provider source to the component target (`wasi:http/incoming-handler`, address `0.0.0.0:8000`) for ch15/ch16. Source: https://github.com/wasmCloud/capability-providers/pkgs/container/http-server |
| **Part 5 minikube deployment tier (FIRM, verified live 2026-10-21, r06a)** | |
| containerd Wasm shim (runwasi) | **containerd-shim-wasmtime v0.6.1**, asset `containerd-shim-wasmtime-x86_64-linux-musl.tar.gz`, SHA-256 `a9b1215ee670f11414c8fd8e970b52679085929c8ec73a0fe6ed9cf215cf9ba1` — installed directly on the minikube node, serving `wasi:http/incoming-handler` components under a `RuntimeClass` named `wasmtime` (DRQ-048). Confirmed live on minikube r06a; upstream runwasi#1004 did not reproduce. Source: https://github.com/containerd/runwasi/releases/tag/v0.6.1 |
| minikube | **v1.39.0** — docker driver + containerd runtime only, per house convention (podman path removed). Verified live for r06a. Source: https://github.com/kubernetes/minikube/releases/tag/v1.39.0 |
| Kubernetes | **v1.37.1**, pinned explicitly via `--kubernetes-version` at `minikube start` rather than taking minikube's default. Verified live for r06a. |
| containerd (in-node) | **v2.3.4** — the in-node containerd minikube v1.39.0/Kubernetes v1.37.1 bundles; the runwasi shim above installs alongside it without replacing it. |
| ingress-nginx controller | **v1.15.1** — the minikube `ingress` addon bundled with minikube v1.39.0; fronts live verification over the real `nip.io` Ingress path, never a port-forward (DRQ-049). |
| kubeconform | **v0.8.0**, pinned GitHub release binary `kubeconform-linux-amd64.tar.gz`, SHA-256 `9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883` — the CI static-manifest gate for Part 5 (`kubectl kustomize | kubeconform -strict -kubernetes-version 1.37.1`, DRQ-053); CI-only, never exercises a live cluster. |
| **Part 5 CRC/OpenShift deployment tier (FIRM, verified live 2026-10-21, r06b)** | |
| wasmcloud-platform Helm chart | **v1 `0.1.2`** (`oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2`) — bundles operator **0.1.5** (image `ghcr.io/wasmcloud/wasmcloud-operator:0.4.0`), nats **1.2.3** (nats image 2.10.19), wadm **0.2.7** (binary v0.14.0), and the host subchart **0.8.4**. This is the last tagged v1 release; the v1 operator repo is now archived upstream. Confirmed live on CRC r06b (DRQ-054). |
| wasmCloud host | **1.9.1**, pinned via `WasmCloudHostConfig.spec.version` — NOT the chart's default **1.2.1**, which is too old for the httpserver provider below and triggers a wRPC version-skew HTTP 500. |
| httpserver capability provider | **`ghcr.io/wasmcloud/http-server:0.27.0`** — the same pin as the Part 4/minikube tier, reused unchanged for the CRC deployment. |
| CRC / OpenShift Local | **2.64.0** / OCP **4.22.14** — `restricted-v2` SCC throughout; no privileged MachineConfig. Firms the r02 snapshot row below for this component. |
| Note | The wasmCloud **v2** rewrite (runtime-operator chart 2.10.x) uses a different, non-OAM/non-`WasmCloudHostConfig` model that diverges from this book's Part 4 contract spine; the book pins the **v1 chart 0.1.2** instead of tracking v2. |
| **Part 5 interposition patterns (r06c, no new pins)** | |
| Note | Ch20 (sidecar) and Ch21 (ambassador, adapter) reuse the firm Part 5 pins as-is: containerd Wasm shim v0.6.1 and minikube v1.39.0/Kubernetes v1.37.1 on the compile-time `wac plug` path; wasmcloud-platform chart 0.1.2 and host 1.9.1 on the runtime wadm-link path; httpserver provider 0.27.0; kubeconform v0.8.0 for the static manifest gate. No new tool version is introduced. The new per-component private `ghcr.io/patterncatalyst/{cargo-provider,frontdoor,filter,adapter}:crc` image references are deploy artifacts for this chapter pair, not entries in the version pin table. |
| **Part 5 scaling + observability tier (r06d pins; surveyed 2026-10-21, confirmed-live-at-kickoff; live-verify pending)** | |
| KEDA core | **v2.21.0** (Helm `kedacore/keda`) — the autoscaler behind both Ch23 halves. HTTP add-on requires core ≥2.21. Source: https://github.com/kedacore/keda/releases/tag/v2.21.0 |
| KEDA HTTP add-on | **0.16.0** (Helm `keda-add-ons-http`) — drives the Ch23 scale-to-zero HTTP half via an `HTTPScaledObject` (`spec.replicas.{min,max}`; deprecated toward `InterceptorRoute` but still functional). Source: https://github.com/kedacore/http-add-on/releases |
| metrics-server | minikube **`metrics-server` addon**, **v0.9.0** (confirmed live at kickoff 2026-10-21: `registry.k8s.io/metrics-server/metrics-server:v0.9.0`) — feeds the Ch22 CPU HPA on minikube (HPA wiring verified live; the Ch22 finding is that a cheap stateless Wasm handler gives no CPU signal to scale on — see DRQ-074). |
| Strimzi | **1.3.0** (Apache **Kafka 4.3.1**, `metadataVersion: 4.3-IV0`), single-node KRaft, multi-partition topic. **CORRECTED**: Strimzi 1.3.0 does NOT support Kafka 4.1.0 (supports 4.2.x–4.3.x); 4.3.1 is upstream's own tested pairing for this operator tag. Node pools are mandatory (no `strimzi.io/node-pools` annotation). Source: https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.3.0 |
| wasmCloud messaging-kafka provider | **`ghcr.io/wasmcloud/messaging-kafka:0.2.0`** — the stable semver release (CORRECTED at kickoff 2026-10-21: an earlier survey wrongly concluded "no semver, only commit-SHA builds"; the ghcr tag list carries **0.2.0** stable + 0.2.0-rc.1, and `wash inspect` confirms vendor=wasmcloud / version=0.2.0 / x86_64-linux). Implements `wasmcloud:messaging@0.2.0` for the Ch23 Kafka handler. Its link `source_config` key names (`hosts`/`topic`/`consumer_group`) are still unconfirmed — verify from the provider logs on the Kafka live pass (DRQ-076). Source: https://github.com/wasmCloud/messaging |
| wasmcloud-platform Helm chart (minikube) | **v1 `0.1.2`** / host **1.9.1** — the SAME r06b pins, now also installed on minikube for the Ch23 Kafka half (DRQ-070); plain k8s, no Routes/SCC. |
| grafana/otel-lgtm | **0.33.1** (bundles OTel Collector 0.161.0 + Grafana/Tempo/Loki/Prometheus) — the Ch24 in-cluster LGTM backend on **minikube only**. Source: https://github.com/grafana/docker-otel-lgtm |
| otel/opentelemetry-collector-contrib | **0.163.1** — the Ch24 **CRC** telemetry sink: a minimal ROOTLESS collector under restricted-v2 (NO SCC exception, DRQ-072); evidence read from its debug/file exporters. Source: https://github.com/open-telemetry/opentelemetry-collector-releases |
| CRC KEDA (Custom Metrics Autoscaler) | OperatorHub **Custom Metrics Autoscaler** operator, pinned CSV, Manual approval — TBD-confirm-at-kickoff via `oc get packagemanifest`. The CRC counterpart to KEDA core for Ch23. |
| **Kubernetes deployment tier (TBD-at-kickoff; snapshot only, surveyed live when the relevant chapter lands)** | |
| Istio | Snapshot: **1.31.2**, released 2026-10-16. Source: https://github.com/istio/istio/releases/tag/1.31.2 — re-verify live when Ch25 (Istio + Wasm) lands |
| KEDA | Firmed to **v2.21.0** at r06d (see the Part 5 scaling tier above); this snapshot row stands for the later Ch25+ re-survey. Source: https://github.com/kedacore/keda/releases/tag/v2.21.0 |
| **wasi-nn (TBD-at-kickoff; snapshot only, surveyed live when the relevant chapter lands)** | |
| wasi-nn backend (OpenVINO) | Snapshot: the `wasmtime-wasi-nn` crate tracks wasmtime's version directly (v50.0.0 as of this survey; source https://crates.io/crates/wasmtime-wasi-nn). The OpenVINO backend toolkit itself is at **2026.4.1**, released 2026-10-01. Source: https://github.com/openvinotoolkit/openvino/releases/tag/2026.4.1 — re-verify live when Ch27 lands |

## Dependency policy

Pin every dependency to the **upstream latest stable** release at the time
it is surveyed, exactly — never a floating major or a `latest` tag — and bump
it as a deliberate, reviewed change rather than a side effect of an unrelated
commit. Favor maintained, actively developed open source only; no
vendor-specific cloud service is a dependency of any example in this site.
Prefer CNCF or otherwise vendor-neutral projects where a choice exists (KEDA,
Istio, OpenTelemetry) over a proprietary alternative. Rust **nightly** is used
only where a specific Wasm feature requires it, and only pinned to a dated
nightly, never a floating `nightly` channel.

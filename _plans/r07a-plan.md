# r07a — Part 6 Deviations, ch25: Istio + WebAssembly (proxy-wasm WasmPlugin)

Branch `r07a-istio` off main. First of the r07a/b/c split (user-gated: one deviation chapter per iteration).
Dual-cluster verified BY ME (user-gated live): minikube (Istio) + CRC (OpenShift Service Mesh 3).

## Gated decisions
- Split r07 into r07a (Istio) / r07b (Spin) / r07c (wasi-nn).
- ch25 = a REAL proxy-wasm `WasmPlugin` (WasmPlugin-primary; TrafficExtension covered as the newer unified API in the Decision/deeper-coverage). The headline teaching: proxy-wasm core-module ABI ≠ Component Model — different toolchain (`proxy-wasm` crate, plain `cargo build --target wasm32-wasip1`, NOT cargo-component), different host (Envoy sidecar), running in the SAME pod as our Component-Model cargo app under the containerd shim.
- Full dual-cluster by me: minikube + CRC/OSSM3.

## Pins (confirmed live 2026-10-22)
- Istio **1.31.2** (istioctl present); WasmPlugin API `extensions.istio.io/v1alpha1`. Note: Istio 1.30+ added TrafficExtension as the recommended unified API; WasmPlugin stays fully supported (istiod transforms it) — cover as forward path.
- proxy-wasm Rust SDK **0.2.5** (crates.io max_stable); target wasm32-wasip1, crate-type cdylib.
- Istio↔k8s skew risk: Istio 1.31 supports k8s 1.32–1.36; Part 5 pins minikube k8s 1.37.1 — verify at `istioctl install` precheck; pin minikube k8s into 1.32–1.36 for this chapter if needed (record as DRQ).
- CRC = OpenShift Service Mesh 3 (Sail/OSSM operator) via lgtm-crc; edge-TLS Route.

## Example: examples/part6-deviations/istio-wasmfilter/ (NEW, NOT a component)
- `proxy-wasm 0.2.5` cdylib → `filter.wasm` (plain `cargo build --target wasm32-wasip1`; NO cargo-component, NO bindings.rs, NOT in the drift gate). contracts/wit PRISTINE.
- Minimal cargo-domain HTTP filter: require an `x-cargo-tenant` request header (4xx if absent), inject an `x-cargo-filtered-by` response header. Deterministic, curl-provable at the mesh/Envoy layer (echoes ch20 embargo idea, different layer).
- Package as OCI wasm image `oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio` (wash push / docker). WasmPlugin loads it.

## Manifests: examples/part6-deviations/istio/
- minikube: `istio-install.sh` (istioctl 1.31.2 pinned, minimal/demo profile), namespace `istio-injection=enabled`, reuse the Part 5 cargo-http Deployment/RuntimeClass UNDER the mesh (sidecar injected), `wasmplugin.yaml`, ingress `Gateway`+`VirtualService`, nip.io host. `verify-istio-minikube.sh` (curl: 200 w/ injected header when `x-cargo-tenant` present; 4xx when absent; NO port-forward).
- CRC/OSSM3: `install-ossm.sh` (Sail operator + Istio/IstioCNI CRs, pinned CSV), edge-TLS Route, matching `wasmplugin.yaml`, `verify-istio-crc.sh` (CA-verified curl, no -k, no port-forward).
- Teaching: the cargo-http pod runs TWO Wasm worlds — our Component-Model app under containerd-shim-wasmtime + the proxy-wasm filter inside the injected Envoy.

## Chapter: _docs/25-istio-and-webassembly.md
House spine (match ch20-24): Learning objectives + Why this matters + near-top diagram + concrete boxes + callout--safe Decision (before For-deeper-coverage) + duration; ≥2000 words; ≥2 diagrams (light ink): (1) proxy-wasm-in-Envoy vs Component-Model-app-under-shim in one pod; (2) WasmPlugin/TrafficExtension module distribution + request path. 0 ban-tier (run scan.sh MYSELF — executor self-greps unreliable, r06d lesson). Footers "pending live verification" until the gated runs pass.

## CI
- `examples` job: add `cargo build --target wasm32-wasip1` of the filter (build-only; EXCLUDED from ALL_BINDINGS). `k8s-manifests`: kubeconform `wasmplugin.yaml` + Istio/OSSM CR instances (`-ignore-missing-schemas`). No cluster in CI.

## Steps
BUILD (offline): branch+plan [done] → filter crate → Istio manifests (minikube+CRC) + verify scripts → 2 diagrams → chapter → CI + plans → static gates green (jekyll build, kubeconform, scan.sh 0 ban-tier, contracts/wit pristine, chmod 755).
LIVE-VERIFY (user-gated, one cluster at a time, by me): minikube Istio → evidence; then CRC OSSM3 → evidence; flip footers to "verified live <date>" only on genuine PASS.

## Risks
proxy-wasm ABI/target mismatch (must be plain cargo cdylib wasm32-wasip1, loads in Envoy — verify live); Istio↔k8s 1.37 skew (precheck); OSSM3 operator footprint on CRC (heavy); WasmPlugin→TrafficExtension drift (documented). Clean-base + idempotent installs (DRQ-075 lesson).

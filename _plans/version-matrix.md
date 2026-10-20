---
title: "Version Matrix"
layout: plan
render_with_liquid: false
---

# Version Matrix

> Surveyed: 2026-10-20 (r01 bootstrap). Only the authoring-box toolchain below
> is confirmed by actual installation and a local build; every other row is a
> placeholder marked TBD-at-kickoff and gets a real, dated survey pass —
> checked against the vendor's own release notes, not memory — when the
> chapter or example that depends on it is written.

This is a placeholder laid down at r01 bootstrap. Nothing in this table is
authoritative yet except the authoring-box rows explicitly marked confirmed.

| Component | Version |
|---|---|
| **Authoring box (confirmed, installed)** | |
| Rust | 1.99.1 — installed and confirmed on the authoring box |
| cargo | 1.99.1 — ships with the Rust toolchain above |
| Go | 1.26.9 — installed and confirmed on the authoring box; primary Go path (DRQ-013) |
| TinyGo | 0.43.0 — installed and confirmed working against Go 1.26.9 / LLVM 22.1.4; optional sidebar path (DRQ-013) |
| **Wasm toolchain (TBD-at-kickoff)** | |
| wasmtime | TBD — survey live upstream release when Part 4 (Ch14) lands |
| wash (wasmCloud CLI) | TBD — survey live upstream release when Part 4 (Ch15/16) lands |
| wasm-tools | TBD — survey live upstream release when the Go component-adapter chapter lands |
| cargo-component | TBD — survey live upstream release when the Rust component chapters (Part 2) land |
| **Kubernetes deployment tier (TBD-at-kickoff)** | |
| containerd Wasm shim (runwasi) | TBD — survey live upstream release when Part 5 minikube chapters land |
| minikube / Kubernetes | TBD — survey the verified-live combination when Part 5 minikube chapters land; docker driver + containerd runtime only, per house convention |
| Istio | TBD — survey live upstream release when Ch25 (Istio + Wasm) lands |
| KEDA | TBD — survey live upstream release when Ch23 (scale-to-zero) lands |
| CRC / OpenShift Local | TBD — survey live upstream release when Ch19 lands |
| **wasi-nn (TBD-at-kickoff)** | |
| wasi-nn backend (OpenVINO) | TBD — survey live upstream release when Ch27 lands |

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

---
title: "Outline"
order: 0
overview: true
part: "Prerequisites"
description: "What this site covers and how it's organized: 29 chapters across 8 parts, Rust and Go built as components against one WIT contract."
---

This site teaches server-side WebAssembly against a single WIT contract for a
shipping and cargo domain. The same cargo-handling interface is implemented twice:
once as a **Rust component** and once as a **Go component**. Each then runs under
**wasmtime** standalone and under **wasmCloud** as a distributed actor, and deploys
to **Kubernetes** on both minikube and OpenShift Local (CRC). Every hands-on chapter
ships the same example in both languages, built against the same WIT world.

## Part 0: Prerequisites
- [0. Setup](../00-setup/)

## Part 1: Foundations
- [1. Why Server-Side WebAssembly](../01-why-server-side-webassembly/)
- [2. The Execution Model](../02-the-execution-model/)
- [3. The Component Model and WIT](../03-component-model-and-wit/)
- [4. WASI Preview 2](../04-wasi-preview-2/)
- [5. The Shared Cargo Domain as Components](../05-shared-cargo-domain-as-components/)

## Part 2: Building Components in Rust & Go
- [6. First Component in Rust](../06-first-component-in-rust/)
- [7. First Component in Go](../07-first-component-in-go/)
- [8. Composing Components and WIT Worlds](../08-composing-components-and-wit-worlds/)
- [9. Debugging WebAssembly](../09-debugging-webassembly/)
- [10. Error and Exception Handling](../10-error-and-exception-handling/)

## Part 3: Interfaces: HTTP and gRPC
- [11. HTTP from a Component](../11-http-from-a-component/)
- [12. gRPC with Wasm](../12-grpc-with-wasm/)
- [13. Networking, Reconnect, and Resilience](../13-networking-reconnect-resilience/)

## Part 4: Runtimes: wasmtime & wasmCloud
- [14. wasmtime](../14-wasmtime/)
- [15. wasmCloud](../15-wasmcloud/)
- [16. wasmtime and wasmCloud Together](../16-wasmtime-and-wasmcloud-together/)

## Part 5: Deploying to Kubernetes
- [17. Wasm on Kubernetes](../17-wasm-on-kubernetes/)
- [18. Deploying on minikube](../18-deploying-on-minikube/)
- [19. Deploying on OpenShift Local (CRC)](../19-openshift-local-crc/)
- [20. Wasm as a Sidecar](../20-wasm-as-a-sidecar/)
- [21. Ambassador and Adapter Patterns with Wasm](../21-ambassador-and-adapter-patterns/)
- [22. Scaling Wasm Workloads: HPA](../22-scaling-wasm-workloads-hpa/)
- [23. Serverless Wasm: Scale-to-Zero with KEDA](../23-serverless-wasm-scale-to-zero-keda/)
- [24. Observability On-Cluster](../24-observability-on-cluster/)

## Part 6: Deviations
- [25. Istio and WebAssembly](../25-istio-and-webassembly/)
- [26. WebAssembly for Other Backend Architectures](../26-wasm-for-other-backend-architectures/)
- [27. wasi-nn: Portable Inference from Wasm](../27-wasi-nn/)

## Part 7: Final Project
- [28. Final Project](../28-final-project/)

---
title: "Examples"
layout: plan
permalink: /examples/
description: "Every runnable example in this repo, mapped to the chapter it supports."
---

Every hands-on chapter ships a runnable example under
[`examples/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples),
built against the one WIT world in
[`contracts/wit`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/contracts/wit).
Most examples carry **both** a Rust and a Go component behind that shared
contract; the runtime and deployment examples take the composed artifact and run
it on wasmtime, wasmCloud, minikube, and OpenShift Local.

| Example | What it shows | Stacks | Chapter |
|---|---|---|---|
| [part2-building-components](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part2-building-components) | The Rust and Go provider and consumer components, and the native host that proves both behave identically | Rust + Go | [Ch6]({{ '/docs/06-first-component-in-rust/' | relative_url }})–[Ch8]({{ '/docs/08-composing-components-and-wit-worlds/' | relative_url }}) |
| [part3-interfaces](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part3-interfaces) | wasi-http front doors, protobuf in a component, the tonic gRPC bridge, and wasi-sockets reconnect | Rust + Go | [Ch11]({{ '/docs/11-http-from-a-component/' | relative_url }})–[Ch13]({{ '/docs/13-networking-reconnect-resilience/' | relative_url }}) |
| [part4-runtimes/wasmtime-host](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part4-runtimes/wasmtime-host) | The component embedded directly with wasmtime under fuel, epoch, and memory limits | Rust | [Ch14]({{ '/docs/14-wasmtime/' | relative_url }}) |
| [part4-runtimes/wasmcloud](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part4-runtimes/wasmcloud) | The same component run under the wasmCloud lattice, with the same-bytes proof against wasmtime | Rust | [Ch15]({{ '/docs/15-wasmcloud/' | relative_url }})–[Ch16]({{ '/docs/16-wasmtime-and-wasmcloud-together/' | relative_url }}) |
| [part5-kubernetes/k8s](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part5-kubernetes/k8s) | Deploy to minikube under the containerd-shim-wasmtime RuntimeClass, through ingress-nginx | Rust + Go | [Ch18]({{ '/docs/18-deploying-on-minikube/' | relative_url }}) |
| [part5-kubernetes/openshift](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part5-kubernetes/openshift) | The same component on OpenShift Local (CRC) via the wasmCloud operator and an edge-TLS Route | Rust + Go | [Ch19]({{ '/docs/19-openshift-local-crc/' | relative_url }}) |
| [part5-kubernetes interposition](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part5-kubernetes) | Sidecar filter, ambassador egress grant, and adapter shape-translation interposed on the provider | Rust + Go | [Ch20]({{ '/docs/20-wasm-as-a-sidecar/' | relative_url }})–[Ch21]({{ '/docs/21-ambassador-and-adapter-patterns/' | relative_url }}) |
| [part5-kubernetes/k8s/scaling](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part5-kubernetes/k8s/scaling) | A stock Horizontal Pod Autoscaler wired to a Wasm Deployment | Rust + Go | [Ch22]({{ '/docs/22-scaling-wasm-workloads-hpa/' | relative_url }}) |
| [part5-kubernetes/k8s/keda](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part5-kubernetes/k8s/keda) | KEDA HTTP scale-to-zero and Kafka lag scaling, with the native kafka-host | Rust + Go | [Ch23]({{ '/docs/23-serverless-wasm-scale-to-zero-keda/' | relative_url }}) |
| [part5-kubernetes/k8s/observability](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part5-kubernetes/k8s/observability) | The containerd shim's OTel export into the LGTM stack | Rust + Go | [Ch24]({{ '/docs/24-observability-on-cluster/' | relative_url }}) |
| [part6-deviations/istio](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part6-deviations/istio) | The proxy-wasm gateway filter enforcing the `x-cargo-tenant` contract on the Istio ingress | Rust + Go | [Ch25]({{ '/docs/25-istio-and-webassembly/' | relative_url }}) |
| [part6-deviations/spinkube](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part6-deviations/spinkube) | The Spin app on SpinKube (minikube) and in a restricted-v2 container (CRC) | Rust | [Ch26]({{ '/docs/26-wasm-for-other-backend-architectures/' | relative_url }}) |
| [part6-deviations/wasi-nn](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part6-deviations/wasi-nn) | wasi-nn image classification from a component, on the OpenVINO backend | Rust | [Ch27]({{ '/docs/27-wasi-nn/' | relative_url }}) |
| [part7-final-project](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/part7-final-project) | The final project: both language composites behind the Istio filter, with OTel, on minikube and CRC | Rust + Go | [Ch28]({{ '/docs/28-final-project/' | relative_url }}) |

## Build, run, observe

Each example is self-contained: a `README.md`, a build script, and a `verify*.sh`
(or `run.sh`) that builds the component against the shared WIT contract, runs it,
and asserts its behavior. The cluster examples assert a real HTTP response through
the edge, with no port-forward and no NodePort.

```bash
cd examples/part2-building-components && ./verify.sh   # local: both components + host
cd examples/part5-kubernetes/k8s && ./verify-minikube.sh   # cluster: minikube
```

Each chapter's **Build, run, observe** section names the exact script for that
example and what it asserts. See [Setup]({{ '/docs/00-setup/' | relative_url }})
for the toolchain.

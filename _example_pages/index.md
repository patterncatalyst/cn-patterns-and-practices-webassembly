---
title: "Examples"
layout: plan
permalink: /examples/
description: "Every runnable example in this repo, mapped to the chapter it supports."
---

Every hands-on chapter ships a Rust component and a Go component built
against the same WIT world in [`contracts/wit`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/contracts/wit), composed with `wac plug`, and
deployable to both minikube and OpenShift Local (CRC). Browse the source
under [`examples/`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/examples):

- [`part2-building-components/`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/examples/part2-building-components): the Rust and Go provider components, their consumer counterparts, and the native host that proves both providers behave identically.
- [`part3-interfaces/`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/examples/part3-interfaces): wasi-http front doors, protobuf-in-Wasm, the tonic gRPC bridge, and wasi-sockets reconnect.
- [`part4-runtimes/`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/examples/part4-runtimes): the same component embedded directly with wasmtime, and run under wasmCloud.
- [`part5-kubernetes/`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/examples/part5-kubernetes): deployment to minikube and OpenShift Local, the sidecar/ambassador/adapter interposition patterns, HPA and KEDA scale-to-zero.
- [`part6-deviations/`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/examples/part6-deviations): Istio and WebAssembly, Spin and SpinKube, and wasi-nn inference from a component.
- [`part7-final-project/`](https://github.com/patterncatalyst/cn-patterns-and-practices-webassembly/tree/main/examples/part7-final-project): the final project, assembling the book's components into one deployable system.

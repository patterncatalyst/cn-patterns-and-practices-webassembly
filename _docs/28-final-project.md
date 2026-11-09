---
title: "Final Project"
order: 28
part: "Final Project"
description: "Run the cargo domain end to end across the Rust and Go components, deployed on-cluster, with the shim's OTel export live in Grafana's Tempo."
duration: "15 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain how `build.sh` assembles `cargo-rust.wasm` and `cargo-go.wasm` without editing `contracts/wit` or any component: each composite is `wac plug`-ged from its own Part 2 provider and Part 3 HTTP front door.
- State the two-language-one-contract thesis concretely: one `patterncatalyst:cargo` WIT world, implemented once in Rust and once in Go, composed into two `wasi:http/incoming-handler` artifacts that answer byte-identical JSON for the same request.
- Trace the minikube request path for both languages: `nip.io` host, ingress-nginx, Service, Pod on `runtimeClassName: wasmtime`, `containerd-shim-wasmtime`, composite.
- Explain why the proxy-wasm `WasmPlugin` gates two backends with no change: it runs once in the shared `istio-ingressgateway` Envoy, ahead of either Service.
- State what the on-cluster trace proves for two deployed languages and what it cannot: shim-OTel liveness under the assembled workload, not a per-language `service.name` and not a span through either guest's domain logic.
- Contrast the tiers: minikube runs the full assembly (shim, Istio filter, trace); OpenShift Local runs both composites as wasmCloud components behind two httpserver providers and two edge-TLS Routes, with no mesh, because the shim's node-level install is unavailable under `restricted-v2`.

## Why this matters

Each earlier part proved one claim: a WIT world can be implemented twice against the same `contracts/wit`; either provider can sit behind a `wasi:http` front door; the composite runs under `wasmtime` and wasmCloud; it runs as a Kubernetes Pod with its own OTel signal; a mesh filter can sit in front of it without touching its Deployment. Each used one composite, almost always the Rust one, on one more substrate. The final project runs both composites, Rust and Go, through every substrate side by side behind the same edge.

`examples/part7-final-project/build.sh` writes no new provider, front door or line of `contracts/wit`. It rebuilds the Part 2 Rust provider and the Part 3 `http-rust` front door with their own recipes and `wac plug`s them into `cargo-rust.wasm`, then does the same on the Go side with the Part 2 Go provider and the Part 3 `http-go` TinyGo front door into `cargo-go.wasm`. `cargo-rust.wasm` is the same bytes as the `app.wasm` carried since the wasmtime chapter, sha256 `eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3`. `cargo-go.wasm` is its TinyGo counterpart, sha256 `17b0fca2f591650d89ee2f854ac9af1dfd6fccee17dacec9417bc2dfbb439839`. Two toolchains, two language runtimes inside the component, one contract, one response:

```
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
```

{% include excalidraw.html file="28-one-contract-two-languages" alt="A thread map. Top, an accent box labeled contracts/wit, patterncatalyst:cargo, the one contract. Two columns descend from it. Left column: Part 2 Rust cargo provider implementing contracts/wit, feeding Part 3 http-rust component (wasi:http/incoming-handler), feeding cargo-rust.wasm. Right column: Part 2 Go cargo provider implementing contracts/wit, feeding Part 3 http-go/TinyGo component, feeding cargo-go.wasm. Both composites feed down into a bottom band labeled Shared deploy targets, listing four targets: the containerd shim, the Istio gateway filter, the shim-to-otel-lgtm OTel pipeline, and the wasmCloud operator on OpenShift Local." caption="Figure 28.2: One contract, two language implementations, converging on the same four deploy targets." %}

Every deploy target here (the containerd shim, the Istio gateway filter, the OTel pipeline, the wasmCloud operator) was already built for one language. Running two languages through them adds no new engineering. It turns the portability claim from an assertion about one component into a property of a running system: two Pods, two source languages, one answer.

## The assembly: two composites, one contract

After `wac plug` satisfies the `patterncatalyst:cargo` import on each side, `build.sh` checks that the `.wasm` exports `wasi:http/incoming-handler` and that every remaining import starts with `wasi:`. No `patterncatalyst:*` import survives composition in either language:

{% raw %}
```bash
assert_http_composite() {
  local wasm="$1" label="$2"
  local wit
  wit="$(wasm-tools component wit "$wasm")"
  if ! grep -q 'export wasi:http/incoming-handler' <<<"$wit"; then
    echo "build.sh: FAIL, $label does not export wasi:http/incoming-handler" >&2
    exit 1
  fi
  local bad
  bad="$(grep -E '^\s*import ' <<<"$wit" | grep -v 'import wasi:' || true)"
  if [[ -n "$bad" ]]; then
    echo "build.sh: FAIL, $label still imports a non-wasi interface after wac plug:" >&2
    echo "$bad" >&2
    exit 1
  fi
  echo "build.sh: ok, $label exports wasi:http/incoming-handler, imports only wasi:*"
}
```
{% endraw %}

It then serves each composite under `wasmtime serve -S cli` on its own local port and requests the canonical tracking id and an unknown one. Both composites must return the exact JSON and a 404 before either is packaged. Packaging uses one parameterized `Containerfile` that takes `WASM` as a build argument, so a single recipe produces `cargo-rust:final` and `cargo-go:final`:

{% raw %}
```dockerfile
ARG WASM=cargo-rust.wasm

FROM scratch
ARG WASM
COPY ${WASM} /app.wasm
# The shim uses the OCI command/args to locate the module in the rootfs. The
# Deployment sets `command: ["/app.wasm"]` explicitly, but ENTRYPOINT is set
# here too so `ctr run <image> <id>` (a go/no-go smoke test with no extra args)
# also works.
ENTRYPOINT ["/app.wasm"]
```
{% endraw %}

`docker build --provenance=false` keeps each image a single-manifest, single-layer rootfs. The containerd shim reads `/app.wasm` directly and needs no Linux userland, the same shape as every Part 5 image. `--load` copies both images into the minikube node's containerd store with `minikube image load`, with no registry.

## Deploy: two Pods on the shim, one filter at the gateway

`k8s/base/deployment-rust.yaml` and `deployment-go.yaml` copy the Part 5 base Deployment, one per language:

{% raw %}
```yaml
    spec:
      runtimeClassName: wasmtime
      containers:
        - name: cargo-rust
          image: cargo-rust:final
          imagePullPolicy: IfNotPresent
          command: ["/app.wasm"]
          ports:
            - name: http
              containerPort: 8080
```
{% endraw %}

Probes are TCP on 8080, because the component answers `GET /` with 404 and an HTTP probe would fail. No `securityContext` is set, matching Part 5: there is no evidence that restrictive `PodSecurityContext` fields are compatible with a Wasm module run by the containerd shim rather than a Linux process under `runc`, so none is invented. Each Deployment gets its own Service on 8080.

One `Ingress` carries two host-based rules. Both composites answer `GET /cargo/{id}` unprefixed, so a path split would need a rewrite-target annotation to strip the prefix that ingress-nginx added. Host-based routing needs none:

{% raw %}
```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: cargo-rust.part7-final-project.example
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cargo-rust
                port:
                  number: 8080
    - host: cargo-go.part7-final-project.example
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cargo-go
                port:
                  number: 8080
```
{% endraw %}

`verify-minikube.sh` patches both hosts live to `cargo-rust.<minikube-ip>.nip.io` and `cargo-go.<minikube-ip>.nip.io`, and checks the Ingress's affinity cookie (`part7-cargo-affinity`) first, so a response that never went through these rules cannot count as proof.

The Istio side makes the same host-not-path choice. `istio/base/gateway.yaml` defines one `Gateway` listener with two hosts on the same `istio: ingressgateway` workload that the earlier Istio `Gateway` selects. Istio merges `Gateway` resources on one workload as long as their hosts do not collide, so the two coexist without editing either. `istio/base/virtualservice.yaml` routes each host by `authority` match:

{% raw %}
```yaml
spec:
  hosts:
    - "cargo-rust-istio.part7-final-project.example"
    - "cargo-go-istio.part7-final-project.example"
  gateways:
    - cargo-final-gateway
  http:
    - match:
        - authority:
            exact: "cargo-rust-istio.part7-final-project.example"
      route:
        - destination:
            host: cargo-rust.part7-final-project.svc.cluster.local
            port:
              number: 8080
    - match:
        - authority:
            exact: "cargo-go-istio.part7-final-project.example"
      route:
        - destination:
            host: cargo-go.part7-final-project.svc.cluster.local
            port:
              number: 8080
```
{% endraw %}

`istio/gateway-wasmplugin.yaml` is the proxy-wasm filter from the Istio-and-WebAssembly chapter with the same `metadata.name` (`cargo-wasmfilter`), namespace (`istio-system`), selector, OCI reference and `phase: AUTHZ`. It is copied so this directory is self-contained. Applying it does not create a second filter; whichever verify script runs last re-confirms the one live `WasmPlugin`. Because it loads into the gateway's Envoy rather than a sidecar, it gates every request that reaches the gateway, for either backend, with one contract: 403 without `x-cargo-tenant`, 200 plus `x-cargo-filtered-by: cargo-wasmfilter` with it. Neither Pod carries an Istio injection label or a sidecar. Both stay pure Wasm Pods.

{% include excalidraw.html file="28-final-project-request-path" alt="A client resolves either cargo-rust or cargo-go nip.io hosts through the minikube Ingress, or resolves the istio-labeled hosts through the Istio ingress gateway's NodePort. At the Istio gateway, the proxy-wasm cargo-wasmfilter runs first, authorizing on x-cargo-tenant: missing returns 403, present continues and gets x-cargo-filtered-by stamped on the response. Past either edge, two Pods sit side by side under RuntimeClass wasmtime, hosted by containerd-shim-wasmtime: cargo-rust (http-rust plugged with the Rust cargo provider) and cargo-go (http-go/TinyGo plugged with the Go cargo provider), both exporting wasi:http/incoming-handler and both returning the identical cargo JSON. A lower band shows each Pod's shim emitting an OTel span per invocation into the shared otel-lgtm sink (Tempo), labeled with a scope note: both shims report the same node-level service.name, so the signal is shim-OTel liveness under the workload, not a per-language label." caption="Figure 28.1: The assembled request path on minikube: two edges (ingress-nginx and the Istio gateway with the proxy-wasm filter), two language Pods on the shim, one shared OTel pipeline." %}

Through ingress-nginx, both hosts return the exact cargo JSON and a 404 on an unknown id, and the two bodies are compared with each other as well as with the expected string:

{% raw %}
```bash
rust_body="$(curl_body "http://$RUST_HOST$CARGO_PATH")"
echo "verify-minikube.sh: GET $CARGO_PATH (rust) -> $rust_body"
assert_eq "$EXPECTED_JSON" "$rust_body" "minikube GET $CARGO_PATH through ingress (cargo-rust)"
rust_404="$(curl_code "http://$RUST_HOST/cargo/NOPE")"
assert_eq "404" "$rust_404" "minikube GET /cargo/NOPE through ingress (cargo-rust)"

go_body="$(curl_body "http://$GO_HOST$CARGO_PATH")"
echo "verify-minikube.sh: GET $CARGO_PATH (go) -> $go_body"
assert_eq "$EXPECTED_JSON" "$go_body" "minikube GET $CARGO_PATH through ingress (cargo-go)"
go_404="$(curl_code "http://$GO_HOST/cargo/NOPE")"
assert_eq "404" "$go_404" "minikube GET /cargo/NOPE through ingress (cargo-go)"

assert_eq "$rust_body" "$go_body" "cargo-rust and cargo-go responses are byte-identical"
```
{% endraw %}

Through the Istio gateway, each host gets the filter contract in turn: no `x-cargo-tenant` returns 403, and `x-cargo-tenant: acme` returns 200 with the exact JSON and `x-cargo-filtered-by: cargo-wasmfilter`, so the shared filter demonstrably ran ahead of whichever backend the `Host` header selected.

KEDA scale to zero is left out here. The HTTP add-on's scaler and the Istio gateway both want to own the ingress role, so this project treats scale to zero as the serverless alternative to these always-on Deployments, not an addition to them.

## Observability: one pipeline, a bounded trace scope

The shim's OTel export is the mechanism from the on-cluster observability chapter, pointed at the same `otel-lgtm` sink, with no new configuration for a second language. `enable-shim-otel.sh` sets `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME` as a systemd `Environment=` on the `containerd.service` unit, a node-level setting that every shim process inherits identically. So `cargo-rust`'s and `cargo-go`'s shims report the same `resource.service.name`, `containerd-shim-wasmtime`, and Tempo cannot filter to `cargo-go` by service name. The pinned shim attaches no `k8s.pod.name` or image-name attribute to its spans, because its OTel integration is unaware of Kubernetes metadata.

What the pipeline proves is liveness. `verify-minikube.sh` drives traffic to both languages, queries Tempo's `/api/search` for the shared shim service name and requires at least one trace:

{% raw %}
```bash
for i in 1 2 3; do curl_body "http://$RUST_HOST$CARGO_PATH" >/dev/null; curl_body "http://$GO_HOST$CARGO_PATH" >/dev/null; done
sleep 10
shim_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
echo "verify-minikube.sh: Tempo trace count for '$SHIM_SVC' after the workload = $shim_count"
if (( shim_count <= 0 )); then
  echo "verify-minikube.sh: FAIL, no traces in Tempo for '$SHIM_SVC' after the assembled workload ran" >&2
  exit 1
fi
echo "verify-minikube.sh: ok, the shim exported $shim_count trace(s) for '$SHIM_SVC' into otel-lgtm (shim-OTel pipeline live under the final-project workload)"
```
{% endraw %}

The count is read with `kubectl exec` into the `otel-lgtm` Pod: no port-forward and no Grafana UI. A per-language count is unreliable, since both languages land under one service and Tempo's search caps its result set. The scope also excludes a single trace that follows one request from the Istio filter through either guest's call graph. The shim's span describes a Pod's invocation lifecycle at the container boundary, not anything the `patterncatalyst:cargo` component executed.

## OpenShift Local: the reduced pass

minikube runs the full assembly. OpenShift Local runs both composites under the wasmCloud operator behind two httpserver providers and two edge-TLS Routes, with no mesh and no trace capture. The containerd shim needs a privileged node-level install that `restricted-v2` forbids, so the mesh and shim-trace passes stay minikube-only. That is a substrate boundary, not a gap.

`wadm-final.yaml` defines two OAM `Application`s, `cargo-final-rust` and `cargo-final-go`, each one component plus its own httpserver provider on `0.0.0.0:8000`. The Rust one:

{% raw %}
```yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: cargo-final-rust
  annotations:
    version: v0.0.1
    description: "Part 7 final project, Rust cargo composite on the wasmCloud lattice (CRC)"
spec:
  components:
    - name: cargo-rust
      type: component
      properties:
        image: __RUST_REF__
      traits:
        - type: daemonscaler
          properties:
            replicas: 1

    - name: httpserver-rust
      type: capability
      properties:
        image: ghcr.io/wasmcloud/http-server:0.27.0
      traits:
        - type: link
          properties:
            target: cargo-rust
            namespace: wasi
            package: http
            interfaces:
              - incoming-handler
            source_config:
              - name: cargo-rust-listen
                properties:
                  address: 0.0.0.0:8000
        - type: daemonscaler
          properties:
            replicas: 1
```
{% endraw %}

The Go Application mirrors it with the Go composite. The operator creates one Kubernetes Service per httpserver provider scaled with a `daemonscaler`, named after the Application, so two Applications yield two Services. Each Service is fronted by its own edge-TLS Route:

{% raw %}
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cargo-final-rust
  labels:
    app.kubernetes.io/part-of: part7-final-project
    app.kubernetes.io/component: cargo-rust
spec:
  to:
    kind: Service
    name: cargo-final-rust
  port:
    targetPort: 8000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cargo-final-go
  labels:
    app.kubernetes.io/part-of: part7-final-project
    app.kubernetes.io/component: cargo-go
spec:
  to:
    kind: Service
    name: cargo-final-go
  port:
    targetPort: 8000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```
{% endraw %}

`verify-crc.sh` proves both Routes with a CA-verified `curl` against the combined system and ingress CA bundle (never `-k`, a port-forward or a NodePort), and requires the same byte-identical JSON and the 404. Everything runs in a `wasmcloud-final` project under `restricted-v2`. The `WasmCloudHostConfig` CRD has no `securityContext` field, and `restricted-v2` assigns namespace-range UIDs, drops all capabilities, forbids privilege escalation and defaults seccomp to `RuntimeDefault` on its own. `values-crc.yaml` drops wadm's hard-coded `runAsUser` and `runAsGroup: 1000` for the same reason. No `anyuid` exception is requested.

> **Decision**
>
> Treat the assembly as the proof of the two-language thesis: `contracts/wit` is read by two build pipelines and written by neither, and both outputs return the same JSON through two edges on two clusters. Treat the mesh filter as proof that a cross-cutting policy written once against `proxy-wasm` covers a second language with no per-backend duplication, because it inspects the request, never the composite behind it. Treat the shim's OTel signal as liveness and nothing stronger, because `OTEL_SERVICE_NAME` is set once per node, not once per Pod. Treat the minikube and OpenShift Local split as a substrate boundary: minikube proves the shim and the mesh filter because both need node-level capabilities that `restricted-v2` withholds, and OpenShift Local proves the same application-layer contract through the wasmCloud operator and two Routes.

## Build, run, observe

```bash
cd examples/part7-final-project && ./build.sh && ./verify-minikube.sh
```

`build.sh` assembles both composites, checks each export and import set, and smoke-tests both under `wasmtime serve` before packaging. `verify-minikube.sh` deploys both on the shared `part5` minikube profile under `runtimeClassName: wasmtime`, adds the Istio filter, wires the shim's OTel export into `otel-lgtm`, and passes when: both languages answer byte-identical JSON (and 404) through ingress-nginx; the `x-cargo-tenant` contract holds through the Istio gateway for both; and Tempo holds at least one shim trace. `openshift/verify-crc.sh` runs the OpenShift Local counterpart. `capture-evidence.sh` and `openshift/capture-evidence.sh` write the `evidence/<date>/` files; `README.md` documents the setup for both clusters.

## For deeper coverage

- The shared cargo domain as components, and composing components and WIT worlds: the `contracts/wit` world and the `wac plug` technique `build.sh` reuses on both languages.
- Wasmtime, and wasmtime and wasmCloud together: the provenance of the `eff7f5ee...` hash of `cargo-rust.wasm` across runtimes.
- Deploying on minikube and on OpenShift Local (CRC): the containerd shim, the `runtimeClassName: wasmtime` Deployment shape and the `restricted-v2` posture `k8s/base` and `openshift/` build on.
- Serverless Wasm, scale to zero with KEDA: the serverless alternative to these always-on Deployments.
- Observability on cluster: the node-level `OTEL_SERVICE_NAME` mechanism and the substrate-versus-guest telemetry boundary.
- Istio and WebAssembly: the unchanged proxy-wasm `WasmPlugin` that gates both backends.
- [`wac` (WebAssembly Composition tool)](https://github.com/bytecodealliance/wac): the composition tool `build.sh` calls once per language to produce `cargo-rust.wasm` and `cargo-go.wasm`.

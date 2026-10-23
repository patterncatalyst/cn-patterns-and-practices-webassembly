---
title: "Final Project"
order: 28
part: "Final Project"
description: "Run the cargo domain end to end across the Rust and Go components, deployed on-cluster, with one trace in Grafana tying the whole request path together."
duration: "18 min read"
---

## Learning objectives

By the end of this chapter you can:

- Read `examples/part7-final-project/build.sh` and explain how `cargo-rust.wasm` and `cargo-go.wasm` are assembled without editing `contracts/wit` or any existing component: each composite is `wac plug`-ged from its own Part 2 provider and Part 3 HTTP front door, exactly as `examples/part4-runtimes/wasmcloud/build.sh` already does for the Rust half.
- State the two-language-one-contract thesis in concrete terms: the same `patterncatalyst:cargo` WIT world, implemented once in Rust and once in Go, composed into two separate `wasi:http/incoming-handler` artifacts that answer byte-identical JSON for the same request.
- Read `k8s/base/deployment-rust.yaml`, `deployment-go.yaml`, and `ingress.yaml` and trace the minikube request path for both languages: `nip.io` host → ingress-nginx → Service → Pod on `runtimeClassName: wasmtime` → `containerd-shim-wasmtime` → composite.
- Explain why the Ch25 proxy-wasm `WasmPlugin` needs no change to gate two backends instead of one: the filter runs once in the shared `istio-ingressgateway` Envoy, ahead of either Service, so the `x-cargo-tenant` contract (403 without the header, 200 plus `x-cargo-filtered-by` with it) applies identically to `cargo-rust` and `cargo-go`.
- State precisely what the on-cluster trace does and does not prove for two deployed languages: `OTEL_SERVICE_NAME` is a node-level `containerd.service` setting every shim process inherits identically, so Tempo cannot show a per-language `service.name`; what is provable is shim-OTel liveness under the assembled workload (traces present for the shim service), not a per-language label or a stitched end-to-end span through either guest's domain logic.
- Contrast the minikube and CRC tiers for this final project: minikube runs the full assembly (shim, Istio filter, trace); CRC runs both composites as wasmCloud components behind two httpserver providers and two edge-TLS Routes, with no mesh, because the shim's node-level install is unavailable under `restricted-v2`.

## Why this matters

Every part of this book up to here proved one claim at a time: Part 2 proved a WIT world can be implemented twice, once in Rust and once in Go, against the identical `contracts/wit`. Part 3 proved either provider can sit behind a `wasi:http` front door. Part 4 proved the resulting composite runs unmodified under `wasmtime` and under wasmCloud. Part 5 proved it runs as a Kubernetes Pod, with its own OTel signal. Part 6 proved a mesh-layer filter can sit in front of it without touching its Deployment. Each of those chapters picked one composite (almost always the Rust one) and ran it through one more substrate. This final project runs both composites, Rust and Go, through every substrate at once, side by side, behind the same edge.

`examples/part7-final-project/build.sh` is the whole point stated as code: it does not write a new provider, a new front door, or a new line of `contracts/wit`. It rebuilds the Part 2 Rust provider and the Part 3 `http-rust` front door with their own unedited recipes, `wac plug`s them into `cargo-rust.wasm`, then does the identical thing on the Go side (the Part 2 Go provider, the Part 3 `http-go` TinyGo front door) into `cargo-go.wasm`. `cargo-rust.wasm` is not merely similar to the `app.wasm` this book has carried since Chapter 14; it is the same bytes, sha256 `eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3`, confirmed against every runtime this book has run it under. `cargo-go.wasm` is the TinyGo counterpart, sha256 `17b0fca2f591650d89ee2f854ac9af1dfd6fccee17dacec9417bc2dfbb439839`, assembled here from the same two unedited recipes on the Go side. Two different toolchains, two different language runtimes inside the component, one WIT contract, one JSON response:

```
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
```

{% include excalidraw.html file="28-one-contract-two-languages" alt="A thread map. Top, an accent box labeled contracts/wit, patterncatalyst:cargo, the one contract. Two columns descend from it. Left column: Part 2 Rust cargo provider implementing contracts/wit, feeding Part 3 http-rust component (wasi:http/incoming-handler), feeding cargo-rust.wasm. Right column: Part 2 Go cargo provider implementing contracts/wit, feeding Part 3 http-go/TinyGo component, feeding cargo-go.wasm. Both composites feed down into a bottom band labeled Shared deploy targets: where the final project assembles, listing four targets: the containerd shim (Part 5), the Istio gateway filter (Part 6, Ch25), the shim-to-otel-lgtm OTel pipeline (Ch24), and the wasmCloud operator on CRC (Ch19)." caption="Figure 28.2: one contract, two language implementations, converging on the same four deploy targets this book already built." %}

Figure 28.2 names the convergence directly: every deploy target this final project exercises (the containerd shim, the Istio gateway filter, the OTel pipeline, the wasmCloud operator) is a chapter this book has already written and already verified for one language. Nothing about running two languages through them is new engineering; what is new is running them at the same time, against the same edge, so the two-language-one-contract claim stops being an assertion about one component's portability and becomes a visible property of a running system: two Pods, two source languages, one answer.

## The assembly: `build.sh`, two composites, one contract

`build.sh` validates both composites before it packages anything. After `wac plug` satisfies the `patterncatalyst:cargo` import on each side, it asserts two things on the resulting `.wasm`: that it exports `wasi:http/incoming-handler`, and that every remaining import starts with `wasi:`; no `patterncatalyst:*` import survives composition, on either language:

```bash
assert_http_composite() {
  local wasm="$1" label="$2"
  local wit
  wit="$(wasm-tools component wit "$wasm")"
  if ! grep -q 'export wasi:http/incoming-handler' <<<"$wit"; then
    echo "build.sh: FAIL — $label does not export wasi:http/incoming-handler" >&2
    exit 1
  fi
  local bad
  bad="$(grep -E '^\s*import ' <<<"$wit" | grep -v 'import wasi:' || true)"
  if [[ -n "$bad" ]]; then
    echo "build.sh: FAIL — $label still imports a non-wasi interface after wac plug:" >&2
    echo "$bad" >&2
    exit 1
  fi
}
```

The script then smoke-tests each composite under `wasmtime serve -S cli` on its own local port, curling the canonical tracking id and an unknown one, before either composite is allowed anywhere near an OCI image:

```bash
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

serve_assert() {
  local label="$1" composed="$2" port="$3"
  wasmtime serve -S cli "$composed" --addr "127.0.0.1:$port" >"$log" 2>&1 &
  ...
  body="$(curl -s "$base/cargo/CARGO-USNYC-DEHAM")"
  assert_eq "$EXPECTED_JSON" "$body" "$label GET /cargo/CARGO-USNYC-DEHAM body"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$base/cargo/NOPE")"
  assert_eq "404" "$code" "$label GET /cargo/NOPE status"
}
```

Both composites pass this gate before `build.sh` packages either one as an OCI image. Packaging uses one parameterized `Containerfile`, `FROM scratch`, taking `WASM` as a build-arg so a single recipe produces `cargo-rust:final` and `cargo-go:final` without forking the Dockerfile per language:

```dockerfile
ARG WASM=cargo-rust.wasm

FROM scratch
ARG WASM
COPY ${WASM} /app.wasm
ENTRYPOINT ["/app.wasm"]
```

`docker build --provenance=false` keeps each image a single-manifest, single-layer rootfs: the containerd shim reads `/app.wasm` directly and needs no Linux userland underneath it, the same shape every Part 5 image has used. A `--load` flag copies both images straight into the minikube node's containerd image store with `minikube image load`, no registry round trip, matching the docker-driver-plus-containerd convention this book has used since Part 5. Nothing in this pipeline is new infrastructure: it is the Part 2 build, the Part 3 build, `wac plug`, and the Part 5 packaging convention, run twice in parallel and gated by the same assertions on both outputs.

## Deploy: two Pods on the shim, one filter at the gateway

`k8s/base/deployment-rust.yaml` and `deployment-go.yaml` are a straight copy of the Part 5 base Deployment shape, one per language, each on `runtimeClassName: wasmtime` with `command: ["/app.wasm"]` and TCP probes on 8080: the component answers `GET /` with 404, so a TCP probe, not an HTTP probe, is the correct liveness signal, the same reasoning Part 5 used. No `securityContext` is set, matching Part 5's base Deployment exactly: this RuntimeClass path has no committed evidence anywhere in this book that restrictive `PodSecurityContext` fields are compatible with a Wasm module run by the containerd shim rather than a Linux process under `runc`, so this chapter does not invent one. Each Deployment gets its own Service on port 8080:

```yaml
spec:
  replicas: 1
  template:
    spec:
      runtimeClassName: wasmtime
      containers:
        - name: cargo-rust
          image: cargo-rust:final
          command: ["/app.wasm"]
          ports:
            - name: http
              containerPort: 8080
```

One `Ingress`, `k8s/base/ingress.yaml`, carries two host-based rules rather than one host with path prefixes. Both composites answer their own `GET /cargo/{id}` unprefixed, so a path split would need a rewrite-target annotation to strip a prefix ingress-nginx itself added; host-based routing needs none:

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: cargo-rust.part7-final-project.example
      http:
        paths:
          - path: /
            backend: { service: { name: cargo-rust, port: { number: 8080 } } }
    - host: cargo-go.part7-final-project.example
      http:
        paths:
          - path: /
            backend: { service: { name: cargo-go, port: { number: 8080 } } }
```

`verify-minikube.sh` patches both hosts live to `cargo-rust.<minikube-ip>.nip.io` and `cargo-go.<minikube-ip>.nip.io`, the same `nip.io` convention every prior minikube chapter uses, and confirms routing with the Ingress's own affinity cookie (`part7-cargo-affinity`) before asserting anything: a response that never went through this Ingress's rules never gets to claim the proof.

The Istio side reuses that same host-not-path choice. `istio/base/gateway.yaml` defines one `Gateway` listener with two hosts, `cargo-rust-istio.<ip>.nip.io` and `cargo-go-istio.<ip>.nip.io`, selecting the same `istio: ingressgateway` workload Chapter 25's own `Gateway` already selects; Istio merges multiple `Gateway` resources on the same workload as long as their hosts do not collide, so this unit's `Gateway` coexists with Chapter 25's without editing either. `istio/base/virtualservice.yaml` routes each host by `authority` match to its own Service:

```yaml
spec:
  hosts:
    - cargo-rust-istio.part7-final-project.example
    - cargo-go-istio.part7-final-project.example
  gateways: [cargo-final-gateway]
  http:
    - match: [{ authority: { exact: cargo-rust-istio.part7-final-project.example } }]
      route: [{ destination: { host: cargo-rust.part7-final-project.svc.cluster.local, port: { number: 8080 } } }]
    - match: [{ authority: { exact: cargo-go-istio.part7-final-project.example } }]
      route: [{ destination: { host: cargo-go.part7-final-project.svc.cluster.local, port: { number: 8080 } } }]
```

`istio/gateway-wasmplugin.yaml` is the Chapter 25 proxy-wasm filter, byte-identical in every field that matters: same `metadata.name` (`cargo-wasmfilter`), same namespace (`istio-system`), same `selector.matchLabels: istio: ingressgateway`, same OCI reference, same `phase: AUTHZ`. It is copied into this unit's directory rather than referenced across directories so `examples/part7-final-project` is self-contained, but applying it here does not create a second filter: it is the same `metadata.name` in the same namespace, so whichever unit's verify script runs last simply re-confirms the one live `WasmPlugin` object. Because the filter loads into the gateway's own Envoy rather than a sidecar on either app Pod, it gates every request that reaches that gateway: Chapter 25's original path and this chapter's `cargo-rust`/`cargo-go` paths alike, with the identical contract: 403 without `x-cargo-tenant`, 200 plus `x-cargo-filtered-by: cargo-wasmfilter` with it. Neither `cargo-rust` nor `cargo-go` carries an Istio injection label or a sidecar; a `runtimeClassName: wasmtime` Pod runs one container runtime for every container it holds, so both composites stay pure Wasm Pods, exactly as Chapter 25 established for the single-language case.

{% include excalidraw.html file="28-final-project-request-path" alt="A client resolves either cargo-rust or cargo-go nip.io hosts through the minikube Ingress, or resolves the istio-labeled hosts through the Istio ingress gateway's NodePort. At the Istio gateway, the proxy-wasm cargo-wasmfilter runs first, authorizing on x-cargo-tenant: missing returns 403, present continues and gets x-cargo-filtered-by stamped on the response. Past either edge, two Pods sit side by side under RuntimeClass wasmtime, hosted by containerd-shim-wasmtime: cargo-rust (http-rust plugged with the Rust cargo provider) and cargo-go (http-go/TinyGo plugged with the Go cargo provider), both exporting wasi:http/incoming-handler and both returning the identical cargo JSON. A lower band shows each Pod's shim emitting an OTel span per invocation into the shared otel-lgtm sink (Tempo), labeled with a scope note: both shims report the same node-level service.name, so the signal is shim-OTel liveness under the workload, not a per-language label." caption="Figure 28.1: the assembled final-project request path on minikube: two edges (ingress-nginx, Istio gateway with the Ch25 filter), two language Pods on the shim, one shared OTel pipeline." %}

`verify-minikube.sh` proves both edges in one run. Through ingress-nginx, both hosts return the exact cargo JSON and 404 on an unknown id, and the two bodies are asserted byte-identical to each other, not merely each matching the expected string separately:

```bash
assert_eq "$EXPECTED_JSON" "$rust_body" "minikube GET $CARGO_PATH through ingress (cargo-rust)"
assert_eq "$EXPECTED_JSON" "$go_body" "minikube GET $CARGO_PATH through ingress (cargo-go)"
assert_eq "$rust_body" "$go_body" "cargo-rust and cargo-go responses are byte-identical"
```

Through the Istio gateway, the script repeats the Chapter 25 contract for each host in turn: a request with no `x-cargo-tenant` header gets 403, a request with `x-cargo-tenant: acme` gets 200, the exact JSON, and an `x-cargo-filtered-by: cargo-wasmfilter` response header: proof the one shared filter actually ran ahead of whichever backend the `Host` header selected.

Chapter 23's KEDA scale-to-zero pass is a deliberate non-addition here. Both the HTTP add-on's scaler and the Istio gateway in this chapter want to own the same ingress role, and stacking them was never this book's design; this final project cross-references Chapter 23 as the serverless alternative to the always-on Deployments it runs, not a layer composed on top of them.

## Observability: one pipeline, a bounded trace scope

The shim's OTel export is the same mechanism Chapter 24 wired up, pointed at the same shared `otel-lgtm` sink, with no new configuration for a second language. `enable-shim-otel.sh` sets `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME` as a systemd `Environment=` on the `containerd.service` unit itself (a node-level setting, not a per-Pod one), which every shim process the node spawns afterward inherits identically as a child of that one containerd process. That mechanism carries a direct consequence for two languages sharing one node: `cargo-rust`'s shim and `cargo-go`'s shim report the same `resource.service.name`, `containerd-shim-wasmtime`. Tempo cannot be asked to show only `cargo-go`'s traces by service name, because nothing in the pinned shim version attaches a `k8s.pod.name` or an image-name attribute to a span that would let one be told apart from the other that way: the shim's OTel integration predates and is unaware of Kubernetes metadata, the same gap Chapter 24 names for the single-language case.

What the pipeline proves instead is liveness. `verify-minikube.sh` drives traffic to both languages, queries Tempo's `/api/search` for the shared shim service name, and asserts at least one trace is present; the shim's OTel export is carrying spans under the assembled workload:

```bash
for i in 1 2 3; do
  curl_body "http://$RUST_HOST$CARGO_PATH" >/dev/null
  curl_body "http://$GO_HOST$CARGO_PATH" >/dev/null
done
sleep 10
shim_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
# shim_count must be > 0 — shim-OTel traces present after the workload
```

The count is read with a plain `kubectl exec` into the `otel-lgtm` Pod's own network namespace: no port-forward, no Grafana UI. A per-language count is not a reliable signal here: the shim service name is node-level, so both languages' spans land under one service, and Tempo's search caps its result set, so one language's traffic alone can saturate the count. What this scope does not produce, and what this chapter does not claim, is a per-language label or a single stitched trace that follows one request's domain logic from the Istio filter through either guest component's internal call graph: the shim's span describes a Pod's invocation lifecycle at the container boundary, not anything the `patterncatalyst:cargo` component itself executed, the same substrate-versus-guest line Chapter 24 drew for one language and this chapter now draws for two.

## CRC: the reduced pass

minikube runs the full assembly: both composites, the Chapter 25 filter, the shim's trace. CRC runs a reduced pass: both composites deployed by the wasmCloud operator, the same Part 5 / Chapter 19 CRC tier, behind two httpserver providers and two edge-TLS Routes. There is no service mesh on this cluster, and no trace capture: the containerd shim needs a privileged, node-level install that `restricted-v2` forbids outright, so the mesh and the shim-trace pass both stay minikube-only for this project. That split is a substrate boundary, not a gap in this chapter: Chapter 19 already established that `restricted-v2` keeps the shim off CRC entirely, for every chapter that has touched CRC since.

`wadm-final.yaml` wires two OAM `Application`s (`cargo-final-rust` and `cargo-final-go`), each a single component plus its own httpserver provider on `0.0.0.0:8000`, the Chapter 20 coexisting-apps shape:

```yaml
# Application: cargo-final-rust (cargo-final-go mirrors it with the Go composite)
components:
  - name: cargo-rust
    type: component
    properties: { image: __RUST_REF__ }
    traits: [{ type: daemonscaler, properties: { replicas: 1 } }]
  - name: httpserver-rust
    type: capability
    properties: { image: ghcr.io/wasmcloud/http-server:0.27.0 }
    traits:
      - type: link
        properties:
          target: cargo-rust
          namespace: wasi
          package: http
          interfaces: [incoming-handler]
          source_config: [{ name: cargo-rust-listen, properties: { address: "0.0.0.0:8000" } }]
      - type: daemonscaler
        properties: { replicas: 1 }
```

The wasmCloud operator creates one Kubernetes Service for httpserver providers scaled with a `daemonscaler`, named after the Application: two Applications yield two Services, `cargo-final-rust` and `cargo-final-go`, each exposing its provider's listen port. One Application per language is the shape Chapter 19 and Chapter 20 already proved: one httpserver provider, one Service, one listen address linked to one component. Each Service is fronted by its own edge-TLS Route:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cargo-final-rust
spec:
  to: { kind: Service, name: cargo-final-rust }
  port: { targetPort: 8000 }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cargo-final-go
spec:
  to: { kind: Service, name: cargo-final-go }
  port: { targetPort: 8001 }
  tls: { termination: edge, insecureEdgeTerminationPolicy: Redirect }
```

`verify-crc.sh` proves both Routes with a CA-verified `curl` (never `-k`, never a port-forward, never a NodePort) against the combined system-plus-ingress CA bundle every CRC chapter in this book builds the same way:

```bash
CA="$(combined_ca_bundle)"
rust_body="$(curl -sS --max-time 15 --cacert "$CA" "https://$RUST_HOST$VALID_PATH")"
go_body="$(curl -sS --max-time 15 --cacert "$CA" "https://$GO_HOST$VALID_PATH")"
[[ "$rust_body" == "$EXPECTED_JSON" ]] || fail "cargo-rust JSON mismatch"
[[ "$go_body" == "$EXPECTED_JSON" ]] || fail "cargo-go JSON mismatch"
[[ "$rust_body" == "$go_body" ]] || fail "cargo-rust and cargo-go responses differ (expected byte-identical)"
```

Everything runs in a `wasmcloud-final` project, an ordinary namespace governed by `restricted-v2`: the `WasmCloudHostConfig` CRD has no `securityContext` field, the operator leaves the host and leaf containers' security context unset, and `restricted-v2` assigns namespace-range UIDs, drops all capabilities, forbids privilege escalation, and defaults seccomp to `RuntimeDefault` on its own; `values-crc.yaml` drops wadm's hard-coded `runAsUser`/`runAsGroup: 1000` for the same reason. No `anyuid` exception is requested anywhere on this cluster, the same posture Chapter 19 established and every CRC chapter since has held to.

## Build, run, observe

```bash
cd examples/part7-final-project && ./build.sh && ./verify-minikube.sh
```

`build.sh` assembles `cargo-rust.wasm` and `cargo-go.wasm`, asserting each exports `wasi:http/incoming-handler` with no stray `patterncatalyst:*` import, then smoke-tests both under `wasmtime serve` before packaging either as an OCI image. `verify-minikube.sh` deploys both composites on the shared `part5` minikube profile under `runtimeClassName: wasmtime`, fronts them with the Chapter 25 Istio proxy-wasm filter, and wires the shim's OTel export into the shared `otel-lgtm` sink, then checks three things through the live cluster: both languages answer byte-identical cargo JSON (and a 404 for an unknown id) through ingress-nginx; the shared `x-cargo-tenant` filter contract (403 without the header, 200 plus `x-cargo-filtered-by` with it) holds through the Istio gateway for both backends; and the shim has exported at least one trace per service into Tempo, read with no port-forward. Expect `PASS` once all three hold. `openshift/verify-crc.sh` runs the CRC counterpart: both composites deployed by the wasmCloud operator as two OAM Applications, each behind its own edge-TLS Route, checked with a CA-verified `curl` for the same byte-identical JSON and 404, with no mesh and no shim trace on that path (the containerd shim's node-level install is unavailable under `restricted-v2`). `capture-evidence.sh` and `openshift/capture-evidence.sh` write the `evidence/<date>/` files for each path; `README.md` documents the full setup sequence for both clusters.

## Decision: what this final project actually proves

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>The two-language-one-contract thesis is proved by assembly, not by argument: <code>contracts/wit</code> is read by two independent build pipelines and never written by either, and both outputs answer the identical JSON string through two different edges on two different clusters. Treat the mesh-layer filter as proof that a cross-cutting policy, written once against <code>proxy-wasm</code> and loaded once into the shared gateway's Envoy, needs no per-backend duplication to cover a second language: the filter never inspects which composite it is in front of, only the request. Treat the shim's OTel signal as proof of liveness, and nothing stronger: traces present for the shim service under the assembled workload, not a per-language label and not a stitched trace through either guest's domain logic, because <code>OTEL_SERVICE_NAME</code> is set once per node, not once per Pod. Treat the minikube/CRC split as a substrate boundary rather than an inconsistency: minikube proves the full assembly, including the shim and the mesh filter, because both depend on node-level capabilities <code>restricted-v2</code> withholds from CRC; CRC proves the same application-layer contract, the same byte-identical JSON across two languages, through a different, equally real deploy path (the wasmCloud operator and two edge-TLS Routes) with no mesh and no shim trace, by design, not by omission. Every claim this final project makes was already true of one language in some earlier chapter; what this final project adds is both languages making the claim simultaneously, against the same edge.</p></div>

## For deeper coverage

- Chapter 5, "The Shared Cargo Domain as Components" and Chapter 8, "Composing Components and WIT Worlds": the `contracts/wit` world and the `wac plug` composition technique this chapter's `build.sh` reuses verbatim on both languages.
- Chapter 14, "wasmtime" and Chapter 16, "wasmtime and wasmCloud Together": the sha256 `eff7f5ee…` provenance of `cargo-rust.wasm`, confirmed byte-identical across every runtime this book has run it under.
- Chapter 18, "Deploying on minikube" and Chapter 19, "Deploying on OpenShift Local (CRC)": the containerd shim, the `runtimeClassName: wasmtime` Deployment shape, and the `restricted-v2` posture this chapter's `k8s/base` and `openshift/` directories both build on without modification.
- Chapter 23, "Serverless Wasm: Scale-to-Zero with KEDA": the serverless alternative to this chapter's always-on Deployments, cross-referenced rather than stacked, because the HTTP add-on and the Istio gateway both want to own ingress.
- Chapter 24, "Observability On-Cluster": the node-level `OTEL_SERVICE_NAME` mechanism and the substrate-versus-guest telemetry boundary this chapter's shim-OTel liveness signal depends on for two languages instead of one.
- Chapter 25, "Istio and WebAssembly": the proxy-wasm `WasmPlugin`, unchanged, that this chapter confirms gates two backends as readily as it gates one.
- [`wac` (WebAssembly Composition tool)](https://github.com/bytecodealliance/wac): the composition tool `build.sh` calls twice, once per language, to produce `cargo-rust.wasm` and `cargo-go.wasm` from their respective provider and front-door halves.

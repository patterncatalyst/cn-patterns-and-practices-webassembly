---
title: "Istio and WebAssembly"
order: 25
part: "Deviations"
description: "Extend Istio's proxy with a Wasm filter via Proxy-Wasm and the Istio WasmPlugin CRD, without rebuilding Envoy."
duration: "21 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why a `WasmPlugin`'s filter module is a **proxy-wasm core module**, a different Wasm ABI from every Component Model artifact this book has built so far, and name the three concrete differences: no WIT world, no `wit-bindgen` output, and a different host (Envoy's proxy-wasm VM, not `containerd-shim-wasmtime` or the wasmCloud host).
- Read `examples/part6-deviations/istio-wasmfilter/src/lib.rs` and `Cargo.toml` and point to the exact lines that make this crate a proxy-wasm module rather than a component: the `proxy_wasm::main!` macro, the `RootContext`/`HttpContext` trait pair, and the absence of `[package.metadata.component]`.
- Trace a request through Figure 25.2's distribution and request path: how a `WasmPlugin` names an OCI reference, how istiod pushes that module's config to the matching Envoy (the ingress gateway's own, not a sidecar), and where the `x-cargo-tenant` check runs relative to the cargo-http Pod.
- State the design constraint that places the filter at the gateway rather than beside the app: a `runtimeClassName: wasmtime` Pod runs one container runtime for every container it carries, so an injected Istio sidecar cannot share that Pod with the Wasm app, on minikube or CRC.
- Decide, for a given cross-cutting concern, whether a `WasmPlugin`/proxy-wasm filter at the mesh layer or a Component Model interposer (Chapter 20) at the application layer is the right placement, and name the newer API, `TrafficExtension`, that supersedes `WasmPlugin` for new filter wiring going forward.

## Why this matters

Every chapter from Part 2 through Part 5 has built, composed, and deployed one kind of Wasm artifact: a Component Model component, compiled with `cargo-component` against a WIT world drawn from `contracts/wit`, hosted either by `containerd-shim-wasmtime` on minikube or by the wasmCloud operator on CRC. Istio runs Wasm too, but a different kind entirely. A `WasmPlugin` resource loads a **proxy-wasm core module** into Envoy, built with a different crate, a different macro, a different toolchain invocation, and a different host than anything this book has touched so far. The filter has no WIT world. It has no `bindings.rs`. It never imports or exports a `patterncatalyst:cargo` interface, and it never touches `contracts/wit` at all.

That contrast is this chapter's teaching point. `examples/part6-deviations/istio-wasmfilter` is built with `cargo build --release --target wasm32-wasip1`, plain cargo, no `cargo-component` anywhere in the build script. Its `Cargo.toml` depends on the `proxy-wasm` crate at version `0.2.5` and declares `crate-type = ["cdylib"]`, with no `[package.metadata.component]` section, because there is no component here to describe. The crate's own header comment names the comparison directly: it solves the same "inspect, allow, or deny a request" problem as Chapter 20's `sidecar-filter`, but as a core-module Envoy extension instead of a WIT component composed with `wac`. Lay the two crates side by side and the differences are the lesson:

| | `part5-kubernetes/sidecar-filter` (Ch. 20) | `part6-deviations/istio-wasmfilter` (this chapter) |
|---|---|---|
| ABI | Component Model (WIT) | proxy-wasm (Envoy) |
| Crate deps | `wit-bindgen-rt` | `proxy-wasm` |
| Build | `cargo component build` | `cargo build --target wasm32-wasip1` |
| Generated code | `src/bindings.rs` from WIT | none: the crate's traits *are* the ABI |
| Host | containerd `wasmtime` shim (runwasi) | Envoy's proxy-wasm VM |
| Composition | `wac plug` into `app.wasm` | none: loaded directly by Envoy |

The filter runs in the Istio ingress gateway's own Envoy, not in a sidecar on the `cargo-http` Pod. A Pod carrying `runtimeClassName: wasmtime` runs one container runtime for every container it holds, so an injected Envoy sidecar would inherit that same RuntimeClass and cannot run beside the Wasm app; the `WasmPlugin` instead targets the gateway's Pod, an ordinary Envoy with no RuntimeClass at all. `cargo-http` stays exactly the Part 5 pure-Wasm Pod it has always been — no sidecar, no injection label, no change to its Deployment, Service, or RuntimeClass. Figure 25.1 draws the result: two Wasm worlds, in two Pods, across the mesh.

{% include excalidraw.html file="25-two-wasm-worlds-in-the-mesh" alt="Two Pod boundaries side by side. Left: Pod istio-ingress-gateway, an ordinary Envoy with no RuntimeClass, running the proxy-wasm filter cargo-wasmfilter, loaded by the gateway's WasmPlugin CR, core-module ABI via the proxy-wasm crate; it checks x-cargo-tenant, returning 403 if missing, and injects x-cargo-filtered-by on the way out. Right: Pod cargo-http, runtimeClassName wasmtime, no sidecar, running the unchanged Part 5 Component Model app with the wasi:http ABI, hosted by containerd-shim-wasmtime. A client request arrow enters the gateway Pod first, then crosses to the cargo-http Pod. A bottom ink band states: a runtimeClassName: wasmtime Pod runs one container runtime, so the mesh filter runs in the gateway's Envoy, not a sidecar; two Wasm ABIs, proxy-wasm core module and Component Model, now split across two Pods instead of sharing one." caption="Figure 25.1 — two Wasm worlds across the mesh: the ingress gateway's proxy-wasm filter and the cargo-http Pod's unmodified Component Model app, in separate Pods with no shared RuntimeClass." %}

Both halves of this chapter verify the same 403/200 behavior through the gateway's filter. The minikube path is **verified live, 2026-10-22**, against a running cluster; evidence is committed under `examples/part6-deviations/istio/evidence/2026-10-22/`. The CRC path is **pending live verification**: its manifests and scripts are transcribed from the example tree, and the verify script is written to run headless against an already-running Part 5 OpenShift deployment, but it has not yet been run against a live cluster.

## The filter: a minimal proxy-wasm HTTP filter

`examples/part6-deviations/istio-wasmfilter/src/lib.rs` implements one small, deterministic policy, small enough that a single `curl` proves it ran. On the request path, a missing `x-cargo-tenant` header gets a local 403 with a JSON body; a request that carries the header continues down the Envoy filter chain unchanged. On the response path, every request that reached this point gets an `x-cargo-filtered-by: cargo-wasmfilter` header stamped onto the outgoing response, so an allowed response is provably different from one the filter never saw:

{% raw %}
```rust
use proxy_wasm::traits::{Context, HttpContext, RootContext};
use proxy_wasm::types::{Action, ContextType, LogLevel};

const TENANT_HEADER: &str = "x-cargo-tenant";
const FILTERED_BY_HEADER: &str = "x-cargo-filtered-by";
const FILTER_NAME: &str = "cargo-wasmfilter";
const DENY_BODY: &str = r#"{"error":"x-cargo-tenant header required"}"#;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_root_context(|_context_id| -> Box<dyn RootContext> {
        Box::new(CargoFilterRoot)
    });
}}

/// Root context: one per Envoy worker thread / VM. Its only job is to hand
/// out a fresh `CargoFilter` for each HTTP stream the proxy opens.
struct CargoFilterRoot;

impl Context for CargoFilterRoot {}

impl RootContext for CargoFilterRoot {
    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }

    fn create_http_context(&self, _context_id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(CargoFilter))
    }
}

/// One instance per HTTP stream. proxy-wasm calls these methods as Envoy's
/// filter chain reaches the corresponding phase for this stream.
struct CargoFilter;

impl Context for CargoFilter {}

impl HttpContext for CargoFilter {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        match self.get_http_request_header(TENANT_HEADER) {
            Some(tenant) => {
                proxy_wasm::hostcalls::log(
                    LogLevel::Info,
                    &format!("{FILTER_NAME}: allowing request for tenant '{tenant}'"),
                )
                .ok();
                Action::Continue
            }
            None => {
                proxy_wasm::hostcalls::log(
                    LogLevel::Warn,
                    &format!("{FILTER_NAME}: denying request missing '{TENANT_HEADER}'"),
                )
                .ok();
                self.send_http_response(
                    403,
                    vec![("content-type", "application/json")],
                    Some(DENY_BODY.as_bytes()),
                );
                Action::Pause
            }
        }
    }

    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        self.set_http_response_header(FILTERED_BY_HEADER, Some(FILTER_NAME));
        Action::Continue
    }
}
```
{% endraw %}

Two trait objects carry the entire ABI surface. `RootContext` is instantiated once per Envoy worker thread (or VM, depending on Envoy's configured concurrency), and its only job here is `create_http_context`, handing out a fresh `CargoFilter` for every HTTP stream the proxy opens. `HttpContext` is the per-stream instance proxy-wasm calls into as Envoy's own filter chain reaches each corresponding phase: `on_http_request_headers` fires once headers arrive, before the body; `on_http_response_headers` fires on the way back out. There is no `handle` function signature imposed by a WIT world here, because there is no WIT world; the method names and their `Action::Continue` / `Action::Pause` return values are the entire contract the `proxy-wasm` crate defines, matching the `proxy_on_*` host calls Envoy's VM invokes directly. `self.send_http_response` is a hostcall: it short-circuits the filter chain immediately, which is why `Action::Pause` follows it rather than `Action::Continue` — the request never reaches any filter stage after this one, including the application.

`Cargo.toml` makes the toolchain choice explicit in its own header comment, aimed squarely at a reader who might reach for the wrong build:

{% raw %}
```toml
[package]
name = "cargo-wasmfilter"
version = "0.1.0"
edition = "2021"

# NOTE: this crate targets the Envoy proxy-wasm ABI, NOT the Component Model.
# It is built with plain `cargo build --target wasm32-wasip1` (see build.sh) —
# never `cargo-component build`. There is no WIT world, no `wit/` directory,
# and no generated `bindings.rs` here; the `proxy-wasm` crate's `main!` macro
# wires the module's exports directly to the symbols Envoy's proxy-wasm host
# looks for (proxy_on_context_create, proxy_on_request_headers, ...). Compare
# with examples/part5-kubernetes/sidecar-filter, which implements the SAME
# "inspect/allow/deny a request" idea as a Component Model component — the
# contrast between the two crates IS chapter 25's teaching point.
[dependencies]
proxy-wasm = "0.2.5"

[lib]
crate-type = ["cdylib"]

[profile.release]
lto = true
opt-level = "s"
strip = true
```
{% endraw %}

`crate-type = ["cdylib"]` with no `[package.metadata.component]` is the field to notice if you have been reading `Cargo.toml` files throughout this book expecting the latter section: every Component Model crate carries one, because `cargo-component` reads it to know which WIT package and world to bind against. This crate has nothing for that tool to read, because `cargo-component` never touches it. `build.sh` reinforces the same point procedurally rather than just in a comment:

{% raw %}
```bash
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

OUT="$SCRIPT_DIR/target/wasm32-wasip1/release/cargo_wasmfilter.wasm"

echo "build.sh: building the proxy-wasm HTTP filter (plain cargo, wasm32-wasip1) ..."
cargo build --release --target wasm32-wasip1

if [[ ! -s "$OUT" ]]; then
  echo "build.sh: FAIL — $OUT not produced" >&2
  exit 1
fi

if command -v wasm-tools >/dev/null 2>&1; then
  echo "build.sh: validating as a core wasm module (NOT a component) ..."
  wasm-tools validate "$OUT"
fi
```
{% endraw %}

The crate name `cargo-wasmfilter` normalizes its dash to an underscore in the compiled artifact, `cargo_wasmfilter.wasm`, an ordinary cargo convention that is easy to trip over if you go looking for the output under the crate's own name. The README's own verification steps lean on the same distinction `build.sh` validates: `wasm-tools validate` accepts the output as a plain core wasm module, and `wasm-tools component wit` is *expected to fail* against it, because the artifact carries no component-type custom sections for that tool to read. A build that fails `wasm-tools component wit` here is not broken; it is proof the toolchain boundary held.

## Packaging and the WasmPlugin resource

A `WasmPlugin`'s `spec.url` field with an `oci://` scheme is the entire distribution contract: Istio's fetcher pulls the named OCI reference and reads a `/plugin.wasm` file from its root. The README documents two ways to produce that image, a `docker buildx` build against a one-line `FROM scratch` + `COPY ... /plugin.wasm` Dockerfile (the same minimal-image pattern Part 5's `Dockerfile` already uses for `/app.wasm`, just a different file name because the consumer differs), or `wash push`, which pushes the raw `.wasm` as a generic OCI artifact without a Docker-style layered image. Either path lands the same bytes at `oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio`, the reference both clusters' `WasmPlugin` manifests name.

`examples/part6-deviations/istio/gateway-wasmplugin.yaml` is the minikube `WasmPlugin`. It targets the ingress gateway's own Envoy directly, in `istio-system`, not the app's namespace:

{% raw %}
```yaml
apiVersion: extensions.istio.io/v1alpha1
kind: WasmPlugin
metadata:
  name: cargo-wasmfilter
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  url: oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio
  imagePullSecret: ghcr-pull
  pluginName: cargo-wasmfilter
  phase: AUTHZ
  pluginConfig: {}
```
{% endraw %}

`selector.matchLabels` targets `istio: ingressgateway`, the label the `demo` profile's `istio-ingressgateway` Deployment carries, not any label on `cargo-http`. `imagePullSecret: ghcr-pull` names a `docker-registry` Secret in this same namespace, `istio-system`, because `cargo-wasmfilter` is a private ghcr package and the gateway Envoy's own agent needs credentials to pull it; `istio-install.sh` creates that secret from `gh auth token`. `phase: AUTHZ` places the filter among Istio's authorization-shaped extensions, ordered after Istio's own authentication and authorization filters and before the request is proxied onward, now enforced at the mesh edge in the gateway's own Envoy, before the request ever leaves for the `cargo-http` Pod.

Applying a `WasmPlugin` does not touch Kubernetes' own scheduler or any Deployment object; istiod watches `WasmPlugin` resources directly and pushes an ECDS (Extension Config Discovery Service) update to every Envoy whose Pod matches the selector (here, only the gateway's own Envoy), which fetches the OCI reference and loads the module into its proxy-wasm VM as an HTTP filter. Figure 25.2 draws both halves of that story, the control-plane distribution and the data-plane request path, together.

{% include excalidraw.html file="25-wasmplugin-request-path" alt="Two stacked bands. Top, control plane: an OCI reference oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio feeds a WasmPlugin CR (extensions.istio.io/v1alpha1) scoped to the ingress gateway, which registers with istiod; istiod distributes the filter's config to the matching gateway Envoy via a dashed distributes-config arrow. Bottom, data plane: a client request crosses the Istio ingress gateway, where the proxy-wasm filter runs, labeled x-cargo-tenant present? else 403, inject x-cargo-filtered-by on egress; a missing-header path breaks off to a 403 box, while a present-header path continues across the mesh to the cargo-http Pod's Component Model app (wasi:http). A bottom ink band states: TrafficExtension is the newer unified API and supersedes WasmPlugin for new filter config; WasmPlugin remains supported, existing filters keep working." caption="Figure 25.2 — WasmPlugin distribution to the ingress gateway's Envoy (control plane), and the request path from there, across the mesh, to the cargo-http Pod (data plane)." %}

A request enters through Istio's ingress gateway, which Chapter 25's `base/gateway.yaml` and `base/virtualservice.yaml` stand up as a second entry point alongside Part 5's original `ingress-nginx` Ingress; both coexist, but this chapter's live verification goes through the Istio path specifically, because that is the only path the proxy-wasm filter sits in front of:

{% raw %}
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: cargo-http-gateway
  namespace: part5-kubernetes
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "cargo-istio.part5-kubernetes.example"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: cargo-http
  namespace: part5-kubernetes
spec:
  hosts:
    - "cargo-istio.part5-kubernetes.example"
  gateways:
    - cargo-http-gateway
  http:
    - route:
        - destination:
            host: cargo-http.part5-kubernetes.svc.cluster.local
            port:
              number: 8080
```
{% endraw %}

The `VirtualService` routes to the existing Part 5 `cargo-http` Service on port 8080 — no new Service, no change to the app's own Deployment. The proxy-wasm filter runs in the gateway's own Envoy before the request ever leaves for the `cargo-http` Pod: `on_http_request_headers` either stops the chain with a 403 or lets the request continue across the mesh, and `on_http_response_headers` stamps the response on the way back out.

## minikube: Istio layered onto the existing profile

`examples/part6-deviations/istio/istio-install.sh` installs Istio 1.31.2 with `istioctl install`, pinned by `--set tag=1.31.2` against the `demo` profile, not `minimal`, because `base/gateway.yaml` and `base/virtualservice.yaml` need `istio-ingressgateway`, which the `minimal` profile omits. The script runs `istioctl x precheck` as a gate before installing anything: Istio 1.31 officially supports Kubernetes 1.32 through 1.36, and Part 5 pins minikube's control plane to `v1.37.1`, one minor past that documented ceiling. If `precheck` reports a blocker, the fix is to re-create the minikube profile with `KUBERNETES_VERSION` re-pinned into the supported window before retrying, not to proceed past a failed gate:

{% raw %}
```bash
step "1. istioctl x precheck (the Istio<->Kubernetes skew gate, see header note)"
istioctl x precheck --context "$PROFILE" \
  || { echo "istio-install.sh: FAIL — precheck reported a blocker; re-pin minikube's Kubernetes version into Istio 1.31's supported 1.32-1.36 window and retry (see header note)" >&2; exit 1; }
```
{% endraw %}

Once the control plane is up, the script creates the `ghcr-pull` image-pull secret in `istio-system` and patches `istio-ingressgateway`'s Service to `NodePort`: the `demo` profile's default `LoadBalancer` type stays `<pending>` on minikube's docker driver without a separate `minikube tunnel`, and this book's house rule rules out both a tunnel and a port-forward. No namespace gets an injection label, and no app Deployment gets rolled; `cargo-http` stays a pure Wasm Pod throughout.

`verify-istio-minikube.sh` applies the ch25 overlay (the unmodified Part 5 app plus `Gateway` and `VirtualService`), then applies `gateway-wasmplugin.yaml` directly into `istio-system` and rolls the ingress gateway, not the app:

{% raw %}
```bash
step "1/6 Apply the ch25 app-side overlay (Gateway + VirtualService; NO WasmPlugin, NO injection label)"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"
echo "verify-istio-minikube.sh: expect READY 1/1 below (pure Wasm app Pod, NO istio-proxy sidecar)"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=cargo-http \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready'

step "2/6 ghcr-pull secret in istio-system + apply the gateway-side WasmPlugin"
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=patterncatalyst \
  --docker-password="$(gh auth token)" \
  -n istio-system \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$SCRIPT_DIR/gateway-wasmplugin.yaml"
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s
```
{% endraw %}

The script resolves the ingress gateway's live NodePort and the minikube VM's IP, patches the `Gateway` and `VirtualService` hosts to a `nip.io`-style hostname built from that IP, same convention as every other Part 5 Ingress host in this book, and then asserts both halves of the filter's behavior through the real network path, never a port-forward: a request without `x-cargo-tenant` must return 403, and a request with `x-cargo-tenant: acme` must return 200, the exact cargo JSON, and the `x-cargo-filtered-by: cargo-wasmfilter` response header. **Verified live, 2026-10-22**, against minikube IP `192.168.49.2`, ingress gateway NodePort `30920`:

{% raw %}
```
$ curl -s -o /dev/null -w '%{http_code}\n' -H "Host: cargo-istio.192.168.49.2.nip.io" \
  http://192.168.49.2:30920/cargo/CARGO-USNYC-DEHAM
403
```
{% endraw %}

{% raw %}
```
$ curl -sS -D - -H "Host: cargo-istio.192.168.49.2.nip.io" -H 'x-cargo-tenant: acme' \
  http://192.168.49.2:30920/cargo/CARGO-USNYC-DEHAM
HTTP/1.1 200 OK
x-cargo-filtered-by: cargo-wasmfilter
...
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
```
{% endraw %}

A 403 on the first request proves the gateway's filter runs and enforces its policy; a 200 with the stamped header on the second proves the same `cargo-http` Pod's Component Model app, under `containerd-shim-wasmtime`, answers normally once the filter lets a request through — the two Wasm worlds Figure 25.1 draws, split across the mesh instead of sharing a Pod, each doing its own job on the same request. Full evidence, including the gateway's own log line fetching the filter image from ghcr, is committed under `examples/part6-deviations/istio/evidence/2026-10-22/`.

## CRC: OpenShift Service Mesh 3, the same gateway design

CRC does not run community Istio directly; it runs **OpenShift Service Mesh 3**, the Sail operator's distribution of Istio 1.31.2, installed by `install-ossm.sh` through the same OperatorHub pattern this book uses everywhere else on CRC: a `Subscription` with `installPlanApproval: Manual`, a pinned `startingCSV`, and an explicit approval of only the one named `InstallPlan`:

{% raw %}
```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: $OSSM_NAMESPACE
spec:
  channel: $OSSM_CHANNEL
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  startingCSV: $OSSM_STARTING_CSV
```
{% endraw %}

Once the operator is installed, the control plane itself is a pair of Sail `sailoperator.io/v1` custom resources, not a Helm chart or an `istioctl install` invocation:

{% raw %}
```yaml
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: $ISTIO_VERSION
  namespace: $ISTIO_CNI_NS
---
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: $ISTIO_VERSION
  namespace: $ISTIO_NS
```
{% endraw %}

The script's own header comment flags one item as unconfirmed against a live cluster at the time of this authoring pass: the exact `startingCSV` string for `servicemeshoperator3` on the `stable` channel, which needs a live `oc get packagemanifest servicemeshoperator3 -n openshift-marketplace` check before the real run; `OSSM_STARTING_CSV` defaults to `servicemeshoperator3.v3.1.0` pending that confirmation.

CRC shares minikube's design: the filter runs in the gateway's Envoy, never beside the app. `install-ossm.sh` never labels the `wasmcloud` namespace for injection and never restarts `deploy/$HOSTCFG`, the operator-managed wasmCloud host Deployment. `openshift/wasmplugin.yaml` carries the same spec as minikube's `gateway-wasmplugin.yaml` (same OCI reference, same `phase: AUTHZ`, same `istio: ingressgateway` selector), now in OSSM3's `istio-system`. CRC's app Pod is an ordinary container the wasmCloud operator manages, not a RuntimeClass-scoped Wasm Pod, so a co-located sidecar there would not hit the same constraint directly; the manifest still targets the gateway, keeping one design across both cluster paths so both verify scripts assert the identical 403/200 behavior through the same code path.

The Route, Gateway, and VirtualService follow the same edge-TLS pattern every CRC chapter in this book uses:

{% raw %}
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cargo-http-istio
  namespace: istio-system
spec:
  to:
    kind: Service
    name: istio-ingressgateway
  port:
    targetPort: http2
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```
{% endraw %}

The router terminates TLS at the edge and forwards plain HTTP to the gateway's `http2` port, the same split Part 5's own CRC Route already uses in front of the wasmCloud operator's Service; the `VirtualService` routes that plain-HTTP request on to the existing `cargo-http` Service in the `wasmcloud` namespace, port 8000, no new Service created. `verify-istio-crc.sh` applies the four manifests (idempotent `oc apply`), resolves the Route's assigned host and patches `Gateway`/`VirtualService` to match, waits on the ingress gateway's own rollout, and runs the identical two-request proof minikube's script runs, through a CA-verified `https://` request against the real edge-TLS Route, never `-k`, never a port-forward. **Pending live verification**:

<!-- LIVE-OUTPUT ch25 CRC istio: fill from examples/part6-deviations/istio/evidence/<date>/03-no-tenant-403.txt after the gated run --> *(verified-live output lands here after the cluster run: the WITHOUT-`x-cargo-tenant` request returning HTTP 403 through the edge-TLS Route, CA-verified.)*

<!-- LIVE-OUTPUT ch25 CRC istio: fill from examples/part6-deviations/istio/evidence/<date>/04-with-tenant-200.txt after the gated run --> *(verified-live output lands here after the cluster run: the WITH-`x-cargo-tenant: acme` request returning HTTP 200, the exact cargo JSON, and a response header `x-cargo-filtered-by: cargo-wasmfilter`.)*

The filter's behavior is identical on both clusters: a missing header denies at the gateway before the request ever reaches the app Pod, and a present header lets the request through, stamped with proof the filter ran. What differs between the two runs is the control plane (community Istio vs. OSSM3/Sail) and the app's own host underneath the filter (`containerd-shim-wasmtime` on minikube, the wasmCloud operator on CRC), not where the filter executes, which is the ingress gateway's Envoy on both paths.

## Decision: mesh-layer filter, Component Model interposer, or TrafficExtension

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for a <code>WasmPlugin</code>/proxy-wasm filter when the concern is mesh-layer, language-agnostic, and about traffic policy that applies uniformly across every workload the gateway fronts: tenant-header enforcement, rate limiting, request/response header injection, or any cross-cutting rule that should not require every application team to rebuild their own Wasm component to get it. The filter runs ahead of the application entirely, in Envoy's own process, built from any language proxy-wasm supports, and deployed by applying one CRD — istiod pushes the config live, no redeploy of the app workload required. Reach for a Component Model interposer, the shape Chapter 20 built, when the concern is app-layer and needs to operate on typed domain values, <code>Booking</code>, <code>RouteSpec</code>, <code>CargoError</code>, rather than raw HTTP headers and bytes: a policy that has to reason about the shape of a booking request, not just whether a header is present, belongs inside the component graph where WIT has already validated that shape, not in a filter that only ever sees an HTTP request before any domain logic runs. Between the two there is no overlap to resolve by taste: a proxy-wasm filter cannot see a <code>Booking</code> record, and a Component Model interposer has no hook into Envoy's listener chain at all. Looking forward, <code>TrafficExtension</code> (<code>istio.io</code>, 1.30+) is the newer unified API for wiring Wasm and native extensions into the mesh, and istiod transforms an existing <code>WasmPlugin</code> into that model under the hood; <code>WasmPlugin</code> itself stays fully supported, and nothing in this chapter's manifests needs to change today, but new filter wiring going forward should default to <code>TrafficExtension</code> rather than treating <code>WasmPlugin</code> as the only entry point.</p></div>

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model / WASI Preview 2 ABI this chapter's proxy-wasm filter never touches, read here for the full contrast with what a WIT-based component actually requires.
- [Istio: WebAssembly Plugin Extensibility](https://istio.io/latest/docs/concepts/wasm/): the `WasmPlugin` resource, `extensions.istio.io/v1alpha1`, ECDS distribution, and plugin phases (`AUTHN`, `AUTHZ`, `STATS`, and the rest) this chapter's `wasmplugin.yaml` instances draw on.
- [`proxy-wasm-rust-sdk`](https://github.com/proxy-wasm/proxy-wasm-rust-sdk): the `proxy-wasm` crate, `RootContext`/`HttpContext` traits, and the `proxy_wasm::main!` macro `src/lib.rs` is built against.
- [Istio: `TrafficExtension`](https://istio.io/latest/docs/reference/config/networking/traffic-extension/): the newer unified extensibility API named in this chapter's Decision callout as the forward path beyond `WasmPlugin`.
- [Red Hat OpenShift Service Mesh 3 documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh): the Sail operator, its `sailoperator.io/v1` `Istio`/`IstioCNI` CRs, and the `servicemeshoperator3` OperatorHub package `install-ossm.sh` subscribes to.
- Chapter 17, "Wasm on Kubernetes" and Chapter 19, "Deploying on OpenShift Local (CRC)": the containerd shim and the wasmCloud operator this chapter's two Wasm-world contrast builds directly on, including the `restricted-v2` constraint that keeps the shim off CRC entirely.
- Chapter 20, "Wasm as a Sidecar": the Component Model interposer, `sidecar-filter`, this chapter's proxy-wasm filter stays structurally parallel to and contrasts against; the Decision callout above names exactly when to reach for which.
- Chapter 24, "Observability On-Cluster": the same no-port-forward, CA-verified evidence discipline this chapter's two verify scripts apply to a mesh-fronted request instead of a telemetry backend.

---
title: "Istio and WebAssembly"
order: 25
part: "Deviations"
description: "Extend Istio's gateway with a proxy-wasm filter loaded by the WasmPlugin CRD, without rebuilding Envoy, and see why it is a different Wasm ABI from a Component Model component."
duration: "21 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why a `WasmPlugin` loads a proxy-wasm core module, a different ABI from a Component Model component: no WIT world, no `wit-bindgen` output, and Envoy's proxy-wasm VM as host.
- Recognize a proxy-wasm crate by `proxy_wasm::main!`, the `RootContext` and `HttpContext` traits, `crate-type = ["cdylib"]` and the absence of `[package.metadata.component]`.
- Package the module as an OCI image with `/plugin.wasm` at its root and attach it to the ingress gateway with a `WasmPlugin`.
- Say why the filter runs in the gateway's Envoy and not in a sidecar: a `runtimeClassName: wasmtime` Pod runs one container runtime for every container it carries.
- Choose between a mesh-layer filter and a Component Model interposer, and name `TrafficExtension` as the newer API.

## Why this matters

Istio runs Wasm too, but a different kind from the Component Model components built elsewhere. A `WasmPlugin` loads a proxy-wasm core module into Envoy, built with a different crate, macro, toolchain invocation and host. The filter has no WIT world and no `bindings.rs`, and it never touches `contracts/wit`. It's built with plain `cargo build --release --target wasm32-wasip1`, depends on the `proxy-wasm` crate and declares `crate-type = ["cdylib"]`. It solves the same inspect, allow or deny problem as the Wasm-as-a-sidecar `sidecar-filter`, as a core-module Envoy extension instead of a WIT component composed with `wac`:

| | `sidecar-filter` (Component Model) | `istio-wasmfilter` (proxy-wasm) |
|---|---|---|
| ABI | Component Model (WIT) | proxy-wasm (Envoy) |
| Crate deps | `wit-bindgen-rt` | `proxy-wasm` |
| Build | `cargo component build` | `cargo build --target wasm32-wasip1` |
| Generated code | `src/bindings.rs` from WIT | none: the crate's traits are the ABI |
| Host | containerd `wasmtime` shim (runwasi) | Envoy's proxy-wasm VM |
| Composition | `wac plug` into `app.wasm` | none: loaded directly by Envoy |

The filter runs in the Istio ingress gateway's own Envoy, not in a sidecar on the `cargo-http` Pod. A Pod with `runtimeClassName: wasmtime` runs one container runtime for every container it holds, so an injected Envoy sidecar would inherit that RuntimeClass and couldn't run beside the Wasm app. The `WasmPlugin` targets the gateway's Pod, an ordinary Envoy with no RuntimeClass. `cargo-http` stays a pure-Wasm Pod: no sidecar, no injection label, no change to its Deployment, Service or RuntimeClass.

{% include excalidraw.html file="25-two-wasm-worlds-in-the-mesh" alt="Two Pod boundaries side by side. Left: the istio-ingress-gateway Pod, an ordinary Envoy with no RuntimeClass, running the proxy-wasm filter cargo-wasmfilter loaded by a WasmPlugin; it returns 403 when x-cargo-tenant is missing and adds x-cargo-filtered-by on the way out. Right: the cargo-http Pod, runtimeClassName wasmtime, no sidecar, running the unchanged Component Model app with the wasi:http ABI under containerd-shim-wasmtime. A client request enters the gateway Pod first, then crosses to the cargo-http Pod. A bottom band says a runtimeClassName wasmtime Pod runs one container runtime, so the mesh filter runs in the gateway and not in a sidecar." caption="Figure 25.1: Two Wasm worlds across the mesh. The gateway's proxy-wasm filter and the unmodified Component Model app run in separate Pods with no shared RuntimeClass." %}

Both clusters check the same 403 and 200 behavior through the gateway. The minikube path runs upstream Istio 1.31.2 through `istioctl`. The CRC path runs OpenShift Service Mesh 3.1.0 (the Sail operator), which supports Istio only up to v1.26.2 and rejects 1.31.2, so its `Istio` and `IstioCNI` resources pin v1.26.2; the `WasmPlugin` API (`extensions.istio.io/v1alpha1`) is the same on both, so the filter does not change. CRC traffic arrives through an edge-TLS Route. OSSM doesn't provision an ingress gateway, so `openshift/ingress-gateway.yaml` deploys one by gateway injection.

## The filter: a minimal proxy-wasm HTTP filter

The policy is small enough that one `curl` proves it ran. A request without `x-cargo-tenant` gets a local 403 with a JSON body. A request with it continues down the filter chain, and its response gets `x-cargo-filtered-by: cargo-wasmfilter`, so an allowed response is visibly different from one the filter never saw:

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

Two traits carry the whole ABI. `RootContext` is created once per Envoy worker thread or VM and hands out a fresh `CargoFilter` for each HTTP stream. `HttpContext` is the per-stream instance Envoy calls as its filter chain reaches each phase: `on_http_request_headers` once headers arrive, `on_http_response_headers` on the way back. The method names and the `Action::Continue` and `Action::Pause` return values are the contract; they map onto the `proxy_on_*` calls Envoy's VM makes. `send_http_response` is a hostcall that short-circuits the chain, so `Action::Pause` follows it: the request never reaches the application.

### Building it

`Cargo.toml` states the toolchain choice for a reader who might reach for the wrong build:

{% raw %}
```toml
[package]
name = "cargo-wasmfilter"
version = "0.1.0"
edition = "2021"

# NOTE: this crate targets the Envoy proxy-wasm ABI, NOT the Component Model.
# It is built with plain `cargo build --target wasm32-wasip1` (see build.sh),
# never `cargo-component build`. There is no WIT world, no `wit/` directory,
# and no generated `bindings.rs` here; the `proxy-wasm` crate's `main!` macro
# wires the module's exports directly to the symbols Envoy's proxy-wasm host
# looks for (proxy_on_context_create, proxy_on_request_headers, ...). Compare
# with examples/part5-kubernetes/sidecar-filter, which implements the SAME
# "inspect/allow/deny a request" idea as a Component Model component. The
# contrast between the two crates is the point.
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

Every Component Model crate carries `[package.metadata.component]`, because `cargo-component` reads it to find the WIT package and world. This crate has none and is never touched by that tool. `build.sh` is plain cargo:

```bash
echo "build.sh: building the proxy-wasm HTTP filter (plain cargo, wasm32-wasip1) ..."
cargo build --release --target wasm32-wasip1

if [[ ! -s "$OUT" ]]; then
  echo "build.sh: FAIL, $OUT not produced" >&2
  exit 1
fi

if command -v wasm-tools >/dev/null 2>&1; then
  echo "build.sh: validating as a core wasm module (NOT a component) ..."
  wasm-tools validate "$OUT"
fi
```

The output is `target/wasm32-wasip1/release/cargo_wasmfilter.wasm`: cargo normalizes the dash in the crate name to an underscore, which is easy to miss when looking for the artifact by crate name. `wasm-tools validate` accepts it as a plain core module. `wasm-tools component wit` is expected to fail against it because there are no component-type sections to read. That failure shows the toolchain boundary held.

## Packaging and the WasmPlugin resource

A `WasmPlugin` with an `oci://` `spec.url` is the whole distribution contract: Istio's fetcher pulls the OCI reference and reads `/plugin.wasm` from its root. Produce the image with `docker buildx` against a `FROM scratch` Dockerfile that copies the module to `/plugin.wasm` (the same minimal-image shape Part 5 uses for `/app.wasm`), or with `wash push`, which pushes the raw `.wasm` as a generic OCI artifact. Both land the same bytes at `oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio`, the reference both clusters name.

The minikube `WasmPlugin` targets the gateway's Envoy in `istio-system`, not the app's namespace:

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
  # The filter image is a PRIVATE ghcr package, so the gateway Envoy's agent
  # needs registry credentials to fetch it: a docker-registry secret named
  # `ghcr-pull` in THIS namespace (istio-system, where the gateway Pod and
  # this WasmPlugin both live, not the app's namespace). ../istio-install.sh
  # creates it (kubectl create secret docker-registry ghcr-pull
  # --docker-server=ghcr.io --docker-username=<owner> --docker-password=<token>
  # -n istio-system). Make the package public instead and this line can be
  # dropped.
  imagePullSecret: ghcr-pull
  pluginName: cargo-wasmfilter
  phase: AUTHZ
  pluginConfig: {}
```
{% endraw %}

- `selector.matchLabels` picks `istio: ingressgateway`, the label the `demo` profile's gateway Deployment carries. Nothing selects `cargo-http`.
- `imagePullSecret: ghcr-pull` names a `docker-registry` Secret in `istio-system`, because `cargo-wasmfilter` is a private ghcr package and the gateway's agent needs credentials. `istio-install.sh` creates it from `gh auth token`.
- `phase: AUTHZ` orders the filter after Istio's own authentication and authorization filters and before the request is proxied onward, at the mesh edge.

Applying a `WasmPlugin` touches no Deployment and no scheduler. istiod watches the resource and pushes an ECDS (Extension Config Discovery Service) update to every Envoy whose Pod matches the selector, here only the gateway's. That Envoy fetches the OCI reference and loads the module into its proxy-wasm VM as an HTTP filter.

{% include excalidraw.html file="25-wasmplugin-request-path" alt="Two stacked bands. Top, control plane: the OCI reference oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio feeds a WasmPlugin scoped to the ingress gateway, which registers with istiod; istiod distributes the filter config to the matching gateway Envoy. Bottom, data plane: a client request crosses the ingress gateway where the proxy-wasm filter checks x-cargo-tenant; a missing header breaks off to a 403, a present header continues across the mesh to the cargo-http Pod's Component Model app and the filter injects x-cargo-filtered-by on the way out. A bottom band says TrafficExtension is the newer API that supersedes WasmPlugin for new filter config, and WasmPlugin remains supported." caption="Figure 25.2: WasmPlugin distribution to the gateway's Envoy (control plane) and the request path from the gateway to the cargo-http Pod (data plane)." %}

A `Gateway` and a `VirtualService` stand up the Istio entry point as a second path beside Part 5's `ingress-nginx` Ingress. Both coexist, but only the Istio path has the filter in front of it:

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
```
{% endraw %}

{% raw %}
```yaml
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

The `VirtualService` routes to the existing `cargo-http` Service on port 8080: no new Service and no change to the app's Deployment.

## minikube: Istio layered onto the existing profile

`istio-install.sh` runs `istioctl install` pinned to Istio 1.31.2 with the `demo` profile, not `minimal`, because the `Gateway` and `VirtualService` need `istio-ingressgateway`, which `minimal` omits. It runs `istioctl x precheck` first as a gate:

```bash
step "1. istioctl x precheck (the Istio<->Kubernetes skew gate, see header note)"
istioctl x precheck --context "$PROFILE" \
  || { echo "istio-install.sh: FAIL, precheck reported a blocker; re-pin minikube's Kubernetes version into Istio 1.31's supported 1.32-1.36 window and retry (see header note)" >&2; exit 1; }
```

Istio 1.31 supports Kubernetes 1.32 through 1.36, and the Part 5 minikube control plane is v1.37.1, one minor past that ceiling. If precheck reports a blocker, re-create the minikube profile with `KUBERNETES_VERSION` pinned into the supported window; don't proceed past a failed gate.

The script then creates the `ghcr-pull` secret in `istio-system` and patches the `istio-ingressgateway` Service to `NodePort`. The `demo` profile's `LoadBalancer` stays `<pending>` on minikube's docker driver without a `minikube tunnel`, and neither a tunnel nor a port-forward is used. No namespace gets an injection label and no app Deployment is rolled.

`verify-istio-minikube.sh` applies the overlay (the unmodified app plus `Gateway` and `VirtualService`; the app Pod shows `READY 1/1`, no `istio-proxy`), then wires the filter into `istio-system` and rolls the ingress gateway rather than the app:

```bash
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

It patches the hosts to a `nip.io` name built from the minikube IP and sends two requests through the gateway's NodePort (30920 in the recorded run against `192.168.49.2`):

| Request | Result |
| --- | --- |
| no `x-cargo-tenant` header | 403 |
| `x-cargo-tenant: acme` | 200, the cargo JSON, and `x-cargo-filtered-by: cargo-wasmfilter` |

The 403 shows the gateway's filter runs and enforces its policy. The 200 shows the same `cargo-http` component, under `containerd-shim-wasmtime`, answers once the filter lets the request through. The recorded run, including the gateway's own log line fetching the filter image from ghcr, is under `examples/part6-deviations/istio/evidence/2026-10-22/`.

## CRC: OpenShift Service Mesh 3

CRC runs OpenShift Service Mesh 3, the Sail operator's Istio distribution, installed by `install-ossm.sh` with the usual OperatorHub pattern: a `Subscription` with `installPlanApproval: Manual`, a pinned `startingCSV`, and approval of only the one named `InstallPlan`:

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

The control plane is a pair of `sailoperator.io/v1` resources, an `IstioCNI` and an `Istio`, not a Helm chart or `istioctl`. The `Istio` resource:

{% raw %}
```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: $ISTIO_VERSION
  namespace: $ISTIO_NS
```
{% endraw %}

The script's `startingCSV` default, `servicemeshoperator3.v3.1.0`, still needs a live `oc get packagemanifest servicemeshoperator3 -n openshift-marketplace` check before a real run.

The design matches minikube's. `install-ossm.sh` never labels the `wasmcloud` namespace for injection and never restarts the wasmCloud host Deployment. `openshift/wasmplugin.yaml` carries the same spec as `gateway-wasmplugin.yaml`: same OCI reference, same `phase: AUTHZ`, same selector, in OSSM's `istio-system`. The CRC app is an ordinary container managed by the wasmCloud operator, not a RuntimeClass-scoped Pod, so a sidecar there wouldn't hit the same constraint. The manifest still targets the gateway so both verify scripts assert the same behavior through the same path.

The Route follows the edge-TLS pattern the other CRC deployments use:

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

When both the Istio `Gateway` CRD and the Kubernetes Gateway API CRD are installed, `oc patch gateway` resolves to `gateway.networking.k8s.io`; name the resource in full as `gateway.networking.istio.io` (and `virtualservice.networking.istio.io`). The router terminates TLS and forwards plain HTTP to the gateway's `http2` port. The `VirtualService` then routes to the existing `cargo-http` Service in the `wasmcloud` namespace on port 8000. `verify-istio-crc.sh` applies the four manifests, reads the Route's assigned host and patches `Gateway` and `VirtualService` to match, waits for the gateway rollout, and sends the same two requests as minikube through a CA-verified `https://` request, never `-k`, never a port-forward.

The filter behaves identically on both clusters. What differs is the control plane (community Istio or OSSM 3) and the app's host under the filter (`containerd-shim-wasmtime` or the wasmCloud operator), not where the filter executes.

> **Decision**
>
> Use a `WasmPlugin` proxy-wasm filter for mesh-layer, language-agnostic traffic policy that applies to every workload the gateway fronts: tenant-header enforcement, rate limiting, header injection. It runs ahead of the application in Envoy's process, can be built from any language proxy-wasm supports, and deploys by applying one CRD with no app redeploy. Use a Component Model interposer, as in Wasm as a sidecar, when the concern is app-layer and needs typed domain values such as `Booking`, `RouteSpec` and `CargoError`, not HTTP headers and bytes. The two don't overlap: a proxy-wasm filter can't see a `Booking`, and an interposer has no hook into Envoy's listener chain. For new filter wiring, default to `TrafficExtension` (Istio 1.30+), the newer unified API for Wasm and native extensions. istiod transforms an existing `WasmPlugin` into that model, and `WasmPlugin` stays supported.

> **🤖 Explore with your agent**
>
> "In `examples/part6-deviations/istio-wasmfilter/src/lib.rs`, extend `CargoFilter::on_http_request_headers` so a request whose `x-cargo-tenant` value is empty is denied with the same 403 as a missing header. Keep it a proxy-wasm core module: no WIT world, no `cargo-component`, build with `./build.sh`. Then tell me whether this rule belongs in `istio-wasmfilter` or in a Component Model interposer like `sidecar-filter`, using the rule that mesh-layer policy over headers goes in the filter and policy over typed `Booking` values goes in the component."
>
> Check: `./build.sh` succeeds, `wasm-tools validate` accepts `target/wasm32-wasip1/release/cargo_wasmfilter.wasm`, and the reply places an empty-header rule in the filter.

## Build, run, observe

```bash
cd examples/part6-deviations/istio && ./verify-istio-minikube.sh
```

Run `istio-install.sh` first, or `install-ossm.sh` for CRC; `README-istio.md` documents the sequence and the `evidence/<date>/` layout. The minikube script prints `PASS` once the 403 and the 200 with the stamped header both hold. `./verify-istio-crc.sh` runs the same two requests through the edge-TLS Route.

Experiments:

- Send `curl -sS -D - -H "Host: cargo-istio.<minikube-ip>.nip.io" http://<minikube-ip>:<nodeport>/cargo/CARGO-USNYC-DEHAM` with and without `-H 'x-cargo-tenant: acme'`: 403 without, and 200 with the cargo JSON and `x-cargo-filtered-by: cargo-wasmfilter` with it.
- Run `wasm-tools component wit` on `cargo_wasmfilter.wasm` and it fails, because the artifact is a core module.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model and WASI Preview 2 ABI a proxy-wasm filter never touches.
- [Istio: WebAssembly Plugin Extensibility](https://istio.io/latest/docs/concepts/wasm/): the `WasmPlugin` resource, ECDS distribution and the plugin phases (`AUTHN`, `AUTHZ`, `STATS` and the rest).
- [`proxy-wasm-rust-sdk`](https://github.com/proxy-wasm/proxy-wasm-rust-sdk): the `proxy-wasm` crate, the `RootContext` and `HttpContext` traits and the `proxy_wasm::main!` macro.
- [Istio: `TrafficExtension`](https://istio.io/latest/docs/reference/config/networking/traffic-extension/): the newer extensibility API and the forward path beyond `WasmPlugin`.
- [Red Hat OpenShift Service Mesh 3 documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh): the Sail operator, its `Istio` and `IstioCNI` resources and the `servicemeshoperator3` OperatorHub package.
- The containerd shim from Wasm on Kubernetes and the wasmCloud operator from the OpenShift Local (CRC) deployment: the two hosts the gateway's filter fronts, including the `restricted-v2` constraint that keeps the shim off CRC.
- The Wasm-as-a-sidecar `sidecar-filter`: the Component Model interposer this filter parallels and contrasts with.
- The observability-on-cluster no-port-forward, CA-verified evidence discipline, applied here to a mesh-fronted request.

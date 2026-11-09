---
title: "WebAssembly for Other Backend Architectures"
order: 26
part: "Deviations"
description: "Place the containerd shim, the wasmCloud operator, SpinKube and WasmEdge's runwasi shim on one map, then run a Spin app for the cargo domain through SpinKube on minikube and as a plain restricted-v2 container on OpenShift Local."
duration: "15 min read"
---

## Learning objectives

By the end of this chapter you can:

- Place `containerd-shim-wasmtime`, the wasmCloud operator, SpinKube and WasmEdge's runwasi shim on one map by what each schedules, what control plane it carries and what app shape it fits.
- Name the ABI fact that drives every deploy decision for a Spin app: `spin-sdk = "=7.0.0"` exports `wasi:http/handler@0.3.0` (wasip3), not `wasi:http/incoming-handler@0.2.x`.
- Explain why the shipped `spin.toml` has no `[component.cargo-spin.dependencies]` section, and what the generated `spin-build.toml` does instead.
- Trace the minikube path (`SpinApp`, `spin-operator`, `containerd-shim-spin`, `RuntimeClass wasmtime-spin-v2`) against the OpenShift Local path (`spin up` in a plain `restricted-v2` `Deployment`), and state the constraint that forces the split.
- Choose between SpinKube, the wasmCloud operator and the raw containerd shim by what the app is already built against.

## Why this matters

Running a component on Kubernetes through the generic containerd shim leaves SpinKube out: that shim runs components built directly against a WIT contract, with no framework packaging. `examples/part6-deviations/spin` is a Spin HTTP component serving the same cargo domain, composed with the unedited Part 2 Rust provider. `contracts/wit` is untouched; Spin's tooling sits on top of the same interface.

The lesson is what happens when a framework's ABI choice meets a cluster's installed runtime, and when the cluster refuses the node-level install the framework's Kubernetes integration wants. Both happen here. `spin-sdk = "=7.0.0"` exports an ABI only a Spin 4.1+ runtime understands, which pins the shim build minikube needs. `containerd-shim-spin` needs privileged node changes that `restricted-v2` on OpenShift Local does not allow, so that path runs the Spin runtime inside an ordinary container. Both paths serve the same cargo JSON and the same 404.

## The backend landscape: when each fits

Four projects put a Wasm component inside Kubernetes scheduling. They answer different questions, so the choice follows what the app is built against and how much control-plane machinery the team will run.

| Option | What it schedules | Carries | Fits |
|---|---|---|---|
| `containerd-shim-wasmtime` (runwasi) | A Pod with `runtimeClassName: wasmtime` | One shim binary per node, one `RuntimeClass` | Any `wasi:http/proxy` or `wasi:cli/run` component built directly against WIT |
| wasmCloud operator | A wasmCloud host as an ordinary Pod; `wadm` deploys component, provider and link onto that lattice | NATS, a host process and `wadm` as extra workloads; no `RuntimeClass`, no node change | Apps that want swappable capability providers, declarative links and self-healing, or a cluster where the raw shim hits a WASI feature gap |
| SpinKube | A `SpinApp` custom resource that `spin-operator` reconciles into a `Deployment` and `Service` | `containerd-shim-spin` (embeds the Spin runtime), a `RuntimeClass`, the operator | Apps already packaged the Spin way: `spin.toml`, triggers, `spin-sdk`, Spin OCI artifacts |
| WasmEdge and other runwasi shims | A Pod under the shim's `RuntimeClass` | Same node-install mechanics as the raw shim, with a different embedded runtime | Components that need that runtime's host-function extensions, such as image processing or WASI-NN |

The first and fourth rows share one contract: a component schedules like a container. A component built against the plain WASI worlds runs the same under either embedding, so the choice there is about the extension surface, not a different operating model. SpinKube is the sibling easiest to confuse with the raw shim, because `containerd-shim-spin` also registers under a `RuntimeClass`. It embeds the Spin runtime instead of a generic wasmtime, so it only runs applications packaged for Spin.

{% include excalidraw.html file="26-wasm-backend-landscape" alt="A four-row landscape table. Row 1, containerd-shim-wasmtime (runwasi): a generic shim plus RuntimeClass, smallest operational footprint, runs any wasi:http/proxy or wasi:cli component built directly against WIT. Row 2, wasmCloud operator: schedules a wasmCloud host as a Pod, wadm deploys component, provider and link onto that in-cluster lattice, brings NATS, host and wadm as extra workloads, fits apps wanting declarative links and self-healing. Row 3, SpinKube: containerd-shim-spin (embeds the Spin runtime) plus a SpinApp CRD and spin-operator, scoped to apps packaged with spin.toml and spin-sdk. Row 4, WasmEdge and other runwasi shims: same RuntimeClass pattern as row 1, different embedded runtime with extra host functions (image processing, WASI-NN). A footer band states: pick by what the app is already built against (raw WIT component, lattice-shaped app, or Spin-framework app) and how much control-plane machinery the team will run, not by preference." caption="Figure 26.1: Four ways to put a Wasm component inside Kubernetes scheduling, by what each schedules and what app shape it fits." %}

## The Spin app: `spin-sdk`, composed dependencies and an ABI surprise

`src/lib.rs` is the Spin counterpart of the Part 3 HTTP component: the same route, `GET /cargo/{id}`, the same book-then-get pattern. Spin's `#[http_service]` macro and `spin_sdk::http::{Request, Response}` replace hand-written `wit-bindgen` `Guest` impls:

{% raw %}
```rust
#[http_service]
async fn handle_cargo_spin(req: Request) -> anyhow::Result<impl IntoResponse> {
    let path = req.uri().path().to_string();

    let Some(id) = path.strip_prefix("/cargo/").filter(|rest| !rest.is_empty()) else {
        return json_response(
            404,
            r#"{"error":"not found","hint":"GET /cargo/{id}"}"#.to_string(),
        );
```
{% endraw %}

Spin gives each request its own component instance, so a bare `get-cargo` on a cold instance always misses. A known `CARGO-{ORIGIN}-{DEST}` id therefore books first and then reads back; any other id is never booked and returns a 404. `spin.toml` routes every path to the one component and leaves dispatch to the handler.

### Satisfying the import

`spin_sdk::dependencies!()` is Spin's answer to the problem `wac plug` solves elsewhere: satisfying a component's import with another component's export. A `[component.cargo-spin.dependencies]` table names the provider component. `spin build` decodes its exports, writes `spin-dependencies.wit` into the crate, and the macro generates ordinary Rust functions from it (`patterncatalyst::cargo::booking::book_cargo`, `get_cargo`) at the crate root. `spin up` can satisfy the same dependency at load time, so a local `spin up` needs no hand-run `wac plug`.

The shipped manifest carries none of that:

{% raw %}
```toml
spin_manifest_version = 2

[application]
name = "cargo-spin"
version = "0.1.0"
description = "Cargo domain HTTP front door as a Fermyon Spin component."

[[trigger.http]]
route = "/..."
component = "cargo-spin"

[component.cargo-spin]
source = "cargo-spin.wasm"
allowed_outbound_hosts = []
```
{% endraw %}

`source` points at `cargo-spin.wasm`, one already-composed artifact. `build.sh` runs `spin build` against a generated, gitignored `spin-build.toml` that does declare the dependency, then composes by hand:

{% raw %}
```bash
echo "spin/build.sh: [3/5] spin build (regenerates spin-dependencies.wit, compiles the handler) ..."
spin build -f "$BUILD_MANIFEST"
HANDLER="$SCRIPT_DIR/target/wasm32-wasip2/release/cargo_spin.wasm"
[[ -s "$HANDLER" ]] || { echo "spin/build.sh: FAIL, handler component not produced" >&2; exit 1; }
[[ -s "$SCRIPT_DIR/spin-dependencies.wit" ]] || { echo "spin/build.sh: FAIL, spin-dependencies.wit was not regenerated" >&2; exit 1; }

echo "spin/build.sh: [4/5] composing cargo-spin.wasm (wac plug: provider -> handler) ..."
wac plug --plug "$PROVIDER" "$HANDLER" -o "$OUT"
wasm-tools validate "$OUT"
```
{% endraw %}

The reason to compose by hand is packaging. The CRC runtime image ships exactly two files, `spin.toml` and `cargo-spin.wasm`, instead of a raw handler, a provider and a dependency-aware manifest the runtime resolves at startup. Before writing anything out, `build.sh` checks that the export is exactly `wasi:http/handler@0.3.0` and that every remaining import is `wasi:*`, with no `patterncatalyst:*` import left open.

### The ABI

`#[http_service]` in `spin-sdk = "=7.0.0"` targets `wasi:http@0.3.0/handler`, the wasip3 async HTTP world. Every other HTTP component here, including Part 3, every Part 5 deploy target and the wasmCloud and Istio deviations, exports `wasi:http/incoming-handler@0.2.x`. Spin's `trigger-http` runs both ABIs natively, so `spin up` and SpinKube serve the component with no translation. A `wasmtime serve` pipeline or any other 0.2.x-only host would not recognize its export.

That one fact sets the runtime floor. `containerd-shim-spin` must be v0.26.0 or later, because that release embeds Spin 4.1.0, the first line that understands `wasi:http@0.3.0`. The CRC container runs Spin CLI v4.2.4 for the same reason, and `Cargo.toml` pins the SDK exactly:

{% raw %}
```toml
[dependencies]
anyhow = "1"
spin-sdk = "=7.0.0"

[lib]
crate-type = ["cdylib"]
```
{% endraw %}

## Running Spin without a node install

`containerd-shim-spin` installs a node-level containerd plugin, and on RHCOS that needs a `MachineConfig` that restarts the node. A `restricted-v2` project cannot ask for that, which is also what pushed the raw shim off OpenShift Local in favor of the wasmCloud operator. Spin's CLI is the whole runtime a `cargo-spin.wasm` needs: `spin up` loads the component and serves its HTTP trigger, so a plain `Deployment` is enough, with no CRD and no controller. When a platform refuses a node-level runtime install, wrap the runtime itself in an ordinary container and let the platform's admission rules do the rest.

## Deploying Spin two ways

On **minikube**, the app runs through the full SpinKube platform. `install-spinkube.sh` lays down four pieces, each gated on observed state rather than a fixed sleep:

1. cert-manager v1.21.2, a `spin-operator` webhook prerequisite, proven with a throwaway self-signed `Certificate` the webhook must admit rather than by a Pod reporting `Ready`. A failed smoke test falls back to v1.20.0 and the script reports which one is running.
2. The `runtime-class-manager` Helm chart (v0.2.0), which installs `containerd-shim-spin` on every node labeled `spin=true` and provisions the `RuntimeClass` once the shim is in place:

{% raw %}
```bash
step "2/4 runtime-class-manager $RUNTIME_CLASS_MANAGER_VERSION (Helm)"
helm upgrade --install runtime-class-manager "$RUNTIME_CLASS_MANAGER_CHART" \
  --version "$RUNTIME_CLASS_MANAGER_VERSION" \
  --namespace "$RUNTIME_CLASS_MANAGER_NAMESPACE" --create-namespace \
  --wait --timeout 5m
echo "install-spinkube.sh: runtime-class-manager $RUNTIME_CLASS_MANAGER_VERSION installed (namespace $RUNTIME_CLASS_MANAGER_NAMESPACE)"

step "2b/4 Shim CR for containerd-shim-spin $SHIM_SPIN_VERSION + node labels ($SHIM_SPIN_NODE_LABEL)"
kubectl apply -f "$SHIM_SPIN_MANIFEST_URL"
kubectl label node --all "$SHIM_SPIN_NODE_LABEL" --overwrite
```
{% endraw %}

3. `spin-operator` v0.6.1: its CRDs, a `SpinAppExecutor` named `containerd-shim-spin` that tells the operator which `RuntimeClass` (`wasmtime-spin-v2`) to schedule onto, and the operator chart.
4. A `ghcr-pull` image-pull secret for the private `ghcr.io/patterncatalyst/cargo-spin:spinkube` image, built from `gh auth token`.

The `SpinApp` is small because those steps did the work:

{% raw %}
```yaml
apiVersion: core.spinkube.dev/v1alpha1
kind: SpinApp
metadata:
  name: cargo-spin
  namespace: part6-spin
  labels:
    app.kubernetes.io/name: cargo-spin
    app.kubernetes.io/part-of: part6-spin
spec:
  image: ghcr.io/patterncatalyst/cargo-spin:spinkube
  executor: containerd-shim-spin
  replicas: 1
  imagePullSecrets:
    - name: ghcr-pull
```
{% endraw %}

`spin-operator` reconciles it into a `Deployment` and a `Service`, both named `cargo-spin`, with the `Service` on port 80. The only path in is `base/ingress.yaml`, patched live to `cargo-spin.<minikube-ip>.nip.io`: host, Ingress, Service, Pod (`runtimeClassName: wasmtime-spin-v2`), `containerd-shim-spin`'s HTTP trigger, `cargo-spin.wasm`. No port-forward and no NodePort.

On **OpenShift Local**, the Dockerfile packages the pinned Spin CLI on `debian:trixie-slim`, the smallest base in rotation that already carries the glibc, libgcc and libstdc++ the Spin binary links against, and verifies the release checksum at image build. The runtime half is:

{% raw %}
```dockerfile
WORKDIR /app
COPY spin.toml /app/spin.toml
COPY cargo-spin.wasm /app/cargo-spin.wasm

ENV HOME=/app
USER 10001
EXPOSE 8080
ENTRYPOINT ["spin", "up", "--listen", "0.0.0.0:8080", "-f", "/app/spin.toml"]
```
{% endraw %}

`openshift/deployment.yaml` sets no `runAsUser`. The numeric `USER 10001` already satisfies `runAsNonRoot: true`, and `restricted-v2` assigns its own uid from the project's range; pinning one would fight that range. `/app` is group-0 writable (`chmod g=u`) for the arbitrary uid, with `.cache` pre-created for Spin's compilation cache. Privilege escalation is off, every capability is dropped and the seccomp profile is `RuntimeDefault`, with no `anyuid` exception. `openshift/route.yaml` fronts the Service with an edge-TLS Route that terminates TLS and forwards plain HTTP to the Service's `http` port.

| | minikube (SpinKube) | OpenShift Local (Spin in a container) |
|---|---|---|
| Runtime | `containerd-shim-spin` v0.26.0, node-level | Spin CLI v4.2.4, in-container |
| Kubernetes object | `SpinApp` (`core.spinkube.dev/v1alpha1`) | plain `Deployment` |
| Controller | `spin-operator` v0.6.1 | none |
| Scheduling | `RuntimeClass wasmtime-spin-v2` | ordinary Pod, no `RuntimeClass` |
| Node change | shim binary and containerd config, installed by a Helm-installed installer | none |
| Entry point | image Spin's trigger loads directly | `spin up -f spin.toml` as the container `ENTRYPOINT` |
| Edge | ingress-nginx, `nip.io` host | edge-TLS Route, `apps-crc.testing` host |

The component and what it serves are identical. Only the control-plane depth underneath changes, set by what each platform lets a privileged node change touch.

> **Decision**
>
> Use SpinKube when the app is already a Spin application (`spin-sdk`, `spin.toml`, a Spin OCI artifact) and the cluster accepts a node-level shim install, so a `SpinApp` is a first-class object with its own operator. Use the wasmCloud operator when the workload wants lattice properties (declarative links, swappable providers, `wadm` self-healing) regardless of how the component was packaged. Use the raw `containerd-shim-wasmtime` when the component is a plain WIT artifact and the cluster permits a node install; it carries the least machinery. When no install fits (`restricted-v2`, a managed node image, no privileged role), run the runtime in an ordinary container.

> **🤖 Explore with your agent**
>
> "In examples/part6-deviations/spin, the handler exports wasi:http/handler@0.3.0. Add a GET /health route to src/lib.rs that returns {\"status\":\"ok\"} with a 200, rebuild with ./build.sh, and tell me which of the minikube SpinKube path and the OpenShift Local spin up container needs a different Spin runtime version because of the ABI, and which one needs a node-level install."
>
> Check: build.sh prints the exports and imports and still lists exactly `wasi:http/handler@0.3.0`; the reply names containerd-shim-spin v0.26.0 for minikube and says the CRC container needs no node change.

## Build, run, observe

```bash
cd examples/part6-deviations/spin && ./build.sh
cd ../spinkube && ./verify-spinkube-minikube.sh
```

`build.sh` compiles the handler, regenerates `spin-dependencies.wit`, composes `cargo-spin.wasm` with `wac plug` and fails unless the export is `wasi:http/handler@0.3.0` with no open `patterncatalyst:*` import. `verify-spinkube-minikube.sh` starts or reuses the Part 5 minikube profile, installs cert-manager, `runtime-class-manager` and `spin-operator`, applies the `SpinApp`, patches the Ingress to a live `nip.io` host, and passes on an HTTP 200 with the cargo JSON plus a 404 for an unknown id through ingress-nginx. `--keep` leaves the profile up. `spinkube/openshift/verify-crc.sh` runs the same checks against the container behind the Route with a CA-verified `curl`, never `-k`. The `capture-evidence.sh` scripts write scrubbed `evidence/<date>/` files; `spin/README.md` covers local `spin up` and `spinkube/README.md` the platform install.

Experiments:

- Run the component under `wasmtime serve`: the 0.2.x-only host does not recognize the `wasi:http/handler@0.3.0` export.
- Use a `containerd-shim-spin` older than v0.26.0: the embedded Spin does not understand the wasip3 world.

## For deeper coverage

- [Spin documentation](https://spinframework.dev/): the `spin.toml` manifest, trigger model and `spin-sdk`.
- [SpinKube documentation](https://www.spinkube.dev/): the `SpinApp` CRD, `spin-operator` and `runtime-class-manager`.
- [`fermyon/spin-sdk-rs`](https://github.com/fermyon/spin-rust-sdk): the `#[http_service]` macro and `spin_sdk::dependencies!()`.
- [WasmEdge documentation](https://wasmedge.org/): the runwasi shim and its host-function extensions.
- wasmCloud, and wasmtime and wasmCloud together: the lattice properties weighed against SpinKube's operator model.
- Wasm on Kubernetes: the deployment-path landscape this map extends.
- Deploying on minikube and on OpenShift Local (CRC): the raw shim and the wasmCloud-operator substitution that the Spin minikube and CRC split mirrors.
- Istio and WebAssembly: the same component under a different control-plane depth.

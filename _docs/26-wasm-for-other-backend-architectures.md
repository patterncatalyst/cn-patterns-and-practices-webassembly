---
title: "WebAssembly for Other Backend Architectures"
order: 26
part: "Deviations"
description: "Place the containerd shim, the wasmCloud operator, SpinKube, and WasmEdge's own runwasi shim on one map, then run a Fermyon Spin app for the cargo domain through full SpinKube on minikube and a plain restricted-v2 container on OpenShift Local."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- Place `containerd-shim-wasmtime`/runwasi, the wasmCloud operator, SpinKube, and WasmEdge's own runwasi shim on one map by what each schedules, what control-plane machinery it carries, and what kind of app each fits: the landscape Chapter 17 opened and named SpinKube a Part 6 topic for.
- Read `examples/part6-deviations/spin/src/lib.rs` and name the one ABI fact that drives every deploy decision in this chapter: `spin-sdk = "=7.0.0"`'s `#[http_service]` macro exports `wasi:http/handler@0.3.0` (wasip3), not the `wasi:http/incoming-handler@0.2.x` world every earlier HTTP example in this book targets.
- Read `spin.toml` and `build.sh` together and explain why the shipped manifest carries no `[component.cargo-spin.dependencies]` section even though the app imports `patterncatalyst:cargo`, and what the gitignored `spin-build.toml` does instead.
- Trace the minikube path (`SpinApp` → `spin-operator` → `containerd-shim-spin` → `RuntimeClass wasmtime-spin-v2`) against the CRC path (`spin up` inside a plain `restricted-v2` `Deployment`), and state the constraint that forces the split: the same constraint Chapter 19 hit with the raw shim.
- Decide, for a given backend, whether SpinKube, the wasmCloud operator, or the raw containerd shim is the right fit, based on what the app is already built against rather than preference.

## Why this matters

Chapter 17 surveyed four ways to run a Wasm workload on Kubernetes and set one of them aside for later: "SpinKube... is a Part 6 survey topic, named here because it is frequently confused with the generic shim this chapter teaches." That chapter needed the distinction to keep its own scope clean: this book's components are built directly against the WIT contract from Chapter 3, with no Spin-specific packaging, so `containerd-shim-spin` was not a fit for anything in Part 5. This chapter is where that deferred topic gets a real example instead of a one-paragraph mention. `examples/part6-deviations/spin` is a Fermyon Spin HTTP component serving the same cargo domain every earlier chapter serves, composed with the unedited Part 2 Rust provider the same way every other Part 5/6 example composes it. `contracts/wit` is untouched; Spin's own tooling sits on top of the identical interface, not a fork of it.

The point of running this app is not "Spin is another way to build HTTP services." That much is obvious from `spin.toml`. The point is what happens when a framework's own ABI choice collides with a cluster's installed runtime version, and what happens when that cluster can't take the node-level install the framework's own Kubernetes integration wants. Both collisions are real in this chapter's example tree, not hypothetical: `spin-sdk = "=7.0.0"` exports an ABI only a Spin 4.1+ runtime understands, which pins the exact shim build minikube needs; and `containerd-shim-spin` needs the same kind of privileged node surgery that pushed Chapter 19 off the raw shim and onto the wasmCloud operator, which pushes this chapter off SpinKube and onto a plain container on CRC. Both halves of this chapter are **verified live 2026-10-22**: the minikube SpinKube path (the SpinApp on `containerd-shim-spin` v0.26.0 / RuntimeClass `wasmtime-spin-v2`, through the nip.io ingress) and the CRC path (the Spin runtime in a restricted-v2 container, through an edge-TLS Route, CA-verified), each serving the exact cargo JSON and a 404. Evidence is under `spinkube/evidence/2026-10-22/` and `spinkube/openshift/evidence/2026-10-22/`.

## The server-side-Wasm backend landscape: when each fits

Four different projects put a Wasm component inside a Kubernetes-shaped scheduling model, and none of them compete head-on: each answers a differently scoped question, and the right one depends on what the app is already built against and how much control-plane machinery a team is willing to run for it.

`containerd-shim-wasmtime`, the mechanism Chapter 17 teaches and Chapter 18 runs live, is the generic floor. It is a `runwasi`-scaffolded containerd shim plus a `RuntimeClass`: install the binary on a node (by a one-time script, as this book does, or a DaemonSet installer such as KWasm), register it in `/etc/containerd/config.toml`, and any Pod with `runtimeClassName: wasmtime` schedules onto it. It runs any component exporting a WASI world the shim's wasmtime embedding understands: `wasi:http/proxy`, `wasi:cli/run`, the shapes every component in Parts 2 through 5 of this book exports, with no framework-specific packaging step and no extra Kubernetes objects beyond the `RuntimeClass` itself. The operational surface is the smallest on this map: one shim binary per node, one `RuntimeClass`, ordinary `Deployment`/`Service`/`Ingress` manifests otherwise unchanged. It fits a team that built its component directly against a WIT contract and wants nothing more than a way to schedule it.

The wasmCloud operator, the mechanism Chapter 15 introduces as a single-host lattice and Chapter 19 runs on CRC, answers a different question entirely: not "how do I schedule this component" but "how do I run this component inside a lattice, inside Kubernetes." The operator schedules a wasmCloud host itself as an ordinary Pod (no `RuntimeClass`, no node-level change), and `wadm` then deploys an application onto that in-cluster lattice the same declarative way it deploys onto a local `wash up -d` lattice: a component, a capability provider, and a link between them. That buys a team the lattice properties Chapter 16 names (capability providers swappable without rebuilding the component, declarative links, `wadm`'s self-healing reconcile loop) at the cost of carrying NATS, a host process, and `wadm` as additional Kubernetes workloads on top of the component itself. It fits a workload that already wants those lattice properties, or a cluster where the raw shim hits a real WASI feature gap and the lattice's wasmtime embedding absorbs it instead.

SpinKube, this chapter's own topic, is the closest sibling to the raw shim and the easiest of the four to confuse with it. `containerd-shim-spin` is also a `runwasi`-scaffolded containerd shim registered under a `RuntimeClass`, but the shim embeds the **Spin runtime** itself, not a generic wasmtime embedding, so it only runs applications packaged Spin's way: a `spin.toml` manifest declaring triggers (HTTP, and others Spin supports beyond what this chapter exercises), components built against `spin-sdk`'s ergonomic layer rather than hand-rolled WASI host-import bindings, and Spin's own OCI packaging (`spin registry push`) rather than a generic container image. SpinKube adds one more piece on top of the shim that the raw path doesn't have: a `SpinApp` custom resource and a `spin-operator` controller that reconciles it into a `Deployment` and `Service`, so a Spin app is a first-class Kubernetes object instead of a bare `Deployment` with a `runtimeClassName` field a human wrote by hand. It fits a team already standardized on Spin's trigger model and SDK ergonomics that wants that framework's own object model in the cluster, not a team building directly against WIT with no interest in Spin's packaging.

WasmEdge, and any other `runwasi`-based shim, sits structurally beside `containerd-shim-wasmtime`: same `RuntimeClass` pattern, same node-install or DaemonSet-installer mechanics, same "a component schedules like a container" contract. What changes is the embedded runtime and the host functions it carries: WasmEdge ships additional host-function extensions (image processing, WASI-NN acceleration among them) that a stock wasmtime embedding does not. A component that specifically needs one of those extensions fits a WasmEdge shim; a component built against the plain WASI worlds this book targets runs identically under either embedding, so the choice there is about the extension surface, not a different operations model from the raw shim this book already teaches.

{% include excalidraw.html file="26-wasm-backend-landscape" alt="A four-row landscape table. Row 1, containerd-shim-wasmtime (runwasi): a generic shim plus RuntimeClass, smallest operational footprint, runs any wasi:http/proxy or wasi:cli component built directly against WIT, this book's Part 5 mechanism. Row 2, wasmCloud operator: schedules a wasmCloud host as a Pod, wadm deploys component+provider+link onto that in-cluster lattice, brings NATS+host+wadm as extra workloads, fits apps wanting declarative links and self-healing. Row 3, SpinKube: containerd-shim-spin (embeds the Spin runtime itself) plus a SpinApp CRD and spin-operator, scoped to apps packaged with spin.toml and spin-sdk, this chapter's mechanism. Row 4, WasmEdge / other runwasi shims: same RuntimeClass pattern as row 1, different embedded runtime with extra host functions (image processing, WASI-NN), fits a component needing that specific extension surface. A footer band states: pick by what the app is already built against (raw WIT component, lattice-shaped app, or Spin-framework app) and how much control-plane machinery the team is willing to run, not by preference." caption="Figure 26.1: four ways to put a Wasm component inside Kubernetes's scheduling model, by what each schedules and what app shape it fits." %}

## The Spin app: `spin-sdk`, a dependency Spin resolves itself, and a real ABI surprise

`examples/part6-deviations/spin/src/lib.rs` is the Spin-native counterpart to `examples/part3-interfaces/http-rust`: the same route, `GET /cargo/{id}`, the same domain, the same book-then-get pattern, on a different host with a different entrypoint macro. Spin's `#[http_service]` attribute and the `spin_sdk::http::{Request, Response}` types are the framework's ergonomic layer over a component's HTTP ABI; a function signature and a `Response::builder()` call stand in for hand-written `wit-bindgen` `Guest` impls:

{% raw %}
```rust
use spin_sdk::http::{IntoResponse, Request, Response};
use spin_sdk::http_service;

spin_sdk::dependencies!();

use patterncatalyst::cargo::booking::{book_cargo, get_cargo};
use patterncatalyst::cargo::types::{CargoError, Location, RouteSpec};

#[http_service]
async fn handle_cargo_spin(req: Request) -> anyhow::Result<impl IntoResponse> {
    let path = req.uri().path().to_string();

    let Some(id) = path.strip_prefix("/cargo/").filter(|rest| !rest.is_empty()) else {
        return json_response(
            404,
            r#"{"error":"not found","hint":"GET /cargo/{id}"}"#.to_string(),
        );
    };
    // Known shape CARGO-{ORIGIN}-{DEST}: book (seed) then read back.
    // Any other id is never booked, so get-cargo legitimately misses.
    ...
}
```
{% endraw %}

`spin.toml`'s trigger section is the entire routing table: one `[[trigger.http]]` entry with `route = "/..."` sends every path on the application to the `cargo-spin` component, and the component itself does the actual dispatch inside `handle_cargo_spin`: a known `CARGO-{ORIGIN}-{DEST}` id books then reads back, giving a cold component instance something to find; any other id legitimately misses and returns a 404, the same contract every earlier HTTP example in this book serves.

The import side is the more interesting mechanism. `spin_sdk::dependencies!()`, called once at the top of `lib.rs`, is Spin's own answer to the same problem `wac plug` solves everywhere else in this book: satisfying a component's import with another component's export. A manifest's `[component.cargo-spin.dependencies]` table names a path to the provider component; `spin build` reads that table, decodes the referenced component's exports, writes a `spin-dependencies.wit` file into the crate directory, and `spin_sdk::dependencies!()` bindgens it into ordinary Rust functions (`patterncatalyst::cargo::booking::book_cargo`, `get_cargo`), generated at the crate root rather than behind a `bindings::` module prefix. `spin up` and `spin registry push` can satisfy the same dependency at load time too, through the identical `wac`-based graph composition Spin runs internally, with no hand-run `wac plug` required for a `spin up`-only workflow.

The shipped `spin.toml` carries none of that dependency machinery:

{% raw %}
```toml
spin_manifest_version = 2

[application]
name = "cargo-spin"
version = "0.1.0"
description = "Cargo domain HTTP front door as a Fermyon Spin component (ch26)."

[[trigger.http]]
route = "/..."
component = "cargo-spin"

[component.cargo-spin]
source = "cargo-spin.wasm"
allowed_outbound_hosts = []
```
{% endraw %}

`component.cargo-spin.source` points straight at `cargo-spin.wasm`, a single already-composed artifact, because `build.sh` runs two manifests rather than one. The first, a gitignored, generated `spin-build.toml`, declares `[component.cargo-spin.dependencies]` against the freshly built Part 2 provider, which is what makes `spin build` regenerate `spin-dependencies.wit` and compile the handler to `wasm32-wasip2`. The second step then runs `wac plug` by hand, the same tool and the same shape every other Part 5/6 example in this book uses, to compose that raw handler with the provider directly into one self-contained `cargo-spin.wasm` whose import is already satisfied:

{% raw %}
```bash
echo "spin/build.sh: [3/5] spin build (regenerates spin-dependencies.wit, compiles the handler) ..."
spin build -f "$BUILD_MANIFEST"
HANDLER="$SCRIPT_DIR/target/wasm32-wasip2/release/cargo_spin.wasm"

echo "spin/build.sh: [4/5] composing cargo-spin.wasm (wac plug: provider -> handler) ..."
wac plug --plug "$PROVIDER" "$HANDLER" -o "$OUT"
wasm-tools validate "$OUT"
```
{% endraw %}

The reason to bother composing by hand when Spin could satisfy the dependency itself at `spin up` time is packaging, not correctness: the CRC runtime image ships exactly two files, `spin.toml` and `cargo-spin.wasm`, the same "one pre-composed artifact" shape every other Part 5/6 runtime image in this book holds to, rather than a raw handler plus a provider file plus a dependency-aware manifest the runtime has to resolve at startup. `build.sh` asserts the composition actually closed the loop before it writes anything out: the export must be exactly `wasi:http/handler@0.3.0`, and every remaining import must be `wasi:*`, with no `patterncatalyst:*` import left unsatisfied by the plug.

That export name is the chapter's real teaching point: `spin-sdk = "=7.0.0"`'s `#[http_service]` macro targets `wasi:http@0.3.0/handler`, the **wasip3** async HTTP world, not `wasi:http/incoming-handler@0.2.x`, the ABI every other HTTP example in this book exports: `part3-interfaces/http-rust`, every Part 5 Kubernetes deploy target, the wasmCloud and Istio deviations. `cargo-spin.wasm` is correct and runnable; it simply requires a host that speaks wasip3's HTTP world. Spin's own `trigger-http` runs both ABIs natively, so `spin up` and SpinKube serve this component with no translation layer, but a `wasmtime serve` pipeline or any other 0.2.x-only host would not recognize its exports. That single ABI fact is why containerd-shim-spin needs to be `v0.26.0` or later: that version embeds Spin `4.1.0`, the first line that understands `wasi:http@0.3.0`, and it is why the CRC container runs the pinned Spin CLI `v4.2.4` rather than an arbitrary release: both deploy targets this chapter builds have to run a Spin runtime new enough for the ABI this SDK version actually emits, and `Cargo.toml` pins the SDK itself exact for the same reason:

{% raw %}
```toml
[dependencies]
anyhow = "1"
spin-sdk = "=7.0.0"

[lib]
crate-type = ["cdylib"]
```
{% endraw %}

## Deploying Spin two ways

The chapter runs the same artifact, `cargo-spin.wasm`, on both cluster paths this book always compares, by two different mechanisms, the identical constraint Chapter 19's wasmCloud-operator substitution already established for the raw shim: `containerd-shim-spin` needs a privileged RHCOS node install that does not fit the `restricted-v2` posture the CRC chapters hold to.

On **minikube**, the app runs through the complete SpinKube platform. `install-spinkube.sh` lays down four pieces in order, each gated on real proof rather than a fixed sleep. First, cert-manager (a `spin-operator` webhook prerequisite), installed at `v1.21.2` and proven with a throwaway self-signed `Certificate` the webhook must actually admit, not just a Pod reporting `Ready`; a failed smoke test falls back to `v1.20.0` and the script reports on stdout which version is actually running. Second, the `runtime-class-manager` Helm chart (`v0.2.0`), which installs `containerd-shim-spin` (`v0.26.0`) on every node labeled `spin=true` and, once the shim is in place, provisions the `RuntimeClass` this chapter's Pod will reference:

{% raw %}
```bash
step "2/4 runtime-class-manager $RUNTIME_CLASS_MANAGER_VERSION (Helm)"
helm upgrade --install runtime-class-manager "$RUNTIME_CLASS_MANAGER_CHART" \
  --version "$RUNTIME_CLASS_MANAGER_VERSION" \
  --namespace "$RUNTIME_CLASS_MANAGER_NAMESPACE" --create-namespace \
  --wait --timeout 5m

step "2b/4 Shim CR for containerd-shim-spin $SHIM_SPIN_VERSION + node labels ($SHIM_SPIN_NODE_LABEL)"
kubectl apply -f "$SHIM_SPIN_MANIFEST_URL"
kubectl label node --all "$SHIM_SPIN_NODE_LABEL" --overwrite

wait_for_resource 300 "RuntimeClass '$SPIN_RUNTIMECLASS' present" runtimeclass "$SPIN_RUNTIMECLASS"
```
{% endraw %}

Third, `spin-operator` (`v0.6.1`): its CRDs, a `SpinAppExecutor` named `containerd-shim-spin` that tells the operator which `RuntimeClass` (`wasmtime-spin-v2`) to schedule a `SpinApp`'s Pod onto, and the operator chart itself. Fourth, a `ghcr-pull` image-pull secret for the private `ghcr.io/patterncatalyst/cargo-spin:spinkube` image, built from `gh auth token`, the same pattern every private `cargo-*` package in this book uses. The `SpinApp` custom resource itself is small precisely because the preceding four steps did the real work:

{% raw %}
```yaml
apiVersion: core.spinkube.dev/v1alpha1
kind: SpinApp
metadata:
  name: cargo-spin
  namespace: part6-spin
spec:
  image: ghcr.io/patterncatalyst/cargo-spin:spinkube
  executor: containerd-shim-spin
  replicas: 1
  imagePullSecrets:
    - name: ghcr-pull
```
{% endraw %}

`spin-operator` reconciles that `SpinApp` into a `Deployment` and a `Service`, both named `cargo-spin`, the `Service` listening on port 80: the same name and port pairing SpinKube's own quickstart documents, not something the Ingress manifest invents. `base/ingress.yaml` is the only externally reachable path in, patched live to `cargo-spin.<minikube-ip>.nip.io` the same `nip.io` convention every other Part 5 Ingress host in this book uses; the live request path runs host → Ingress → Service → Pod (`runtimeClassName: wasmtime-spin-v2`) → `containerd-shim-spin`'s own HTTP trigger → `cargo-spin.wasm`, with no port-forward, no NodePort, and no `minikube service` shortcut anywhere in the chain.

On **CRC**, the same artifact runs without any of that platform. `containerd-shim-spin` needs the same kind of privileged RHCOS node install (a node-level containerd plugin and a `MachineConfig` that restarts the node) that pushed Chapter 19 off the raw `containerd-shim-wasmtime` and onto the wasmCloud operator instead. Here the substitute is simpler than an operator, because Spin's own CLI *is* the whole runtime a `cargo-spin.wasm` component needs: `spin up` loads the component and serves its HTTP trigger directly, so an ordinary `Deployment` under `restricted-v2` is enough, with no CRD and no controller at all. `Dockerfile` packages the pinned `spin` `v4.2.4` binary on `debian:trixie-slim` (the smallest base in this book's rotation that already carries the glibc, libgcc, and libstdc++ the Spin binary links against), verified against its release checksum at image-build time:

{% raw %}
```dockerfile
FROM debian:trixie-slim
ARG SPIN_VERSION=v4.2.4
ARG SPIN_SHA256=519ba201e0105dc83a17a4ea9ca6605c80286cbfaf40c1d7505d068bfea83cf1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 \
    && curl -fsSL -o /tmp/spin.tar.gz "https://github.com/fermyon/spin/releases/download/${SPIN_VERSION}/spin-${SPIN_VERSION}-linux-amd64.tar.gz" \
    && echo "${SPIN_SHA256}  /tmp/spin.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/spin.tar.gz -C /tmp spin && install -m 0755 /tmp/spin /usr/local/bin/spin
RUN groupadd --system --gid 10001 cargo-spin \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin cargo-spin \
    && mkdir -p /app/.cache && chown -R 10001:0 /app && chmod -R g=u /app
WORKDIR /app
COPY spin.toml /app/spin.toml
COPY cargo-spin.wasm /app/cargo-spin.wasm
ENV HOME=/app
USER 10001
EXPOSE 8080
ENTRYPOINT ["spin", "up", "--listen", "0.0.0.0:8080", "-f", "/app/spin.toml"]
```
{% endraw %}

`openshift/deployment.yaml` sets no `runAsUser`: the image's fixed numeric `USER 10001` already satisfies the `runAsNonRoot: true` admission check, and `restricted-v2` assigns its own uid from the project's allocated SCC range at admission time: pinning a uid in the manifest would fight that range instead of living inside it, the identical reasoning the wasmCloud host container in Chapter 19 already applies. `allowPrivilegeEscalation: false`, every capability dropped, and `seccompProfile: RuntimeDefault` cover the rest of the posture explicitly, with no `anyuid` exception requested anywhere. `openshift/route.yaml` fronts the Service with the same edge-TLS pattern every CRC chapter in this book uses (the router terminates TLS and forwards plain HTTP to the Service's `http` port), and every assertion in `verify-crc.sh` goes through that Route with a CA-verified `curl`, never `-k`, never a port-forward.

| | minikube (SpinKube) | CRC (Spin runtime in a container) |
|---|---|---|
| Runtime | `containerd-shim-spin` v0.26.0, node-level | Spin CLI v4.2.4, in-container |
| Kubernetes object | `SpinApp` (`core.spinkube.dev/v1alpha1`) | plain `Deployment` |
| Controller | `spin-operator` v0.6.1 | none |
| Scheduling | `RuntimeClass wasmtime-spin-v2` | ordinary Pod, no `RuntimeClass` |
| Node change | shim binary + containerd config, via a Helm-installed DaemonSet-style installer | none |
| Entry point | `cargo-spin.wasm` image Spin's trigger loads directly | `spin up -f spin.toml`, the container's `ENTRYPOINT` |
| Edge | ingress-nginx, `nip.io` host | edge-TLS Route, `apps-crc.testing` host |

What differs between the two paths is entirely the same thing Chapter 25 already established for Istio's community build versus OSSM3: the control-plane depth underneath an identical component, driven by what each platform will let a privileged node change touch, not a difference in the component itself or in what it serves.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for SpinKube when the app is already a Spin application (built against <code>spin-sdk</code>, packaged as a <code>spin.toml</code> manifest, pushed as a Spin OCI artifact) and the cluster will accept a node-level shim install (a cluster you fully control, or a managed node image with a DaemonSet-style installer such as <code>runtime-class-manager</code>); the payoff is a <code>SpinApp</code> as a first-class object with its own operator reconciling it, instead of a bare <code>Deployment</code> a human wrote by hand. Reach for the wasmCloud operator instead when the workload wants the lattice's own properties (declarative links, swappable capability providers, <code>wadm</code>'s self-healing reconcile) on top of running in Kubernetes, independent of what packaging format built the component. Reach for the raw <code>containerd-shim-wasmtime</code> path when the component is a plain WIT-built artifact with no framework packaging at all, and the cluster permits a node-level install; it carries the least machinery of the three live options. When none of those installs fits the platform (<code>restricted-v2</code>, a managed node image, no privileged role), the fallback is the same for every one of these mechanisms: wrap the runtime itself in an ordinary container and let the platform's standard admission rules do the rest, the way this chapter's CRC Deployment and Chapter 19's wasmCloud host both do.</p></div>

Evidence for both halves lands the same way every other chapter in this book captures it: `capture-evidence.sh` on the minikube side and `openshift/capture-evidence.sh` on CRC each commit versions, the live manifests, the HTTP proof, and the component's sha256 under their own `evidence/<date>/` directory, scrubbed of credential material. Both ran on 2026-10-22; the evidence is committed under those directories.

## For deeper coverage

- [Spin documentation](https://spinframework.dev/): the `spin.toml` manifest, trigger model, and `spin-sdk` ergonomics `src/lib.rs` is built against.
- [SpinKube documentation](https://www.spinkube.dev/): the `SpinApp` CRD, `spin-operator`, and `runtime-class-manager`'s installation of `containerd-shim-spin`, this chapter's minikube mechanism.
- [`fermyon/spin-sdk-rs`](https://github.com/fermyon/spin-rust-sdk): the `#[http_service]` macro and `spin_sdk::dependencies!()` composition helper this chapter's handler crate depends on.
- [WasmEdge documentation](https://wasmedge.org/): the runwasi-based shim and host-function extension surface named in this chapter's landscape section as the fourth entry on the map.
- Chapter 15, "wasmCloud" and Chapter 16, "wasmtime and wasmCloud Together": the lattice properties this chapter's landscape section weighs against SpinKube's operator model.
- Chapter 17, "Wasm on Kubernetes": the four-project landscape this chapter extends, and the paragraph that named SpinKube a Part 6 topic in the first place.
- Chapter 18, "Deploying on minikube" and Chapter 19, "Deploying on OpenShift Local (CRC)": the raw shim and the wasmCloud-operator substitution this chapter's own minikube/CRC split mirrors for a Spin app instead of a plain WIT component.
- Chapter 25, "Istio and WebAssembly": the same same-component-different-control-plane-depth framing this chapter's minikube/CRC comparison table applies a second time.

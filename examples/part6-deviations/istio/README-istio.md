# ch25 — Istio + WebAssembly (proxy-wasm `WasmPlugin`)

Deployment manifests + verify scripts for ch25. Both clusters reuse the
existing Part 5 app unmodified — this chapter layers a service mesh and a
proxy-wasm filter around it, it does not change the app.

## Design: the proxy-wasm filter runs in the gateway, not a sidecar

A `runtimeClassName: wasmtime` Pod runs one container runtime for every
container in it, so an injected sidecar Envoy would share the app's
wasmtime shim rather than running under Envoy's normal runtime. This
chapter instead runs the proxy-wasm filter in the istio-ingressgateway's
own Envoy — an ordinary Pod with no RuntimeClass — and keeps cargo-http a
pure Wasm Pod with no injection label and no sidecar.

Verified live on minikube, 2026-10-22: without `x-cargo-tenant` the gateway
returns 403; with it, 200 plus `x-cargo-filtered-by: cargo-wasmfilter` and
the cargo JSON.

## Teaching point: two Wasm worlds, split across two Pods

With the gateway-level design, the mesh runs two independent Wasm runtimes
that share nothing but the network path between them — not the same Pod:

- **Our Component-Model app** (`app.wasm`, sha256 `eff7f5ee…`) — the same
  artifact Parts 2-5 run, built with `cargo-component` against
  `contracts/wit`'s `wasi:http/incoming-handler` world. On minikube it runs as
  the Pod's main (and only) container under the `containerd-shim-wasmtime`
  RuntimeClass (`examples/part5-kubernetes/k8s/base`, unmodified — see
  `../../part5-kubernetes/INTERPOSITION.md`). On CRC it runs inside the
  wasmCloud host process the operator manages
  (`examples/part5-kubernetes/openshift`), because the containerd shim needs a
  privileged RHCOS MachineConfig that restricted-v2 does not allow.
- **The proxy-wasm filter** (`filter.wasm`,
  `examples/part6-deviations/istio-wasmfilter`) — a completely different Wasm
  ABI, toolchain (`proxy-wasm` crate, plain `cargo build --target
  wasm32-wasip1`, not `cargo-component`), and host: it runs inside the
  istio-ingressgateway's Envoy, loaded via `./gateway-wasmplugin.yaml`
  (minikube) / `openshift/wasmplugin.yaml` (CRC) — an ordinary Pod with no
  RuntimeClass, where proxy-wasm's host environment works exactly as upstream
  Istio documents it.

The filter requires an `x-cargo-tenant` request header (403 if absent) and
injects an `x-cargo-filtered-by: cargo-wasmfilter` response header when it
runs — both clusters' verify scripts assert both behaviors through a real
network edge, never a port-forward.

## Run order — minikube

```
# 1. Bring up the Part 5 app (keeps the profile running for this chapter)
../../part5-kubernetes/k8s/verify-minikube.sh --keep

# 2. Install Istio 1.31.2 on that same profile (no sidecar injection; creates
#    the ghcr-pull secret the gateway's WasmPlugin needs)
./istio-install.sh

# 3. Build + push the filter image (sibling task, examples/part6-deviations/istio-wasmfilter)
#    oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio must exist before this step.

# 4. Layer the ch25 Gateway + VirtualService onto the existing (pure Wasm, no
#    sidecar) app, apply gateway-wasmplugin.yaml into istio-system, and prove it
./verify-istio-minikube.sh
```

## Run order — CRC / OpenShift Service Mesh 3

```
eval "$(crc oc-env)"

# 1. Bring up the Part 5 wasmCloud app (unmodified)
../../part5-kubernetes/openshift/install-operator.sh
../../part5-kubernetes/openshift/deploy.sh

# 2. Install OSSM3 (Sail operator) on the same cluster (no sidecar injection;
#    creates the ghcr-pull secret the gateway's WasmPlugin needs)
./install-ossm.sh

# 3. Build + push the filter image (sibling task) — same OCI ref as minikube.

# 4. Layer the ch25 Gateway + VirtualService + Route, apply the gateway-scoped
#    WasmPlugin into istio-system, and prove it
./verify-istio-crc.sh
```

## Pins

- Istio **1.31.2** (`istioctl`); `WasmPlugin` API `extensions.istio.io/v1alpha1`.
- Filter OCI ref: `oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio`
  (built by the `istio-wasmfilter` sibling task).
- Istio↔Kubernetes skew: Istio 1.31 supports Kubernetes 1.32–1.36; Part 5 pins
  minikube's control plane to 1.37.1 — `istio-install.sh` step 1 runs
  `istioctl x precheck` as the gate; re-pin
  `KUBERNETES_VERSION` into the supported window if it fails.
- CRC: OpenShift Service Mesh 3 via the Sail operator
  (`sailoperator.io/v1` `Istio` + `IstioCNI` CRs); OperatorHub package
  `servicemeshoperator3`, pinned CSV, Manual approval — see
  `install-ossm.sh`'s `TBD-confirm-at-kickoff` note for the exact CSV string.

## Known TBD / risk items (author-only pass, no live cluster)

1. **OSSM3 Subscription CSV** (`install-ossm.sh`) — the exact `startingCSV`
   for `servicemeshoperator3` on the `stable` channel was not confirmed
   against a live OperatorHub catalog; confirm with `oc get packagemanifest
   servicemeshoperator3 -n openshift-marketplace` before the live run.
2. **Gateway namespace/label on OSSM3** (`openshift/wasmplugin.yaml`) — this
   pass assumes the Sail operator's istio-ingressgateway workload lands in
   `istio-system` with the standard `istio: ingressgateway` Pod label, same as
   upstream Istio's `demo` profile; confirm with `oc get pods -n istio-system
   --show-labels` once live and adjust `openshift/wasmplugin.yaml` if it
   differs.
3. **Istio↔minikube Kubernetes skew** (`istio-install.sh`) — Part 5 pins
   Kubernetes 1.37.1, one minor past Istio 1.31's documented 1.32–1.36 ceiling;
   gated on `istioctl x precheck`, may require re-pinning minikube's version
   for this chapter.

## Static validation (this BUILD pass)

- `bash -n` every `*.sh`; all chmod 755.
- `kubectl kustomize overlays/minikube | kubeconform -strict -kubernetes-version
  1.37.1 -ignore-missing-schemas` — the Deployment/Service/RuntimeClass/
  Namespace/Ingress built-in kinds validate; `Gateway`/`VirtualService` are
  CRDs and are skipped (no built-in kubeconform schema), exactly like Part 5's
  own Istio-adjacent CRD instances. The overlay no longer contains a
  `WasmPlugin` or a sidecar-injection namespace patch — the gateway-level
  WasmPlugin (`./gateway-wasmplugin.yaml`) is a separate, standalone file
  applied directly into `istio-system`, not part of this kustomize tree.
- `kubeconform -strict -kubernetes-version 1.37.1 -ignore-missing-schemas`
  against the standalone CRD-instance files (`gateway-wasmplugin.yaml`,
  `openshift/wasmplugin.yaml`, `openshift/gateway.yaml`,
  `openshift/virtualservice.yaml`) and `openshift/route.yaml` (a real
  `route.openshift.io/v1` kind, also no built-in schema under this validator,
  also skipped) — these are not part of a kustomize tree.

No cluster is started or touched by this pass.

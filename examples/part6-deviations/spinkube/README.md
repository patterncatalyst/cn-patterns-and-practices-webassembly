# ch26 — SpinKube (Spin on Kubernetes, via the full platform)

Deploys the ch26 Spin app (`../spin`) onto minikube through the complete
SpinKube stack — cert-manager, runtime-class-manager, the
`containerd-shim-spin` node shim, and the spin-operator — rather than Part 5's
manual containerd-shim-wasmtime RuntimeClass or Part 4's wasmCloud host. Same
minikube profile as Part 5 (`part5`, docker driver, containerd runtime); this
is a second, independent workload layered onto it, the way ch25's Istio
deviation shares the profile instead of standing up a second cluster.

## Why a different shim

The ch26 app (`../spin/cargo-spin.wasm`) is built with `spin-sdk = "=7.0.0"`
and exports `wasi:http/handler@0.3.0` (wasip3) — a newer ABI than the
`wasi:http/incoming-handler@0.2.x` world Parts 2-5's Component Model app
targets. `containerd-shim-spin` embeds Spin itself as its runtime, and only
`v0.26.0` and later embed Spin `4.1.0`, which understands that ABI. An older
shim build would schedule the Pod but the trigger inside it would not
recognize the component's exports.

## Pinned versions

| Component | Version | Source |
|---|---|---|
| cert-manager | v1.21.2 (fallback v1.20.0) | static manifest |
| runtime-class-manager | 0.2.0 | `oci://ghcr.io/spinframework/charts/runtime-class-manager` |
| containerd-shim-spin | v0.26.0 | runtime-class-manager Shim manifest |
| spin-operator | 0.6.1 | `oci://ghcr.io/spinframework/charts/spin-operator` |
| minikube / Kubernetes / ingress-nginx | v1.39.0 / v1.37.1 / v1.15.1 | reused from Part 5 |

cert-manager is a spin-operator webhook prerequisite: the operator chart
provisions its webhook's serving certificate through a cert-manager
`Certificate`. `install-spinkube.sh` installs v1.21.2 first and proves the
webhook actually admits that `Certificate` with a throwaway self-signed smoke
test (not just that the Pods report Ready); if that fails — an API skew
between cert-manager and spin-operator v0.6.1's webhook — it falls back to
v1.20.0 and reports on stdout which version is actually running.

## Objects this creates

- `RuntimeClass wasmtime-spin-v2` — provisioned by runtime-class-manager once
  `containerd-shim-spin` is installed on a node labeled `spin=true`.
- `SpinAppExecutor containerd-shim-spin` — ships with
  `spin-operator.shim-executor.yaml`; `SpinApp.spec.executor` references it by
  name.
- `SpinApp cargo-spin` (namespace `part6-spin`) — the operator reconciles it
  into a `Deployment cargo-spin` and a `Service cargo-spin` (port 80), the same
  name/port pairing SpinKube's own quickstart documents.
- `Ingress cargo-spin` — ingress-nginx, patched live to
  `cargo-spin.<minikube-ip>.nip.io`.

## Deploy + verify

```
# full run: starts/reuses the part5 minikube profile, builds + pushes the
# Spin OCI artifact, installs the stack, deploys, proves it live, tears the
# profile down
./verify-spinkube-minikube.sh

# leave the profile running afterwards (e.g. to layer another chapter on it)
./verify-spinkube-minikube.sh --keep
```

Manual steps, in order:

```
../spin/build.sh --push                 # builds + pushes ghcr.io/patterncatalyst/cargo-spin:spinkube
./install-spinkube.sh                   # cert-manager, runtime-class-manager + shim, spin-operator, ghcr-pull secret
kubectl kustomize overlays/minikube      # inspect the rendered manifests
kubectl apply -k overlays/minikube
```

The live proof goes through the real ingress edge — no port-forward, no
NodePort, no `minikube service`:

```
curl -> cargo-spin.<minikube-ip>.nip.io  (ingress-nginx)
     -> Service cargo-spin:80            (spin-operator)
     -> Pod (runtimeClassName: wasmtime-spin-v2)
     -> containerd-shim-spin             (Spin's own HTTP trigger)
     -> cargo-spin.wasm                  (wasi:http/handler@0.3.0)
```

`GET /cargo/CARGO-USNYC-DEHAM` returns the cargo JSON; `GET /cargo/NOPE`
returns 404.

## Evidence + teardown

`./capture-evidence.sh` runs the same flow headlessly and commits versions,
the RuntimeClass, the SpinApp/Deployment/Service/Ingress, the live HTTP proof,
and the component's sha256 to `evidence/<date>/`, scrubbed of credential
material. It does not tear anything down.

`./teardown.sh` removes the app, spin-operator, runtime-class-manager (and the
RuntimeClass), and cert-manager, leaving the minikube profile running for
another example. Pass `--delete-profile` to also delete the profile.

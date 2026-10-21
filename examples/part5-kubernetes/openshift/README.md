# Part 5 on OpenShift Local (CRC) — the wasmCloud operator path

This is the OpenShift counterpart to the minikube deploy one directory up
(`../k8s`, which uses a node-level containerd Wasm shim + a `RuntimeClass`). On
OpenShift the shim path needs a privileged RHCOS `MachineConfig` to install
`containerd-shim-wasmtime` on the node, and that fights the `restricted-v2`
security posture. So here we take the other supported route: run an **in-cluster
wasmCloud host** managed by the **wasmCloud operator**, and deploy the SAME
`app.wasm` onto it as a wadm OAM application.

```
app.wasm (ghcr, private)  ──host pulls──▶  wasmCloud host pod (operator-managed)
                                               │ httpserver provider :8000
   wadm Application (daemonscaler)             ▼
   ─ operator creates ─▶  Service cargo-http:8000  ◀─ edge-TLS Route ◀─ curl --cacert
```

The deployed component is **byte-for-byte** the component Parts 2/3/4 build and
run (`sha256 eff7f5ee…`). `contracts/wit` is untouched; nothing here forks or
edits an interface.

## Run order (headless)

```bash
eval "$(crc oc-env)"
./openshift/install-operator.sh   # nats + wadm + operator (pinned chart)
./openshift/deploy.sh             # push app.wasm to ghcr; host; wadm app; Route
./openshift/verify-crc.sh         # CA-verified curl through the Route: JSON + 404 + resilience
./openshift/capture-evidence.sh   # re-runs verify + records evidence/<date>/
./openshift/teardown.sh           # remove everything, then crc stop
```

The live bring-up/teardown of CRC itself is the operator's call:
`crc start` before, `teardown.sh` (`crc stop`) after.

## Pinned versions (surveyed live 2026-10-21)

| thing | pin | why |
| --- | --- | --- |
| platform chart | `oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2` | last tagged release of the wasmCloud **v1** chart (the operator repo is now archived; v2 uses the different `runtime-operator` chart + a different host/manifest model, not the `WasmCloudHostConfig` + OAM `v1beta1` model this project's Part 4 already uses). Bundles nats 1.2.3, wadm 0.2.7, operator 0.1.5 (image `ghcr.io/wasmcloud/wasmcloud-operator:0.4.0`), appVersion/host 1.2.1. |
| wasmCloud host | `1.9.1` (`WasmCloudHostConfig.spec.version`) | the host version Part 4 proved against provider `0.27.0`. The chart's default host (appVersion `1.2.1`) is too old for `http-server:0.27.0`'s wRPC protocol — invocations fail with `failed to shutdown synchronous parameter channel: not connected` (HTTP 500). Pinning `1.9.1` fixes it; it speaks `wasi:http` 0.2.x and runs our `wasi:http/incoming-handler@0.2.8` component. |
| httpserver provider | `ghcr.io/wasmcloud/http-server:0.27.0` | reused verbatim from `../../part4-runtimes/wasmcloud/wadm.yaml`. |
| component image | `ghcr.io/<owner>/cargo-http:crc` (private) | `app.wasm` pushed with `wash push`; the host pulls it with the `ghcr-pull` docker-registry secret. |

## restricted-v2 / SCC

Everything runs in the **`wasmcloud`** project (a normal project, so it is
governed by `restricted-v2`). The `default` namespace would NOT prove anything —
it is PodSecurity `privileged`.

- **wasmCloud host + NATS leaf:** the `WasmCloudHostConfig` CRD has **no**
  `securityContext` field, and the operator leaves the host/leaf containers'
  `securityContext` unset (confirmed in the operator's `controller.rs`) — so
  `restricted-v2` admission assigns a namespace-range UID, drops ALL
  capabilities, forbids privilege escalation, and defaults seccomp to
  `RuntimeDefault`. (`spec.schedulingOptions.podTemplateAdditions.spec` is the
  pod-level escape hatch if a future host image needs it; `containers` there is
  operator-managed.)
- **NATS + operator:** set no `runAsUser`, so `restricted-v2` assigns their UIDs
  — no override needed.
- **wadm:** the subchart hard-codes `securityContext.runAsUser/runAsGroup: 1000`,
  which is outside a restricted-v2 namespace's UID range and would be rejected.
  `values-crc.yaml` drops those two keys (so OpenShift assigns a UID in range)
  and keeps wadm's other good hardening (runAsNonRoot, drop ALL, no privilege
  escalation, seccomp RuntimeDefault).

No `anyuid`/`nonroot` SCC exception is granted anywhere — the whole stack runs
under `restricted-v2`.

## The daemonscaler edit

`wadm.yaml` is the Part 4 manifest with one operator-specific change: both the
component and the httpserver provider use a **`daemonscaler`** instead of a
`spreadscaler`. The operator only auto-creates a Kubernetes Service for an app
whose httpserver provider is scaled with a daemonscaler (spreadscaler Service
creation is not implemented). The Service is named after the Application
(`cargo-http`) and exposes the provider's listen port (`8000`); `deploy.sh` puts
an edge-TLS Route in front of it.

## The CA-verified curl (no -k, no port-forward, no NodePort)

Every HTTP assertion goes through the edge-TLS Route and is verified against the
cluster's own ingress CA, combined with the system trust store:

```bash
# combined bundle = system trust store + the cluster ingress CA
oc get configmap default-ingress-cert -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}'   # appended to /etc/ssl/certs/ca-certificates.crt
curl --cacert <combined-bundle> https://cargo-http-wasmcloud.apps-crc.testing/cargo/CARGO-USNYC-DEHAM
```

The ingress CA **alone** is not enough — any other TLS the scripts do (e.g.
reaching ghcr) would then fail `UnknownIssuer`. `lib.sh:combined_ca_bundle`
builds the combined bundle; `verify-crc.sh` and `capture-evidence.sh` use it.

## What `verify-crc.sh` proves (live)

1. Readiness is a real **200** through the Route (the router reconciles its
   backend *after* the pod is Ready — "pod Ready" is not "serving").
2. `GET /cargo/CARGO-USNYC-DEHAM` returns the **exact** cargo JSON (the same
   bytes `wasmtime serve` / wasmCloud / the minikube shim serve).
3. `GET /cargo/NOPE` returns **404**.
4. **Resilience:** delete the host pod; the operator's Deployment recreates it
   and traffic recovers to 200 with no redeploy.

## Namespace

The upstream v1 chart hard-codes NATS DNS at `*.default.svc.cluster.local`, but
we install in the dedicated **`wasmcloud`** project (for restricted-v2), so
`values-crc.yaml` repoints wadm's NATS server and `wasmcloud-host.yaml` repoints
the host/operator lattice `natsAddress` at `*.wasmcloud.svc.cluster.local`.
`teardown.sh` removes every resource, deletes the NATS JetStream PVCs (the CRC
hostpath storageclass uses `reclaimPolicy: Retain`), and deletes the project.

## Gotchas worth a chapter callout (all hit live on CRC 2026-10-21)

1. **OpenShift forbids the operator's manually-managed EndpointSlice (403).** The
   operator makes a selector-less Service and writes an EndpointSlice pointing at
   the host pod IP; OpenShift's `RestrictedEndpointsAdmission` rejects a
   cluster-network endpoint address unless the SA holds
   `endpoints(slices)/restricted`. Symptom: the app's Service has no endpoints and
   the Route 503s; the operator logs `endpointslices ... "cargo-http" is
   forbidden: endpoint address X is not allowed`. Fix: the narrow ClusterRole in
   `install-operator.sh` (a network-RBAC grant, not an SCC exception).
2. **Host/provider wRPC version skew.** The chart's default host (`1.2.1`) is too
   old for `http-server:0.27.0`: the Route returns 200-reachable but the provider
   can't invoke the component — HTTP 500, `failed to shutdown synchronous
   parameter channel: not connected`. Pin the host to `1.9.1` (Part 4's proven
   pairing) in `wasmcloud-host.yaml`.
3. **NATS must be standalone on one node.** `cluster.enabled: true` (the chart
   default) makes NATS block on `Waiting for routing to be established` forever
   and JetStream never elects a meta leader (startup probe 503s). Set
   `nats.config.cluster.enabled: false`.
4. **nats-box CrashLoops under restricted-v2** (`can't cd to /root: Permission
   denied`) and would hang `helm --wait`. It is a debug-only sidecar — disable it
   (`nats.natsBox.enabled: false`).
5. **The OAM Application must be applied in the namespace that has the
   WasmCloudHostConfig.** The operator serves `Application` via an aggregated API
   and maps namespace → lattice via the HostConfig there. Apply it anywhere else
   (e.g. `default`) and it fails with `unable to initialize nats client`.
6. **`default` namespace is PodSecurity `privileged`** — deploying there does not
   prove restricted-v2. Use a normal project.
7. **Readiness is a real 200, not pod-Ready.** The HAProxy router reconciles its
   backend *after* the host pod is Ready; a curl in that window 503s.
8. **Teardown must delete the stale OAM APIService.** The operator registers an
   aggregated `v1beta1.core.oam.dev` APIService; after `helm uninstall` its
   backing Service is gone, discovery fails, and that STALLS namespace deletion
   (`NamespaceDeletionDiscoveryFailure`). `teardown.sh` deletes the APIService
   before the project.

## Evidence

`evidence/<YYYY-MM-DD>/` (committed): `00-versions`, `01-pods`,
`02-service-route`, `03-http`, `04-verify-crc.log`, `05-sha256`, `06-scrub`.

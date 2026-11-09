---
title: "Deploying on OpenShift Local (CRC)"
order: 19
part: "Deploying to Kubernetes"
description: "Deploying the cargo wasi:http component to OpenShift Local with the wasmCloud operator under restricted-v2, exposed through a CA-verified edge-TLS Route."
duration: "17 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why OpenShift Local doesn't run the raw containerd shim, and why the wasmCloud operator fits `restricted-v2`.
- Say which field makes the operator create a Kubernetes Service, and which field pins the host version against a provider's wRPC protocol.
- Name the one `values-crc.yaml` edit `restricted-v2` forces on the bundled `wadm` subchart.
- Diagnose a 403 on an operator-managed `EndpointSlice` as a network-RBAC gap rather than a missing SCC exception, and apply the grant that closes it.
- Trace a CA-verified `curl` through an edge-TLS Route, a selector-less Service and the `httpserver` provider into the same `app.wasm` export the other runtimes serve.

## Why this matters

The raw containerd shim needs `containerd-shim-wasmtime-v1` on the node and a new runtime in `/etc/containerd/config.toml`. On minikube that is `minikube ssh`, a root shell and a containerd restart. OpenShift Local runs Red Hat CoreOS nodes whose filesystem the Machine Config Operator manages. Installing a runtime plugin there means authoring a `MachineConfig`, which needs a privileged node role CRC doesn't grant an ordinary user and which bounces the single node to apply. That is a lot of node surgery for one HTTP component, and it fights `restricted-v2`.

The wasmCloud operator avoids it. The host that runs `app.wasm` is an ordinary Deployment, admitted by `restricted-v2` like any other Pod, with no node change. Same component, same contract.

{% include excalidraw.html file="19-crc-request-path" alt="A CA-verified curl to cargo-http-wasmcloud.apps-crc.testing passes through the OpenShift router, which terminates an edge-TLS Route, into a selector-less Service named cargo-http on port 8000. An EndpointSlice the wasmCloud operator wrote by hand points at a wasmCloud host Pod running under restricted-v2 at UID 1000670000. Inside that Pod the httpserver capability provider listens on 0.0.0.0:8000 and invokes the cargo-http component's wasi:http/incoming-handler export over wRPC. A note says the whole path runs in a normal restricted-v2 namespace with no anyuid exception." caption="Figure 19.1: The CRC request path: edge-TLS Route to a selector-less Service to the wasmCloud host Pod to the httpserver provider to the same app.wasm export, all under restricted-v2." %}

## What the chart installs

`install-operator.sh` installs one Helm release, `oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2`, into a dedicated `wasmcloud` project. It is a normal project and not `default`, because `default` runs under the `privileged` pod security profile and proves nothing about `restricted-v2`. The chart bundles NATS (the lattice's message bus), `wadm` (the control loop that reconciles OAM applications) and the operator (which turns a `WasmCloudHostConfig` into a host Deployment).

`0.1.2` is the last tagged release of the archived wasmCloud v1 chart line. The v2 rewrite uses a different `runtime-operator` model with its own host and manifest shapes, and the `WasmCloudHostConfig` plus OAM `v1beta1` model is the one the single-host wasmCloud deploy already speaks. `lib.sh` pins three versions:

| Pin | Value |
| --- | --- |
| Chart | `oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2` |
| Operator image | `ghcr.io/wasmcloud/wasmcloud-operator:0.4.0` |
| `httpserver` provider | `ghcr.io/wasmcloud/http-server:0.27.0` |

The chart's host subchart defaults to version `1.2.1`, and `wasmcloud-host.yaml` overrides it to `1.9.1`. The default host speaks a wRPC protocol too old for `http-server:0.27.0`: the Route is reachable, the provider forwards the call, and the host answers `HTTP 500` with `failed to shutdown synchronous parameter channel: not connected`. `1.9.1` is the host already proven against this provider tag, so the CR pins it by name rather than trusting the chart's next default.

## restricted-v2: one edit

Every Pod in the release lands under `restricted-v2`: no `anyuid`, a namespace-assigned UID, capabilities dropped, privilege escalation forbidden, seccomp `RuntimeDefault`. The recorded Pods show one assigned UID across all five workloads (the columns are Pod, ready, restarts, SCC, UID):

```
nats-0                                true,true   0,0        restricted-v2   1000670000
wadm-57f596d4ff-xqvhc                 true        2          restricted-v2   1000670000
wasmcloud-host-6c5f6c5f88-mbw4k       true,true   0,0        restricted-v2   1000670000
wasmcloud-host-6c5f6c5f88-p5mm4       true,true   0,0        restricted-v2   1000670000
wasmcloud-operator-7f6d8c99bf-hjfms   true        0          restricted-v2   1000670000
namespace uid-range: 1000670000/10000
```

The `WasmCloudHostConfig` CRD has no `securityContext` field, and the operator leaves the host and its NATS leaf sidecar unset, so admission fills in the UID, drops capabilities and forbids escalation. NATS and the operator set no `runAsUser` either.

Only `wadm`'s subchart fought the default. It hard-codes `securityContext.runAsUser: 1000` and `runAsGroup: 1000`, fixed values outside the namespace's `1000670000` range, so admission rejects them instead of reassigning. `values-crc.yaml` nulls both keys:

```yaml
wadm:
  wadm:
    config:
      nats:
        server: "nats://nats-headless.wasmcloud.svc.cluster.local"
  securityContext:
    # Drop the chart's fixed UID/GID so restricted-v2 assigns one in range.
    runAsUser: null
    runAsGroup: null
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - "ALL"
    seccompProfile:
      type: RuntimeDefault
```

Nulling the two UID keys, rather than removing the block, keeps `wadm`'s other hardening (`runAsNonRoot`, dropped capabilities, seccomp) in place.

The overlay has a second job. The chart hard-codes NATS's DNS at `*.default.svc.cluster.local`, so installing into `wasmcloud` means repointing every NATS address at `*.wasmcloud.svc.cluster.local`. `values-crc.yaml` does it for `wadm`, and the `natsAddress` field in `wasmcloud-host.yaml` does it for the host.

## WasmCloudHostConfig and the daemonscaler

{% include excalidraw.html file="19-operator-lattice-topology" alt="install-operator.sh installs the pinned wasmcloud-platform chart, bringing up standalone NATS, wadm with runAsUser and runAsGroup nulled, and the wasmCloud operator, all under restricted-v2. deploy.sh pushes app.wasm to ghcr and creates a pull secret, then applies a WasmCloudHostConfig pinned to host version 1.9.1, which the operator reconciles into a host Deployment. Applying wadm.yaml, an OAM Application where both the component and the httpserver provider carry a daemonscaler trait rather than a spreadscaler, makes the operator create a Service named cargo-http on port 8000." caption="Figure 19.2: The operator and lattice topology: the chart brings up NATS, wadm and the operator; a WasmCloudHostConfig becomes a host Deployment; a daemonscaler-traited wadm Application makes the operator create the Service." %}

`deploy.sh` applies `wasmcloud-host.yaml` once the chart is up:

```yaml
apiVersion: k8s.wasmcloud.dev/v1alpha1
kind: WasmCloudHostConfig
metadata:
  name: wasmcloud-host
  namespace: wasmcloud
spec:
  hostReplicas: 1
  lattice: default
  version: "1.9.1"
  natsAddress: nats://nats.wasmcloud.svc.cluster.local
  registryCredentialsSecret: ghcr-pull
  allowLatest: false
```

The operator reconciles the CR into a Deployment of the same name, so `deploy.sh` waits on `oc get deploy wasmcloud-host` rather than on a Pod. `registryCredentialsSecret` names a `docker-registry` secret `deploy.sh` builds from `gh auth token`: the component image is private, pushed with `wash push` to `ghcr.io/patterncatalyst/cargo-http:crc` before the host starts.

`deploy.sh` then applies `wadm.yaml`, the single-host manifest with one operator-specific change: both the component and the provider use a `daemonscaler` instead of a `spreadscaler`. The provider's half:

```yaml
    - name: httpserver
      type: capability
      properties:
        # Reused verbatim from part4-runtimes/wasmcloud/wadm.yaml: the latest
        # released HTTP server provider, speaks wasi:http 0.2.x, compatible with
        # the host versions in this project.
        image: ghcr.io/wasmcloud/http-server:0.27.0
      traits:
        # The provider (source) calls the component (target) on
        # wasi:http/incoming-handler; source_config carries the listen address.
        # On Kubernetes with the operator the port is configurable but the
        # address MUST be 0.0.0.0.
        - type: link
          properties:
            target: cargo-http
            namespace: wasi
            package: http
            interfaces:
              - incoming-handler
            source_config:
              - name: cargo-http-listen
                properties:
                  address: 0.0.0.0:8000
        # daemonscaler on the httpserver provider is what makes the operator
        # create the Service (named "cargo-http", port 8000).
        - type: daemonscaler
          properties:
            replicas: 1
```

The edit is required. The operator creates a Kubernetes Service only for an application whose `httpserver` provider uses a `daemonscaler`; Service creation for a `spreadscaler` provider isn't implemented. Skip it and `wadm` still reconciles, the component and provider still link, and `wadm status` looks fine, but there is no Service for a Route to point at. `deploy.sh`'s wait on `oc get svc cargo-http` times out with nothing upstream to explain why.

The Service is named after the Application and exposes the provider's listen port:

```
--- Service (operator-created) ---
SVC          TYPE        PORT   SELECTOR
cargo-http   ClusterIP   8000   <none>
--- Route (edge TLS) ---
ROUTE        HOST                                    TERMINATION   PORT
cargo-http   cargo-http-wasmcloud.apps-crc.testing   edge          8000
```

`SELECTOR <none>` is correct. The operator writes an `EndpointSlice` by hand that points at the host Pod's IP, because the lattice, not a Deployment label, knows which host serves the application.

## The EndpointSlice 403

That hand-written `EndpointSlice` is what the first live run hit. OpenShift's `RestrictedEndpointsAdmission` plugin rejects any `Endpoints` or `EndpointSlice` whose address falls inside the cluster or service network unless the creating ServiceAccount holds the `restricted` permission. The check stops a workload from spoofing traffic as another Pod. The operator's selector-less Service does exactly what it guards against, for a legitimate reason.

The fix is network RBAC, not an SCC exception or `anyuid`. `install-operator.sh` applies a narrow `ClusterRole` and binds it to the `wasmcloud-operator` ServiceAccount:

```yaml
- apiGroups: [""]
  resources: ["endpoints/restricted"]
  verbs: ["create", "update"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices/restricted"]
  verbs: ["create", "update"]
```

Without it the Service has no endpoints and the Route answers `503`, with nothing in the operator's status to say why. The rejection shows only in the operator's logs, as `endpointslices ... "cargo-http" is forbidden: endpoint address X is not allowed`.

## The edge-TLS Route and the CA-verified curl

`deploy.sh` puts an edge-terminated Route in front of the Service. Edge termination suffices for a plain HTTP backend and needs no certificate in the Pod. The script polls the real path until it returns a real `200`, because the router wires a new backend some time after the backend is reachable.

`verify-crc.sh` never uses `-k`, `oc port-forward` or a NodePort. OpenShift Local signs the router's certificate from the cluster's own ingress CA, which is in no public trust store. `combined_ca_bundle` in `lib.sh` extracts that CA from the `default-ingress-cert` ConfigMap in `openshift-config-managed` and appends it to the host's system trust store before handing the file to `curl --cacert`. Appending matters: a bundle holding only the ingress CA verifies the Route and then fails `UnknownIssuer` on the next connection to a public endpoint.

```
# CA-verified against the cluster ingress CA (curl --cacert combined-bundle), never -k, never port-forward.
$ curl --cacert <ingress-ca> https://cargo-http-wasmcloud.apps-crc.testing/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -o /dev/null -w %{http_code} https://cargo-http-wasmcloud.apps-crc.testing/cargo/NOPE
404
```

The JSON and the 404 for an unknown id match every other runtime, and the recorded sha256 of the deployed `app.wasm` matches the one `wasmtime serve`, the single-host lattice and the minikube shim run:

```
eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3  <repo>/examples/part5-kubernetes/openshift/../app.wasm
MATCHES Part 2/3/4 expected sha256
```

Four runtimes serve one component, never recompiled.

`verify-crc.sh` also deletes the running host Pod and confirms the operator's Deployment recreates it, with traffic back to the exact cargo JSON and no redeploy:

```
    deleting host pod wasmcloud-host-6c5f6c5f88-mbw4k ...
    ✓ Route serving (HTTP 200) on /cargo/CARGO-USNYC-DEHAM after 0s
    ✓ host pod recreated by the operator Deployment; traffic recovered to the exact cargo JSON
```

That is the Kubernetes Deployment restarting a Pod, a separate mechanism from `wadm`'s own reconcile loop recovering a crashed component on a host. Both exist in this stack, at different layers.

## Four more issues from the live run

None showed up in `helm template` or a YAML check.

- **NATS must be standalone.** The chart default `cluster.enabled: true` makes a single-node NATS block on "waiting for routing to be established" to peers that never exist, so JetStream never elects a meta leader and the readiness probe never passes. `values-crc.yaml` sets `nats.config.cluster.enabled: false`.
- **`nats-box` CrashLoops.** Its entrypoint assumes a writable home directory, so under `restricted-v2` it fails with `can't cd to /root: Permission denied`. It is a debug-only sidecar, disabled with `nats.natsBox.enabled: false`.
- **Apply `wadm.yaml` in `wasmcloud`.** The operator serves `Application` objects through an aggregated API that maps a namespace to a lattice through the `WasmCloudHostConfig` in that namespace. Anywhere else fails with `unable to initialize nats client`, a message that doesn't mention namespaces.
- **Teardown deletes the OAM APIService first.** After `helm uninstall` removes the Service behind the operator's aggregated `v1beta1.core.oam.dev` APIService, API discovery fails, and namespace deletion stalls with `NamespaceDeletionDiscoveryFailure`. `teardown.sh` deletes the stale APIService before the project.

> **Decision**
>
> Use the wasmCloud operator, not a node-level shim, when the cluster enforces `restricted-v2` and you don't control node images. Within that choice: scale the `httpserver` provider with a `daemonscaler` or the operator creates no Service; pin the `WasmCloudHostConfig` version instead of trusting the chart default, because a host and provider wRPC mismatch surfaces as a runtime 500; and give the operator's ServiceAccount the `endpoints(slices)/restricted` grant, a network-RBAC decision and never an `anyuid` exception. Verify through the real Route with a CA-verified `curl`, because a Service with no endpoints looks healthy until something reaches it.

## Build, run, observe

With CRC running (`crc start`; one cluster at a time) and `eval "$(crc oc-env)"` applied:

```bash
cd examples/part5-kubernetes
./openshift/install-operator.sh   # nats + wadm + operator (pinned chart)
./openshift/deploy.sh             # push app.wasm to ghcr; host; wadm app; Route
./openshift/verify-crc.sh         # CA-verified curl: JSON, 404, resilience
./openshift/teardown.sh           # remove everything, then crc stop
```

`verify-crc.sh` waits for a real 200 from the Route, then checks `GET /cargo/CARGO-USNYC-DEHAM` for the exact cargo JSON and `GET /cargo/NOPE` for 404, both against the cluster's ingress CA. It then deletes the host Pod and confirms recovery. Expect `PASS` after all four checks. `./openshift/capture-evidence.sh` re-runs the verification and records `evidence/<date>/`.

- Change `daemonscaler` to `spreadscaler` on the provider: no Service appears and `deploy.sh` times out waiting for it.
- Remove the `endpoints(slices)/restricted` grant: the Service has no endpoints and the Route returns 503; the operator log shows the 403.
- Drop the `version: "1.9.1"` pin: the chart's `1.2.1` host answers HTTP 500 with the wRPC error.
- Remove the null `runAsUser` and `runAsGroup` keys: admission rejects `wadm`.
- Apply `wadm.yaml` outside `wasmcloud`: `unable to initialize nats client`.

## For deeper coverage

- Bilgin Ibryam and Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the operator pattern behind the `WasmCloudHostConfig` reconcile loop, a custom resource as desired state and a controller that turns it into ordinary objects.
- Brendan Burns, Joe Beda, Kelsey Hightower and Lachlan Evenson, *Kubernetes: Up and Running*, 3rd ed. (O'Reilly, 2022): the Service, EndpointSlice and admission model behind the selector-less Service, and the SCC and PodSecurity reasoning `restricted-v2` applies.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): why one component runs unmodified under a containerd shim, `wasmtime serve` or an operator-managed wasmCloud host, since none can see past its WIT exports.
- *Cloud Native Design Patterns*, "Running Example 05 on OpenShift Local": the same OperatorHub, `restricted-v2` and edge-TLS Route shape against a different example.
- [wasmCloud Kubernetes operator documentation](https://wasmcloud.com/docs/deployment/k8s/operator): the `WasmCloudHostConfig` CRD and OAM Application model.
- [OpenShift restricted-v2 SCC reference](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html): the UID-range assignment and capability dropping every Pod here lands under.
- Wasm on Kubernetes: the landscape that makes the operator the fallback when the shim doesn't fit.
- Deploying on minikube: the same component on the raw containerd shim and ingress-nginx.

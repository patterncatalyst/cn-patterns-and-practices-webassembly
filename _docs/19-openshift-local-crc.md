---
title: "Deploying on OpenShift Local (CRC)"
order: 19
part: "Deploying to Kubernetes"
description: "Deploying the same cargo wasi:http component to OpenShift Local via the wasmCloud operator, under restricted-v2, exposed through a CA-verified edge-TLS Route."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why OpenShift Local does not run Chapter 18's raw containerd shim path, and why the wasmCloud operator is the mechanism that fits `restricted-v2` instead.
- Read `examples/part5-kubernetes/openshift/wasmcloud-host.yaml` and `wadm.yaml` together and state which field makes the operator create a Kubernetes Service, and which field pins the host version against a provider's wRPC protocol.
- Name the one `values-crc.yaml` edit `restricted-v2` forces on the chart's bundled `wadm` subchart, and why nothing else in the chart needs an edit at all.
- Diagnose a 403 on an operator-managed `EndpointSlice` as a narrow network-RBAC gap, not a missing SCC exception, and state the exact grant that closes it.
- Trace the live request path from a CA-verified `curl` through an edge-TLS Route, a selector-less Service, the `httpserver` capability provider, and into the same `app.wasm` export Chapters 14, 15, and 18 already proved.

## Why this matters

Chapter 17 placed the wasmCloud operator on a landscape of four ways to run a Wasm component on Kubernetes, and named it the fallback path for a cluster where the raw containerd shim doesn't fit. Chapter 18 proved the shim path live on minikube. This chapter is where that fallback stops being theoretical: on OpenShift Local, the shim path is not merely less convenient, it is the wrong tool, and the operator is the one that is live-verified here.

The reason is `restricted-v2`. Chapter 18's shim needs `containerd-shim-wasmtime-v1` installed as a binary on the node and registered as a new CRI runtime in `/etc/containerd/config.toml`, which on minikube means `minikube ssh`, a root shell, and a containerd restart: ordinary node administration on a cluster you fully control. OpenShift Local runs Red Hat CoreOS (RHCOS) nodes whose filesystem is managed by the Machine Config Operator, not edited by hand; installing a new containerd runtime plugin there means authoring a `MachineConfig`, which needs a privileged node role CRC does not grant to an ordinary user session, and which bounces the entire single node to apply. That is a disproportionate amount of node surgery to run one HTTP component, and it fights the whole `restricted-v2` posture this book's OpenShift path otherwise keeps intact everywhere else. The wasmCloud operator sidesteps the question entirely: the host that runs `app.wasm` is an ordinary Deployment, admitted by `restricted-v2` like any other pod, with no node-level change at all. Same component, same contract, a completely different answer to what has to change about the node.

`examples/part5-kubernetes/openshift/` is that path, run live: **verified live 2026-10-21 (CRC 2.64.0 / OpenShift 4.22.14 / wasmcloud host 1.9.1)**, with evidence committed under `examples/part5-kubernetes/openshift/evidence/2026-10-21/`. Every command, every version pin, and every byte of JSON quoted below comes from that run, not from reading the manifests and assuming what they do.

{% include excalidraw.html file="19-crc-request-path" alt="A CA-verified curl request to cargo-http-wasmcloud.apps-crc.testing flows through the OpenShift router terminating an edge-TLS Route, into a selector-less Service named cargo-http on port 8000, whose endpoints an EndpointSlice the wasmCloud operator wrote by hand points at a wasmCloud host pod running under restricted-v2 at UID 1000670000. Inside that pod the httpserver capability provider listens on 0.0.0.0:8000 and invokes the cargo-http component's wasi:http/incoming-handler export over wRPC. A note states the whole path runs in the wasmcloud project, a normal restricted-v2 namespace, with no anyuid exception anywhere." caption="Figure 19.1: the live CRC request path: edge-TLS Route to a selector-less Service to the wasmCloud host pod to the httpserver provider to the same app.wasm export, all under restricted-v2." %}

## The operator, not the shim: what the chart actually installs

`install-operator.sh` installs one Helm release, `oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2`, into a dedicated `wasmcloud` project: a normal OpenShift project, not `default`, because the `default` namespace runs under the `privileged` pod security profile and deploying there would prove nothing about `restricted-v2`. That chart bundles three things: NATS (the message bus the lattice runs on), `wadm` (the control loop that reconciles OAM applications), and the wasmCloud operator itself (the controller that turns a `WasmCloudHostConfig` custom resource into a running host Deployment). `README.md` in that directory records why this chart specifically: it is `0.1.2`, the last tagged release of the archived wasmCloud **v1** chart line. wasmCloud's v2 rewrite ships a different chart under a different `runtime-operator` model with its own host and manifest shapes; Part 4 of this book already committed to the `WasmCloudHostConfig` plus OAM `v1beta1` model the v1 chart speaks, and switching models here would mean maintaining two incompatible deployment stories for the same lattice concept. The v1 chart is the one that matches every other chapter in Part 4 and Part 5.

Three version pins hold this chart together, all recorded in `lib.sh` and confirmed by `evidence/2026-10-21/00-versions.txt`:

```
CRC version: 2.64.0+458092
OpenShift version: 4.22.14
--- helm release ---
NAME                NAMESPACE   REVISION   STATUS     CHART                       APP VERSION
wasmcloud-platform  wasmcloud   1          deployed   wasmcloud-platform-0.1.2    1.2.1
--- chart pin: oci://ghcr.io/wasmcloud/charts/wasmcloud-platform:0.1.2 ---
--- operator image ---
ghcr.io/wasmcloud/wasmcloud-operator:0.4.0
--- wasmCloud host version (WasmCloudHostConfig) ---
version=1.9.1
--- httpserver provider tag (wadm) ---
  image: ghcr.io/wasmcloud/http-server:0.27.0
```

The chart's own `APP VERSION` column reads `1.2.1`. That is the bundled host subchart's default version, and it is not the version this deployment runs: `wasmcloud-host.yaml`'s `WasmCloudHostConfig` overrides it to `1.9.1` explicitly, and that override matters, not as a cosmetic detail, because the chart's default host speaks a wRPC protocol too old for the `http-server:0.27.0` provider this app links against. Pairing the chart's own default host with that provider produces a Route that is reachable but a backend that cannot invoke the component: the provider forwards the call and the host answers `HTTP 500`, `failed to shutdown synchronous parameter channel: not connected`, because the two sides are speaking incompatible wire versions of the same RPC. `1.9.1` is the host version Part 4's single-host wasmCloud chapter already proved against this exact provider tag, so `wasmcloud-host.yaml` pins it by name instead of trusting whatever the chart ships next.

## restricted-v2: one edit, and only one

Every pod this chart creates lands under `restricted-v2`, OpenShift's default security context constraint for an ordinary project: no `anyuid`, no fixed UID chosen by the workload, a namespace-scoped UID range assigned at admission, capabilities dropped to nothing, privilege escalation forbidden, seccomp set to `RuntimeDefault`. `evidence/2026-10-21/01-pods.txt` shows every single pod in the release landing on the identical assigned UID, with `restricted-v2` as the recorded SCC on each one:

```
nats-0                                true,true   0,0        restricted-v2   1000670000
wadm-57f596d4ff-xqvhc                 true        2          restricted-v2   1000670000
wasmcloud-host-6c5f6c5f88-mbw4k       true,true   0,0        restricted-v2   1000670000
wasmcloud-host-6c5f6c5f88-p5mm4       true,true   0,0        restricted-v2   1000670000
wasmcloud-operator-7f6d8c99bf-hjfms   true        0          restricted-v2   1000670000
namespace uid-range: 1000670000/10000
```

Five different workloads, NATS, `wadm`, two wasmCloud host replicas, and the operator itself, all land on the exact same platform-chosen UID, `1000670000`, out of a `1000670000/10000` namespace range, with no `anyuid` exception requested or granted anywhere. The `WasmCloudHostConfig` CRD has no `securityContext` field at all, and the operator's own reconciler leaves the host and its NATS leaf sidecar's `securityContext` unset in the pod spec it generates, so `restricted-v2` admission fills in the UID, drops the capabilities, and forbids escalation entirely on its own. The host author never had to reason about OpenShift's UID model for that pod to run.

Only one piece of the chart fought that default: `wadm`'s own subchart hard-codes `securityContext.runAsUser: 1000` and `runAsGroup: 1000`. `1000` is a plausible-looking UID, which is exactly what makes it dangerous here: it is a fixed value, and it sits well outside this namespace's `1000670000`-based range, so admission rejects it outright rather than silently reassigning it. `values-crc.yaml` nulls both keys:

```yaml
wadm:
  wadm:
    config:
      nats:
        server: "nats://nats-headless.wasmcloud.svc.cluster.local"
  securityContext:
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

Nulling the two UID keys, not removing the whole `securityContext` block, is the point: `wadm`'s own hardening (`runAsNonRoot`, dropped capabilities, `seccompProfile: RuntimeDefault`) was already correct and stays in place; only the two fields that collide with a namespace-assigned range come out. That is the entire security-context edit this chapter needed. NATS and the operator set no `runAsUser` of their own, so they never needed touching at all. `restricted-v2` was already the right fit for them, and the chart's defaults already matched a pattern Chapter 17's landscape discussion would predict: the operator model is built to run as ordinary pods because that is the whole reason it exists as an alternative to the shim.

The same `values-crc.yaml` overlay also exists because of a second namespace effect that has nothing to do with security contexts: the chart hard-codes NATS's DNS name at `*.default.svc.cluster.local`, and installing into `wasmcloud` instead of `default` (the same `restricted-v2`-vs-`privileged` reasoning as above) means every NATS address in the chart has to be repointed at `*.wasmcloud.svc.cluster.local`. `values-crc.yaml` does it for `wadm`'s NATS server; `wasmcloud-host.yaml`'s own `natsAddress` field does the matching repoint for the host-to-lattice connection.

## WasmCloudHostConfig, the daemonscaler, and the Service the operator builds

{% include excalidraw.html file="19-operator-lattice-topology" alt="install-operator.sh installs the pinned wasmcloud-platform chart, bringing up standalone NATS, wadm with its runAsUser/runAsGroup nulled, and the wasmCloud operator, all under restricted-v2. deploy.sh pushes app.wasm to ghcr and creates a pull secret, then applies a WasmCloudHostConfig pinned to host version 1.9.1, which the operator reconciles into a host Deployment. Applying wadm.yaml, an OAM Application where both the component and the httpserver provider carry a daemonscaler trait rather than a spreadscaler, is what makes the operator auto-create a Service named cargo-http on port 8000." caption="Figure 19.2: the operator/lattice topology: the pinned chart brings up NATS, wadm, and the operator; a WasmCloudHostConfig becomes a host Deployment; a daemonscaler-traited wadm Application is what makes the operator create the Service." %}

`deploy.sh` applies `wasmcloud-host.yaml` after the platform chart is up. The CR itself is short:

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

The operator reconciles that CR into a Deployment named after it, which is why `deploy.sh` waits on `oc get deploy wasmcloud-host` rather than on a pod directly: the CR is the desired state, the Deployment is the mechanism, and the pod is just the Deployment's own replica. `registryCredentialsSecret` points at a `docker-registry` secret `deploy.sh` creates from a `gh auth token`, because the component image this host pulls is private: `deploy.sh` pushes `app.wasm` to `ghcr.io/patterncatalyst/cargo-http:crc` with `wash push` before the host ever starts, and the pull secret is what lets the in-cluster host retrieve it without a public artifact existing anywhere.

Once the host is running, `deploy.sh` applies `wadm.yaml`, an OAM `Application` that is, by design, almost the same manifest Part 4's single-host wasmCloud chapter already deployed: the same component, the same `httpserver` provider at `ghcr.io/wasmcloud/http-server:0.27.0`, the same link wiring the provider's `wasi:http/incoming-handler` calls to the component. The one change this manifest makes for the operator path is the scaler type on both the component and the provider:

```yaml
spec:
  components:
    - name: cargo-http
      type: component
      properties:
        image: __COMPONENT_REF__
      traits:
        - type: daemonscaler
          properties:
            replicas: 1

    - name: httpserver
      type: capability
      properties:
        image: ghcr.io/wasmcloud/http-server:0.27.0
      traits:
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
        - type: daemonscaler
          properties:
            replicas: 1
```

`daemonscaler` in place of Part 4's `spreadscaler` is the whole operator-specific edit, and it is required, not stylistic: the wasmCloud operator only auto-creates a Kubernetes Service for an application whose `httpserver` provider is scaled with a `daemonscaler`. Service creation for a `spreadscaler`-scaled provider is not implemented in the operator at all. Skip this edit and `wadm`'s reconcile loop still succeeds, the component and provider still link, and nothing in `wadm status` looks wrong: there is simply no Service for a Route to ever point at, and `deploy.sh`'s wait on `oc get svc cargo-http` times out with no error anywhere upstream to explain why. The Service the operator creates once the `daemonscaler` is in place is named after the Application itself, `cargo-http`, and exposes the provider's configured listen port, `8000`. `evidence/2026-10-21/02-service-route.txt` shows exactly that Service, and one detail in it needs a closer look:

```
--- Service (operator-created) ---
SVC          TYPE        PORT   SELECTOR
cargo-http   ClusterIP   8000   <none>
--- Route (edge TLS) ---
ROUTE        HOST                                    TERMINATION   PORT
cargo-http   cargo-http-wasmcloud.apps-crc.testing   edge          8000
```

`SELECTOR <none>` is correct, not a bug: this Service has no label selector matching pods the way an ordinary Kubernetes Service would. The operator manages its routing by writing an `EndpointSlice` directly, pointing at the host pod's IP by hand, because the lattice, not a label on a Deployment, is what knows which host is serving this application. That design choice is also exactly what the next section's RBAC gap comes from.

<div class="callout callout--warn"><p class="callout__title">Gotcha</p><p>The first live run of this path 403'd on exactly that manually-written <code>EndpointSlice</code>. OpenShift's <code>RestrictedEndpointsAdmission</code> plugin rejects any <code>Endpoints</code>/<code>EndpointSlice</code> object whose address falls inside the cluster or service network unless the creating ServiceAccount holds the <code>endpoints(slices)/restricted</code> permission, a check that exists to stop a workload from spoofing traffic as if it originated from another pod on the cluster network. The operator's selector-less-Service pattern does exactly the thing that check exists to catch, for a legitimate reason, and the fix is not an SCC exception or <code>anyuid</code>: it is a narrow <code>ClusterRole</code> granting <code>create</code>/<code>update</code> on <code>endpoints/restricted</code> and <code>endpointslices.discovery.k8s.io/restricted</code>, bound to the <code>wasmcloud-operator</code> ServiceAccount. Without it the Service has a selector of <code>&lt;none&gt;</code> and zero endpoints, and the Route in front of it answers <code>503</code> with nothing in the operator's status to say why. The operator's own logs are the only place the rejection shows up, as <code>endpointslices ... "cargo-http" is forbidden: endpoint address X is not allowed</code>.</p></div>

## The edge-TLS Route and the CA-verified curl

`deploy.sh` puts an edge-terminated Route in front of that Service once it exists, the same Route type this book's OpenShift references use everywhere, because edge termination is sufficient for a plain HTTP backend and does not require the pod to carry its own TLS certificate. The script does not trust `oc rollout status` or a Service's existence as proof the Route is serving; it polls the real path until it returns a real `200`, because the router finishes wiring a new backend to a Route some interval after the backend itself becomes reachable, not simultaneously with it.

`verify-crc.sh`, run separately after `deploy.sh`, is where the proof happens, and it never uses `-k`/`--insecure`, `oc port-forward`, or a NodePort anywhere: house rule on every chapter in this book that touches a live cluster. OpenShift Local signs its router's certificate from the cluster's own ingress CA, which sits in no public trust store, so `lib.sh`'s `combined_ca_bundle` function extracts that CA directly from the `default-ingress-cert` ConfigMap in `openshift-config-managed` and appends it to the host's own system trust store before handing the result to `curl --cacert`. Appending rather than replacing matters: an ingress-CA-only bundle would verify the Route's own certificate correctly and then fail `UnknownIssuer` on the very first unrelated TLS connection the script makes to a public endpoint, because the ingress CA alone chains to nothing a public certificate trusts.

`evidence/2026-10-21/03-http.txt` is the live transcript of that CA-verified request:

```
# CA-verified against the cluster ingress CA (curl --cacert combined-bundle), never -k, never port-forward.
$ curl --cacert <ingress-ca> https://cargo-http-wasmcloud.apps-crc.testing/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -o /dev/null -w %{http_code} https://cargo-http-wasmcloud.apps-crc.testing/cargo/NOPE
404
```

That JSON is not a new behavior written for OpenShift. It is the exact tracking-id lookup this site's domain has returned since Part 2, the same `404`-for-an-unknown-id behavior, through the same `wasi:http/incoming-handler` export, and `evidence/2026-10-21/05-sha256.txt` confirms the component answering it is byte-for-byte the one every other runtime in this book has run:

```
eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3  .../app.wasm
MATCHES Part 2/3/4 expected sha256
```

`wasmtime serve` in Chapter 14, the single-host wasmCloud lattice in Chapter 15, the minikube shim in Chapter 18, and the OpenShift operator here are four different runtimes answering with four identical sets of bytes, `eff7f5ee…`, from one component, never recompiled or forked along the way.

`verify-crc.sh`'s full run, captured in `evidence/2026-10-21/04-verify-crc.log`, goes one step further than a single request: it deletes the running wasmCloud host pod mid-script and confirms the Deployment the operator manages recreates it, with traffic back to the exact cargo JSON, with no redeploy command run by hand:

```
==> 4/4 Resilience: delete the host pod; the Deployment restores it, traffic recovers
    deleting host pod wasmcloud-host-6c5f6c5f88-mbw4k ...
    ✓ Route serving (HTTP 200) on /cargo/CARGO-USNYC-DEHAM after 0s
    ✓ host pod recreated by the operator Deployment; traffic recovered to the exact cargo JSON

PASS — Part 5 cargo component on OpenShift Local (CRC, crc-admin context): deployed by the wasmCloud operator to an in-cluster host; served the exact cargo JSON and a 404 through an edge-TLS Route (CA-verified against the cluster's own ingress CA, never -k/port-forward/NodePort); and recovered after the host pod was deleted.
```

That resilience proof is a property of the ordinary Kubernetes Deployment the operator wrote, not of the wasmCloud lattice: `wadm`'s own self-healing reconcile loop, the one Chapter 15 showed recovering a crashed component on a single host in roughly two seconds, is a separate mechanism from the Kubernetes-level Deployment restarting a crashed pod shown here. Both exist in this stack, at different layers, and this chapter's live run exercised the Kubernetes one.

## The rest of what the live run hit, and fixed

Four more issues surfaced only once this ran against a real cluster, none of them visible from `helm template` or a YAML syntax check. NATS has to run standalone, not clustered: the chart's default `cluster.enabled: true` makes a single-node NATS server block forever on "waiting for routing to be established" to peers that will never exist, so JetStream never elects a meta leader and the readiness probe never passes. `values-crc.yaml` sets `nats.config.cluster.enabled: false`. The bundled `nats-box` debug sidecar CrashLoops under `restricted-v2` with `can't cd to /root: Permission denied`, because its entrypoint assumes a writable home directory an arbitrary assigned UID doesn't have; since it is a debug-only convenience nothing else in this chain depends on, `values-crc.yaml` disables it outright with `nats.natsBox.enabled: false`. The OAM Application itself is namespace-sensitive in a way that produces an unhelpful error if missed: the operator serves `Application` objects through an aggregated API that maps a namespace to a lattice via whichever `WasmCloudHostConfig` lives in that same namespace, so applying `wadm.yaml` anywhere other than `wasmcloud` fails immediately with `unable to initialize nats client` rather than any message naming a namespace mismatch. And `teardown.sh` has to delete the operator's own aggregated `v1beta1.core.oam.dev` APIService explicitly, before deleting the project: once `helm uninstall` removes the Service backing that APIService, cluster-wide API discovery starts failing against a registration that still exists, and that failure is specifically what stalls namespace deletion with `NamespaceDeletionDiscoveryFailure`. Deleting the stale APIService first is what lets the project actually finish terminating.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for the wasmCloud operator, not a node-level Wasm shim, whenever the target cluster enforces <code>restricted-v2</code> and you don't control node images. OpenShift Local is the concrete case here, but the same reasoning applies to any managed Kubernetes offering that won't grant a privileged node role for a containerd runtime plugin. The operator's host is an ordinary Deployment admitted like any other restricted-v2 workload; the shim needs node-level surgery that a managed platform is specifically designed to prevent. Within that choice, three things are non-negotiable: scale the httpserver provider with a <code>daemonscaler</code>, not a <code>spreadscaler</code>, or the operator never creates a Service at all; pin the <code>WasmCloudHostConfig</code> version explicitly rather than trusting the chart's bundled default, because a host/provider wRPC mismatch fails as a confusing runtime 500, not an install-time error; and grant the operator's ServiceAccount the narrow <code>endpoints(slices)/restricted</code> permission its hand-written EndpointSlice needs, which is a network-RBAC decision, never an SCC/<code>anyuid</code> exception. Verify every claim with a CA-verified <code>curl</code> through the real Route, never <code>-k</code>, never a port-forward, never a NodePort, because a Service with <code>SELECTOR &lt;none&gt;</code> and zero endpoints looks identical to a healthy one until something actually tries to reach it.</p></div>

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023): the operator pattern this chapter's `WasmCloudHostConfig` reconcile loop follows: a custom resource as desired state, a controller that turns it into ordinary Kubernetes objects, and the Service/EndpointSlice machinery that pattern relies on.
- Brendan Burns, Joe Beda, Kelsey Hightower & Lachlan Evenson, *Kubernetes: Up and Running*, 3rd ed. (O'Reilly, 2022): the Service/EndpointSlice and admission model behind the selector-less Service this chapter's operator writes by hand, and the SCC/PodSecurity reasoning `restricted-v2` applies at pod admission.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model guarantee this chapter leans on directly: a component built once can run unmodified under a containerd shim, a standalone `wasmtime serve` process, or an operator-managed wasmCloud host, because none of those runtimes can see past its WIT-defined exports.
- *Cloud Native Design Patterns*, "Running Example 05 on OpenShift Local" chapter: the same OperatorHub/`restricted-v2`/edge-TLS-Route shape this chapter applies, run against a different example.
- [wasmCloud Kubernetes operator documentation](https://wasmcloud.com/docs/deployment/k8s/operator): the `WasmCloudHostConfig` CRD and OAM Application model this chapter's `wasmcloud-host.yaml` and `wadm.yaml` implement.
- [OpenShift restricted-v2 SCC reference](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html): the UID-range assignment and capability-dropping behavior `evidence/2026-10-21/01-pods.txt` shows every pod in this release landing under.
- Chapter 17, "Wasm on Kubernetes": the landscape this chapter's operator choice comes from, and the shim-versus-operator decision stated before either path ran live.
- Chapter 18, "Deploying on minikube": the same component on the other cluster path this book verifies live, the raw containerd shim and ingress-nginx in place of this chapter's operator and Route.

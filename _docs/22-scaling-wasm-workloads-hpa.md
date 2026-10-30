---
title: "Scaling Wasm Workloads: HPA"
order: 22
part: "Deploying to Kubernetes"
description: "Wire a stock Horizontal Pod Autoscaler to a Wasm Deployment on minikube: the HPA reads real CPU correctly, but a cheap stateless Wasm handler never drives that CPU to target, so it holds the Deployment at one replica; a concurrency-based KEDA scaler takes the same workload to zero and back on request concurrency instead. On CRC, the wadm spreadscaler's instance count is the only correct lever, since a Kubernetes HPA has nothing to target there."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why a stock `autoscaling/v2` HorizontalPodAutoscaler attaches cleanly to a Wasm Deployment on minikube: a Pod with `runtimeClassName: wasmtime` is still scheduled, cgrouped, and metered by the kubelet exactly like a `runc` Pod, so metrics-server and the HPA controller read the same CPU accounting they would for any container workload, and why correct wiring is not the same claim as the HPA driving a scale-out.
- Read live evidence (`kubectl top pod`, `kubectl describe hpa`) and tell apart "the HPA has nothing to read" from "the HPA reads real CPU and the workload never produces enough of it": a cheap, stateless Wasm handler's own CPU usage can sit at 2% of its request under heavy concurrent load while `ScalingActive=True` proves the controller's math is working.
- Read `examples/part5-kubernetes/k8s/scaling/base/hpa.yaml` and point to the exact fields, `averageUtilization: 50` and `scaleDown.stabilizationWindowSeconds: 60`, and explain why a Wasm component's lack of JVM or container warm-up motivates a shorter scale-down window even on a workload that never triggers a scale-out in the first place.
- Explain why a Kubernetes HPA has nothing correct to target on OpenShift Local (CRC): the wasmCloud operator reconciles one `WasmCloudHostConfig` into one host Deployment, not a Deployment per component, and name the lever that replaces an HPA there, the wadm `spreadscaler` trait's `instances` field in `examples/part5-kubernetes/openshift/wadm-scaled.yaml`.
- State why the `httpserver` provider in `wadm-scaled.yaml` stays a `daemonscaler` while only the `cargo-http` component's trait changes to a `spreadscaler`, and what breaks in the deployed app if that choice is reversed.
- Decide, for a given Wasm workload, which substrate's scaling lever applies and whether the metric driving it is the right one: CPU utilization is the wrong signal for a cheap stateless handler on either substrate, which is exactly the gap the concurrency-based, scale-to-zero KEDA mechanism closes.

## Why this matters

Deploying on minikube and deploying on OpenShift Local (CRC) each put the same `app.wasm` on a cluster and proved it answers HTTP requests correctly, one component, one Pod or one wasmCloud host, under light load. The sidecar chapter and the ambassador-and-adapter patterns chapter spliced a second and third component into that request path to add policy, shape translation, and outbound resilience, and along the way isolated a substrate difference that runs through every chapter in this part: compile-time composition on minikube shares one process's memory across a request; a runtime-linked lattice on CRC gives every invocation a fresh instance. This chapter asks a different question of the same two substrates: what happens to a Wasm workload under more load than one Pod or one host can comfortably serve, and does "scale it out" mean the same operation on both platforms. It does not, and the reason traces to exactly the same structural fact the sidecar chapter already surfaced, just applied to a different concern.

On minikube, a Wasm Pod is, from the Kubernetes API's point of view, an ordinary Pod. `runtimeClassName: wasmtime` tells the kubelet which shim to hand the container spec to; it does not remove the Pod from cgroup accounting, from the kubelet's summary API, or from anything metrics-server or the HPA controller already know how to read. A stock `autoscaling/v2` HorizontalPodAutoscaler, the same object type that scales a Spring Boot or a Node.js Deployment, works against `cargo-http` with zero changes to the controller and zero Wasm-specific tooling. The only engineering judgment this chapter adds on the minikube side is tuning the HPA's timing to match a Wasm component's cold-start behavior, which is materially different from a container's.

On CRC, the workload is not a Deployment that happens to run a different shim. The wasmCloud Kubernetes operator (`wasmcloud-host.yaml`, from the OpenShift Local (CRC) deployment) reconciles one `WasmCloudHostConfig` resource into one host Deployment and one host Pod, and inside that single Pod, `wadm` and the wasmCloud host runtime manage however many instances of each component the application's OAM manifest asks for. There is no per-component Kubernetes object for an HPA to point at. Pointing a Kubernetes HPA at the host Deployment instead would not scale `cargo-http`; it would add more wasmCloud lattice nodes, a different and much larger operation the operator already owns and that a generic CPU-utilization controller has no business touching. The correct lever on CRC is the same mechanism `wadm.yaml` already uses to set the component's fixed instance count at deploy time, `wash app deploy`'s own scaler trait, re-applied with a different number.

This chapter's two example trees prove both halves against real cluster state. The minikube half (`examples/part5-kubernetes/k8s/scaling/`) is a gated, headless run that measures `cargo-http`'s own CPU under heavy in-cluster load rather than assuming an outcome, and the measurement is the chapter's finding, not a gap in it. The CRC half (`examples/part5-kubernetes/openshift/`, `verify-scaling-crc.sh`) is a gated, headless script of the identical design. Every manifest and script excerpt below is transcribed directly from those files.

{% include excalidraw.html file="22-hpa-two-substrates" alt="Two bands. Top: on minikube, the cargo-http Deployment runs behind runtimeClassName wasmtime; the kubelet's cAdvisor reads real cgroup CPU usage from the containerd-shim-wasmtime shim, metrics-server scrapes it through the summary API, and a stock autoscaling/v2 HorizontalPodAutoscaler reads metrics-server and scales the Deployment's replica count from 1 toward maxReplicas 5 under load, then back down. Bottom: on CRC, the wasmCloud operator reconciles one WasmCloudHostConfig into exactly one host Deployment and one host Pod; a Kubernetes HorizontalPodAutoscaler has no per-component object to target, so the scaling lever instead is the wadm Application manifest's spreadscaler trait on the cargo-http component, whose instances field changes the in-host component instance count with zero change to the Kubernetes Pod set, while the httpserver provider's daemonscaler trait stays fixed at replicas 1 so the operator keeps creating the Service the edge Route depends on." caption="Figure 22.1: the two scaling levers: a Kubernetes HPA reading cgroup metrics on minikube, and a wadm spreadscaler changing in-host instance count with no Pod churn on CRC." %}

## minikube: a Wasm Pod is a cgrouped Pod, so a stock HPA reads it correctly

`examples/part5-kubernetes/k8s/scaling/base/hpa.yaml` targets the same `cargo-http` Deployment already deployed on minikube, nothing new about the application code or the image:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cargo-http
  namespace: part5-kubernetes
  labels:
    app.kubernetes.io/name: cargo-http
    app.kubernetes.io/part-of: part5-kubernetes
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cargo-http
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 1
          periodSeconds: 30
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 2
          periodSeconds: 15
```

Nothing in this object names Wasm, wasmtime, or a shim; it is a plain `autoscaling/v2` HPA with a resource-utilization target, because nothing about scaling the Deployment needs to be anything else. `containerd-shim-wasmtime` reports the Pod's CPU usage into the same cgroup hierarchy cAdvisor already reads for a `runc` Pod, cAdvisor feeds the kubelet's summary API, metrics-server scrapes that API on its usual interval, and the HPA controller reads metrics-server. Every link in that chain predates this book and has no Wasm-specific code anywhere in it; `runtimeClassName: wasmtime` changes which binary executes `app.wasm` inside the Pod, and nothing upstream of that binary in the Kubernetes control plane needs to know the difference.

`k8s/base/deployment.yaml` sets `resources.requests.cpu` to `50m`, a small figure chosen to make utilization sensitive. Utilization is computed against the request, not against a node's total capacity, so a request this small means a handful of concurrent requests crosses the 50% target quickly, without needing a real load-testing tool or a sustained high-throughput benchmark to demonstrate the mechanism. `examples/part5-kubernetes/k8s/scaling/load/load-generator.yaml` supplies that handful of concurrent requests entirely inside the cluster, a `busybox` Pod running a configurable number of parallel tight request loops against the Service's in-cluster DNS name, never a port-forward:

```yaml
containers:
  - name: load
    image: busybox:1.36
    command: ["/bin/sh", "-c"]
    args:
      - |
        echo "cargo-http-load: starting $CONCURRENCY parallel loops against $TARGET"
        i=0
        while [ "$i" -lt "$CONCURRENCY" ]; do
          ( while true; do
              wget -q -O /dev/null --timeout=3 "$TARGET" 2>/dev/null
            done ) &
          i=$((i + 1))
        done
        wait
    env:
      - name: CONCURRENCY
        value: "8"
      - name: TARGET
        value: "http://cargo-http.part5-kubernetes.svc.cluster.local:8080/cargo/CARGO-USNYC-DEHAM"
```

The Deployment is shipped at `replicas: 0` so applying it is always safe and never drives load by accident. `CONCURRENCY=8` is the manifest's own default, sized to demonstrate the mechanism with a single load Pod; the live evidence run below drives considerably heavier traffic than that default, three load-generator replicas each running 64 parallel loops, 192 concurrent request loops in total, specifically to rule out "the default load was too light" as an explanation for whatever `cargo-http`'s own CPU does under it.

### The scaling math: why the scale-down window can shrink

`hpa.yaml`'s `behavior.scaleDown.stabilizationWindowSeconds` is set to `60`, a quarter of the Kubernetes default of `300`. That default exists for a real reason: a freshly scaled-out replica of a conventional workload is often not ready to absorb load the instant its Pod reports `Ready`, a JVM is still warming up its JIT and loading classes, a connection pool has not yet opened its first connections, and scaling back down too eagerly risks removing capacity the system needed a few seconds ago and might need again a few seconds from now. Five minutes of patience is cheap insurance against that flapping.

A Wasm component run under `wasmtime` has no equivalent warm-up phase to protect against. `containerd-shim-wasmtime` instantiates `app.wasm` and starts serving real requests within milliseconds of the Pod going `Ready`, there is no bytecode interpreter warming into JIT-compiled code, no class loader walking a classpath, no connection pool ramping up in the background; the component's linear memory is initialized and its exported `incoming-handler` is callable the moment the shim finishes loading the module. That means the five-minute default scale-down window is not buying this workload anything: every one of those three hundred seconds a replica sits idle after load drops is pure latency between "the HPA could safely remove this Pod" and "the HPA does," with none of the risk the window exists to manage. Shortening it to `60` seconds (with a conservative `policies` entry removing at most one Pod every 30 seconds, so the Deployment never collapses capacity faster than load is dropping) keeps the safety margin against a true flapping scenario while removing four minutes of needless latency that only applied to workloads with a warm-up cost this one does not have. `scaleUp` stays at the Kubernetes default, `0` seconds of stabilization and the fastest-wins policy, because a fast scale-out was already the right behavior; the asymmetry in this HPA is entirely on the scale-down side, and entirely attributable to the one property that differs between a Wasm component and the workloads the default was tuned for.

This chapter's own live run, below, never reaches far enough into a scale-out for that 60-second window to matter: `cargo-http`'s CPU stays under target for the entire observation period, so the HPA never adds a replica for the window to later remove. The property behind the tuning, no warm-up cost between a Pod going `Ready` and the component serving real traffic, is still real and still worth setting correctly on any HPA fronting a Wasm Deployment; it just does not pay off inside this chapter's CPU-driven mechanism. The same property pays off directly in the KEDA HTTP add-on's scale-to-zero mechanism: it scales the identical Deployment from zero replicas, and the same millisecond-class start is most of what keeps its cold-start number as low as it is.

{% include excalidraw.html file="22-cold-start-scaling-math" alt="A timeline comparing scale-down stabilization windows. For a conventional container workload (JVM or similar), after load drops, the HPA holds the window open for 300 seconds by Kubernetes default, because a newly-scaled replica needed real warm-up time (JIT compilation, connection pool ramp) before it could be trusted to absorb load, and removing it too soon risks flapping. For the Wasm component in this chapter, the containerd-shim-wasmtime shim instantiates app.wasm and starts serving within single-digit milliseconds of the Pod reporting Ready, so hpa.yaml shortens the scale-down window to 60 seconds on the same reasoning, even though this chapter's own CPU-driven HPA never reaches a scale-out to exercise that window against. The same fast-start property is what the KEDA HTTP add-on draws on directly: it scales a Wasm Deployment from zero replicas, and the millisecond-class start, not a warm-up period, is most of what keeps its measured cold-start time as low as it is." caption="Figure 22.2: the scaling math: a Wasm component's millisecond cold start removes the warm-up risk a scale-down window is sized for. This chapter's CPU-based HPA never reaches a scale-out to exercise it; the KEDA HTTP add-on's scale-from-zero cold start is where the same property pays off." %}

`examples/part5-kubernetes/k8s/scaling/verify-hpa-minikube.sh` turns all of this into a gated, idempotent run: it brings the minikube profile up with the `docker` driver and `containerd` runtime, builds and loads `app.wasm`'s image, installs the `wasmtime` `RuntimeClass`, checks (but does not enable) the `metrics-server` addon, applies the scaling overlay, and then polls real state rather than sleeping a fixed duration:

```bash
step "Step 7: wait for the HPA to report REAL metrics (not <unknown>)"
hpa_has_metrics() {
  local targets
  targets="$(kubectl get hpa cargo-http -n "$NAMESPACE" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
  [[ -n "$targets" ]]
}
...
step "Step 9: assert a REAL scale-out — replicas 1 -> N under load (never assumed)"
current_replicas() {
  kubectl get deployment cargo-http -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0
}
waited=0; scaled=0
while (( waited < SCALE_UP_TIMEOUT )); do
  r="$(current_replicas)"
  if [[ "$r" -gt 1 ]]; then
    scaled=1
    echo "verify-hpa-minikube.sh: observed scale-out to $r replicas after ${waited}s"
    break
  fi
  sleep 10; waited=$(( waited + 10 ))
done
```

A timeout in either the metrics wait or the scale-out poll is a script failure, not a soft warning: `verify-hpa-minikube.sh` is built around the assumption that CPU load will eventually push a scale-out, and it fails hard if that assumption doesn't hold within its timeout window. A companion script, `examples/part5-kubernetes/k8s/scaling/capture-hpa-evidence.sh`, runs the identical bring-up, the profile, the image, the shim, the `RuntimeClass`, the scaling overlay, but drops that assumption in favor of a direct measurement: three load-generator replicas, 64 parallel request loops each, sampling `cargo-http`'s own CPU utilization and replica count every 20 seconds for a full two-minute window, then reporting whatever the measurement shows. This is the script, and the 2026-10-21 run of it, this chapter's minikube half is verified against:

```
$ kubectl top pod -n part5-kubernetes
NAME                               CPU(cores)   MEMORY(bytes)
cargo-http-8445d4c5d6-dl55k        1m           6Mi
cargo-http-load-5868786db5-2slgb   249m         24Mi
cargo-http-load-5868786db5-ddtj4   247m         24Mi
cargo-http-load-5868786db5-lr7zz   248m         24Mi

$ kubectl get hpa cargo-http -n part5-kubernetes
NAME         REFERENCE               TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
cargo-http   Deployment/cargo-http   cpu: 2%/50%   1         5         1          2m52s

$ kubectl describe hpa cargo-http -n part5-kubernetes   # (excerpt)
Metrics:                                               ( current / target )
  resource cpu on pods  (as a percentage of request):  2% (1m) / 50%
  ScalingActive   True    ValidMetricFound    the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)
```

Three load Pods each saturate roughly 248m of CPU generating that traffic, while `cargo-http`'s own CPU holds at 1m for the entire two-minute observation window, 2% of its 50m request, nowhere near the 50% target. `kubectl describe hpa` shows the controller working exactly as designed: `ScalingActive=True`, `ValidMetricFound`, the HPA successfully computing a replica count from real CPU data and arriving at 1, because 1 is what 2% utilization against a 50% target computes to. CPU utilization is the wrong signal to scale a cheap, stateless Wasm handler on. `cargo-http` does so little per request, no serialization framework warming up, no connection pool to maintain, no JIT to amortize, that even 192 concurrent request loops cannot push its own CPU within an order of magnitude of a 50-millicore target. A workload shaped like this needs a scaling signal that tracks what is scarce for it, in-flight request concurrency, rather than a resource it barely touches; that is precisely the gap the KEDA HTTP add-on's concurrency-based scaling closes, scaling this exact Deployment on concurrent-request count instead of CPU, down to zero replicas and back.

## CRC: the wadm spreadscaler, not a Kubernetes HPA

OpenShift Local's wasmCloud operator does not expose a per-component Kubernetes object. `examples/part5-kubernetes/openshift/wadm-scaled.yaml` deploys the same application `wadm.yaml` already runs on CRC, with one change, the `cargo-http` component's scaler trait becomes a `spreadscaler` carrying a templated `instances` count instead of a fixed `daemonscaler` replica count:

```yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: cargo-http
  annotations:
    version: v0.0.1
    description: "ch22 scaling variant: cargo-http component on a spreadscaler (wadm-managed instance count), httpserver provider unchanged (daemonscaler, for operator Service creation)"
spec:
  components:
    - name: cargo-http
      type: component
      properties:
        image: __COMPONENT_REF__
      traits:
        - type: spreadscaler
          properties:
            instances: __INSTANCES__

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

The manifest's own comments state the reasoning directly: on CRC, the wasmCloud operator reconciles a `WasmCloudHostConfig` into one host Deployment, and inside that one host Pod, `wadm` and the host runtime instantiate each component some number of times according to its own OAM scaler trait, not according to anything Kubernetes-native. There is no per-component Deployment or Pod for a Kubernetes HPA to target; pointing one at the host Deployment instead would scale the number of wasmCloud lattice *hosts*, an entirely different operation the operator already owns, and the operator does not surface per-component instance count as a metric any Kubernetes-native controller could read in the first place. The `spreadscaler`'s `instances` field is the correct, operator-aware lever precisely because it is the same mechanism `wadm.yaml` already uses to fix the component's replica count at deploy time, `wash app deploy` applying this manifest with a different number is an update-in-place under the same Application name, a redeploy rather than a new app, and `contracts/wit` is untouched either way.

The `httpserver` provider's trait stays a `daemonscaler`, and that is required, not incidental. The operator only auto-creates the Kubernetes Service for an application whose `httpserver` provider uses a `daemonscaler`; `spreadscaler`-based Service creation is not implemented. Switching the *provider's* trait to a `spreadscaler` to match the component removes the Service the edge-TLS Route in front of this application depends on, breaking every external request path this chapter and the CRC deployment rely on, for no scaling benefit, since the provider is a single `httpserver` listener regardless of how many `cargo-http` instances are behind it. Only the component's trait changes; the provider's stays exactly as `wadm.yaml` already shipped it.

`examples/part5-kubernetes/openshift/verify-scaling-crc.sh` proves the asymmetry with an in-place `wadm` application update rather than a cluster bring-up, since it assumes `./openshift/deploy.sh` has already deployed the app:

```bash
# applied_instances — the `instances` value wadm currently has on record for
# the cargo-http component's spreadscaler trait (the DESIRED count we just
# applied, read back from the cluster object, not from our own variable).
applied_instances() {
    oc get application.core.oam.dev "$APP" -n "$NS" \
        -o jsonpath='{.spec.components[?(@.name=="cargo-http")].traits[?(@.type=="spreadscaler")].properties.instances}' 2>/dev/null
}

# host_pods — the wasmCloud host Pod name(s), one per line, sorted. Used to
# assert ZERO Kubernetes Pod churn across a wadm instances change.
host_pods() {
    oc get pods -n "$NS" -l "app.kubernetes.io/name=$HOSTCFG" -o name 2>/dev/null | sort
}
```

The script's five steps apply `wadm-scaled.yaml` at `instances=1` as a baseline, then at `SCALE_UP_INSTANCES` (default `4`), then back to `1`, and at every step it checks two independent facts: that the `instances` value recorded on the `Application` object changed to what was just applied (`applied_instances`, read back from the cluster, not assumed from the script's own variable), and that the set of wasmCloud host Pods (`host_pods`) is byte-for-byte identical before, during, and after the whole cycle:

```bash
step "2/5 Scale OUT: wadm instances 1 -> $SCALE_UP_INSTANCES"
apply_scaled "$SCALE_UP_INSTANCES"
wait_route_serving "/cargo/CARGO-USNYC-DEHAM"
SCALED_PODS="$(host_pods)"
[[ "$AFTER_BASELINE_PODS" == "$SCALED_PODS" ]] \
    || fail "ASYMMETRY BROKEN — scaling wadm instances to $SCALE_UP_INSTANCES changed the Kubernetes Pod set (before=[$AFTER_BASELINE_PODS] after=[$SCALED_PODS]); expected ZERO Pod churn (the component scales INSIDE the existing host pod, not via new Pods)"
ok "ZERO Kubernetes Pod churn while wadm instances went 1 -> $SCALE_UP_INSTANCES: $SCALED_PODS"
```

A test that only checked traffic (the script also curls the Route through a CA-verified `https()` helper at every step, confirming the exact cargo JSON and the embargoed-id 404 both still work) could pass even if the operator had, for some reason, rescheduled the host Pod during the scale. Asserting the Pod set stays identical is what proves the claim this chapter makes about CRC: the component's instance count is changing *inside* an unchanged Pod, invisible to anything watching Kubernetes objects rather than the wasmCloud lattice's own state. Host-log evidence of the wasmCloud runtime's own scale-up and scale-down messages is captured for the record in a separate evidence step, but is not a pass/fail gate in this script; host and operator log wording is not a stable, versioned contract to assert against, so the Pod-set comparison and the `applied_instances` readback carry the actual proof.

## Why the two substrates diverge

The divergence is not a gap in the wasmCloud operator's feature set measured against a plain Kubernetes Deployment; it is a direct consequence of where each platform draws the boundary between "a Kubernetes object" and "a thing running inside one." On minikube, `runtimeClassName: wasmtime` changes which shim executes the Pod's single container, and nothing about that choice moves the component out from under the kubelet's own Pod-level accounting: the Pod is the unit of both scheduling and scaling, same as it would be for any `runc` workload, and the entire chain from cgroup to cAdvisor to metrics-server to the HPA controller already knows how to work with that unit. On CRC, the wasmCloud operator inserts a second scheduling layer between the Kubernetes API and the running component: the Pod becomes the unit of *host* lifecycle, one Pod running one wasmCloud host, and the component becomes a unit the host's own runtime schedules inside that Pod according to the application's OAM manifest, a layer Kubernetes itself has no visibility into and no object representing.

That second layer is also exactly what let the OpenShift Local (CRC) deployment show the wasmCloud host surviving an `oc delete pod` with zero application-visible downtime, the operator reconciling a fresh host Pod while `wadm`'s desired state for the application was unaffected. The same structural choice that bought that deployment its resilience story is what removes a Kubernetes HPA's target here: a control plane that can transparently replace the host Pod underneath a running application is, by the same mechanism, a control plane where the component's instance count is not a property of any Pod a Kubernetes-native autoscaler could read. Neither substrate is incomplete; each one scales the unit it schedules, a Pod on minikube, a lattice instance inside a Pod on CRC, and the right autoscaling tool follows directly from asking which of those two units the workload in front of you is.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s/scaling && ./verify-hpa-minikube.sh
```

`verify-hpa-minikube.sh` brings up the `part5` minikube profile, builds and loads `app.wasm`'s image, installs the `wasmtime` shim, checks (but does not enable) the `metrics-server` addon, and applies the scaling overlay with the `cargo-http` HPA. It scales the in-cluster load generator to drive concurrent request loops against the Service's DNS name, then polls `kubectl get hpa` and `kubectl get deployment` until the HPA reports real (non-`<unknown>`) metrics and asserts a real scale-out from 1 to more than 1 replica, failing hard on a timeout rather than assuming the outcome; it then scales the load back to zero and waits for replicas to return to 1. `openshift/verify-scaling-crc.sh` is the CRC counterpart: run after `deploy.sh`, it re-applies `wadm-scaled.yaml` to cycle the `cargo-http` component's `spreadscaler` instance count 1 to 4 to 1, asserting the `instances` value read back from the Application object changes while the set of wasmCloud host Pods stays byte-for-byte identical, and that the edge-TLS Route keeps serving the exact cargo JSON throughout. Expect `PASS` on either script once its assertions hold.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for a stock <code>autoscaling/v2</code> HorizontalPodAutoscaler when the Wasm workload is deployed as an ordinary Kubernetes Deployment, the way the raw containerd shim deploys it on minikube: the kubelet's cgroup accounting and metrics-server already see the Pod correctly, and no Wasm-specific controller is needed. Before trusting CPU as the metric that drives it, confirm the workload's own utilization approaches the target under real load, the way this chapter's live run checked it and found it does not: a correctly wired HPA reading a signal the workload never produces is not a working autoscaler for that workload, whatever <code>ScalingActive</code> reports, and a cheap stateless Wasm handler is exactly the shape of workload most likely to fail that check. While you are there, measure whether the component has a warm-up cost before copying a container workload's default <code>scaleDown.stabilizationWindowSeconds</code>; a component that starts serving within milliseconds of <code>Ready</code>, the way this chapter's does under <code>containerd-shim-wasmtime</code>, can safely run a much shorter window than the 300-second default sized for JVM or connection-pool warm-up, because that window is pure latency once the risk it protects against is gone. Reach for the operator's own OAM scaler trait, a <code>spreadscaler</code>'s <code>instances</code> count here, whenever the workload is managed by an operator that owns its own host-level Deployment, the way the wasmCloud Kubernetes operator does on CRC: a Kubernetes HPA pointed at that host Deployment does not scale the component, it fights the operator for a field the operator already reconciles, and the operator typically has no per-component Kubernetes metric for an HPA to read regardless. When two traits sit in the same manifest and only one of them needs to change, as the provider's <code>daemonscaler</code> and the component's <code>spreadscaler</code> do in <code>wadm-scaled.yaml</code>, check what each trait is responsible for (Service creation here) before changing the one that is not the lever you are reaching for.</p></div>

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023), "Elastic Scale": the Horizontal Pod Autoscaler pattern this chapter's minikube half implements unmodified against a Wasm Deployment, and the resource-request sizing discipline behind `k8s/base/deployment.yaml`'s small `50m` CPU request.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the component instantiation cost model behind this chapter's cold-start scaling-math figure: why a Wasm component's linear-memory startup carries none of a JVM's class-loading or connection-pool warm-up.
- [Kubernetes: Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/): the `autoscaling/v2` API, the utilization-target metric type, and the `behavior.scaleDown`/`scaleUp` stabilization-window fields `hpa.yaml` tunes in this chapter.
- [wasmCloud Kubernetes operator documentation](https://wasmcloud.com/docs/deployment/k8s/operator): the `WasmCloudHostConfig` reconciliation into one host Deployment this chapter's CRC half explains as the reason a Kubernetes HPA has no per-component object to target.
- [wasmCloud documentation](https://wasmcloud.com/docs/): the OAM Application model and its scaler traits (`spreadscaler`, `daemonscaler`) this chapter's `wadm-scaled.yaml` relies on as the correct, operator-aware scaling lever.
- Wasm on Kubernetes: the four deployment paths this part has worked through, and the operator fallback this chapter's CRC scaling lever builds directly on.
- Deploying on minikube: the raw containerd shim, the `cargo-http` Deployment, and the `runtimeClassName: wasmtime` mechanism this chapter's stock HPA scales unmodified.
- Deploying on OpenShift Local (CRC): the `WasmCloudHostConfig`, the `wadm.yaml` Application, and the host-Pod resilience story that is the other side of the same operator layer this chapter shows removing a Kubernetes HPA's target.
- Wasm as a sidecar: the per-invocation component statelessness on CRC's wasmCloud lattice, the same underlying mechanism (every component call resolved by the lattice, not pinned to a Kubernetes Pod) that this chapter's zero-Pod-churn scaling proof depends on.
- Serverless Wasm: scale-to-zero with KEDA: the concurrency-based scaling that picks up exactly where this chapter's CPU-based HPA finds no signal to work with, taking the same `cargo-http` Deployment all the way to zero replicas and back.

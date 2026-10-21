---
title: "Scaling Wasm Workloads: HPA"
order: 22
part: "Deploying to Kubernetes"
description: "Scale a Wasm deployment with the Horizontal Pod Autoscaler on minikube, and with the wadm spreadscaler's instance count on CRC where a Kubernetes HPA has nothing correct to target; a component's millisecond cold start also changes the scale-down math a container workload never gets to make."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain why a stock `autoscaling/v2` HorizontalPodAutoscaler works unmodified against a Wasm Deployment on minikube: a Pod with `runtimeClassName: wasmtime` is still scheduled, cgrouped, and metered by the kubelet exactly like a `runc` Pod, so metrics-server and the HPA controller read the same CPU accounting they would for any container workload.
- Read `examples/part5-kubernetes/k8s/scaling/base/hpa.yaml` and point to the exact fields, `averageUtilization: 50` and `scaleDown.stabilizationWindowSeconds: 60`, that a Wasm component's lack of JVM or container warm-up lets you set differently than a conventional workload's defaults, and explain why `scaleUp` is left at the Kubernetes default instead.
- Explain why a Kubernetes HPA has nothing correct to target on OpenShift Local (CRC): the wasmCloud operator reconciles one `WasmCloudHostConfig` into one host Deployment, not a Deployment per component, and name the lever that replaces an HPA there, the wadm `spreadscaler` trait's `instances` field in `examples/part5-kubernetes/openshift/wadm-scaled.yaml`.
- State why the `httpserver` provider in `wadm-scaled.yaml` stays a `daemonscaler` while only the `cargo-http` component's trait changes to a `spreadscaler`, and what breaks in the deployed app if that choice is reversed.
- Decide, for a given Wasm workload, which substrate's scaling lever applies, and read a scaling run's evidence correctly: replica counts climbing and falling on one side, a Kubernetes Pod set that never changes at all on the other, as the proof that the right mechanism fired rather than an assumption that it did.

## Why this matters

Chapters 18 and 19 each put the same `app.wasm` on a cluster and proved it answers HTTP requests correctly, one component, one Pod or one wasmCloud host, under light load. Chapters 20 and 21 spliced a second and third component into that request path to add policy, shape translation, and outbound resilience, and along the way isolated a substrate difference that runs through every chapter in this part: compile-time composition on minikube shares one process's memory across a request; a runtime-linked lattice on CRC gives every invocation a fresh instance. This chapter asks a different question of the same two substrates: what happens to a Wasm workload under more load than one Pod or one host can comfortably serve, and does "scale it out" mean the same operation on both platforms. It does not, and the reason traces to exactly the same structural fact Chapter 20 already surfaced, just applied to a different concern.

On minikube, a Wasm Pod is, from the Kubernetes API's point of view, an ordinary Pod. `runtimeClassName: wasmtime` tells the kubelet which shim to hand the container spec to; it does not remove the Pod from cgroup accounting, from the kubelet's summary API, or from anything metrics-server or the HPA controller already know how to read. A stock `autoscaling/v2` HorizontalPodAutoscaler, the same object type that scales a Spring Boot or a Node.js Deployment, works against `cargo-http` with zero changes to the controller and zero Wasm-specific tooling. The only engineering judgment this chapter adds on the minikube side is tuning the HPA's timing to match a Wasm component's cold-start behavior, which is materially different from a container's.

On CRC, the workload is not a Deployment that happens to run a different shim. The wasmCloud Kubernetes operator (Chapter 19's `wasmcloud-host.yaml`) reconciles one `WasmCloudHostConfig` resource into one host Deployment and one host Pod, and inside that single Pod, `wadm` and the wasmCloud host runtime manage however many instances of each component the application's OAM manifest asks for. There is no per-component Kubernetes object for an HPA to point at. Pointing a Kubernetes HPA at the host Deployment instead would not scale `cargo-http`; it would add more wasmCloud lattice nodes, a different and much larger operation the operator already owns and that a generic CPU-utilization controller has no business touching. The correct lever on CRC is the same mechanism `wadm.yaml` already uses to set the component's fixed instance count at deploy time, `wash app deploy`'s own scaler trait, re-applied with a different number.

This chapter's two example trees prove both halves live, and as of this writing neither run has executed against a cluster yet: the minikube half (`examples/part5-kubernetes/k8s/scaling/`, `verify-hpa-minikube.sh`) and the CRC half (`examples/part5-kubernetes/openshift/`, `verify-scaling-crc.sh`) are both gated, headless scripts that assert real replica or instance counts rather than assuming them, and their evidence lands under `k8s/evidence/<date>/` and `openshift/evidence/<date>/` once they run. Every manifest, script excerpt, and structural claim below is transcribed directly from those files; every spot where a live cluster's numbers belong is marked as pending rather than invented.

{% include excalidraw.html file="22-hpa-two-substrates" alt="Two bands. Top: on minikube, the cargo-http Deployment runs behind runtimeClassName wasmtime; the kubelet's cAdvisor reads real cgroup CPU usage from the containerd-shim-wasmtime shim, metrics-server scrapes it through the summary API, and a stock autoscaling/v2 HorizontalPodAutoscaler reads metrics-server and scales the Deployment's replica count from 1 toward maxReplicas 5 under load, then back down. Bottom: on CRC, the wasmCloud operator reconciles one WasmCloudHostConfig into exactly one host Deployment and one host Pod; a Kubernetes HorizontalPodAutoscaler has no per-component object to target, so the scaling lever instead is the wadm Application manifest's spreadscaler trait on the cargo-http component, whose instances field changes the in-host component instance count with zero change to the Kubernetes Pod set, while the httpserver provider's daemonscaler trait stays fixed at replicas 1 so the operator keeps creating the Service the edge Route depends on." caption="Figure 22.1 — the two scaling levers: a Kubernetes HPA reading cgroup metrics on minikube, and a wadm spreadscaler changing in-host instance count with no Pod churn on CRC." %}

## minikube: a Wasm Pod is a cgrouped Pod, so a stock HPA just works

`examples/part5-kubernetes/k8s/scaling/base/hpa.yaml` targets the same `cargo-http` Deployment Chapter 18 already deployed, nothing new about the application code or the image:

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

Nothing in this object names Wasm, wasmtime, or a shim; it is a plain `autoscaling/v2` HPA with a resource-utilization target, because nothing about scaling the Deployment needs to be anything else. `containerd-shim-wasmtime` reports the Pod's CPU usage into the same cgroup hierarchy cAdvisor already reads for a `runc` Pod, cAdvisor feeds the kubelet's summary API, metrics-server scrapes that API on its usual interval, and the HPA controller reads metrics-server. Every link in that chain predates this book and has no Wasm-specific code anywhere in it; `runtimeClassName: wasmtime` changes which binary actually executes `app.wasm` inside the Pod, and nothing upstream of that binary in the Kubernetes control plane needs to know the difference.

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

The Deployment is shipped at `replicas: 0` so applying it is always safe and never drives load by accident; the verification script scales it to `1` to start the eight parallel loops, and back to `0` to let the HPA settle `cargo-http` back down, checking the actual replica counts at every step rather than assuming the HPA reacted.

### The scaling math: why the scale-down window can shrink

`hpa.yaml`'s `behavior.scaleDown.stabilizationWindowSeconds` is set to `60`, a quarter of the Kubernetes default of `300`. That default exists for a real reason: a freshly scaled-out replica of a conventional workload is often not actually ready to absorb load the instant its Pod reports `Ready`, a JVM is still warming up its JIT and loading classes, a connection pool has not yet opened its first connections, and scaling back down too eagerly risks removing capacity the system needed a few seconds ago and might need again a few seconds from now. Five minutes of patience is cheap insurance against that flapping.

A Wasm component run under `wasmtime` has no equivalent warm-up phase to protect against. `containerd-shim-wasmtime` instantiates `app.wasm` and starts serving real requests within milliseconds of the Pod going `Ready`, there is no bytecode interpreter warming into JIT-compiled code, no class loader walking a classpath, no connection pool ramping up in the background; the component's linear memory is initialized and its exported `incoming-handler` is callable essentially the moment the shim finishes loading the module. That means the five-minute default scale-down window is not buying this workload anything: every one of those three hundred seconds a replica sits idle after load drops is pure latency between "the HPA could safely remove this Pod" and "the HPA actually does," with none of the risk the window exists to manage. Shortening it to `60` seconds (with a conservative `policies` entry removing at most one Pod every 30 seconds, so the Deployment never collapses capacity faster than load is actually dropping) keeps the safety margin against a true flapping scenario while removing four minutes of needless latency that only applied to workloads with a warm-up cost this one does not have. `scaleUp` stays at the Kubernetes default, `0` seconds of stabilization and the fastest-wins policy, because a fast scale-out was already the right behavior; the asymmetry in this HPA is entirely on the scale-down side, and entirely attributable to the one property that differs between a Wasm component and the workloads the default was tuned for.

{% include excalidraw.html file="22-cold-start-scaling-math" alt="A timeline comparing scale-down stabilization windows. For a conventional container workload (JVM or similar), after load drops, the HPA holds the window open for 300 seconds by Kubernetes default, because a newly-scaled replica needed real warm-up time (JIT compilation, connection pool ramp) before it could be trusted to absorb load, and removing it too soon risks flapping. For the Wasm component in this chapter, the containerd-shim-wasmtime shim instantiates app.wasm and starts serving within single-digit milliseconds of the Pod reporting Ready, so there is no warm-up period the window is protecting; hpa.yaml shortens the window to 60 seconds, cutting four minutes of pure latency between the HPA's evaluation and the actual scale-down action while keeping a conservative one-Pod-per-30-seconds removal policy." caption="Figure 22.2 — the scaling math: a Wasm component's millisecond cold start removes the warm-up risk the Kubernetes default scale-down window is sized for, so the window itself can shrink." %}

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

A timeout in either the metrics wait or the scale-out poll is a script failure, not a soft warning; the same pattern repeats for the scale-down assertion after the load generator is scaled back to `0`, and a final step re-curls the exact cargo JSON through the Ingress to confirm the application still answers correctly after a full scale-out-and-back-down cycle. This script has not yet been run against a live cluster as part of this chapter's authoring; the timeline it produces belongs here once it has.

<!-- LIVE-OUTPUT ch22 minikube HPA: fill verbatim from k8s/evidence/<date>/2x-*.txt after the gated minikube run -->
```
(verified-live output lands here after the cluster run: kubectl get hpa,deploy cargo-http
timeline showing replicas 1 -> N under load, then N -> 1 after the load generator
is scaled back to 0, per verify-hpa-minikube.sh Steps 7-11 / capture-hpa-evidence.sh
files 20-25 in k8s/evidence/<date>/)
```

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

The `httpserver` provider's trait stays a `daemonscaler`, and that is required, not incidental. The operator only auto-creates the Kubernetes Service for an application whose `httpserver` provider uses a `daemonscaler`; `spreadscaler`-based Service creation is not implemented. Switching the *provider's* trait to a `spreadscaler` to match the component would silently remove the Service the edge-TLS Route in front of this application depends on, breaking every external request path this chapter and Chapter 19 before it rely on, for no scaling benefit, since the provider is a single `httpserver` listener regardless of how many `cargo-http` instances are behind it. Only the component's trait changes; the provider's stays exactly as `wadm.yaml` already shipped it.

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

The script's five steps apply `wadm-scaled.yaml` at `instances=1` as a baseline, then at `SCALE_UP_INSTANCES` (default `4`), then back to `1`, and at every step it checks two independent facts: that the `instances` value actually recorded on the `Application` object changed to what was just applied (`applied_instances`, read back from the cluster, not assumed from the script's own variable), and that the set of wasmCloud host Pods (`host_pods`) is byte-for-byte identical before, during, and after the whole cycle:

```bash
step "2/5 Scale OUT: wadm instances 1 -> $SCALE_UP_INSTANCES"
apply_scaled "$SCALE_UP_INSTANCES"
wait_route_serving "/cargo/CARGO-USNYC-DEHAM"
SCALED_PODS="$(host_pods)"
[[ "$AFTER_BASELINE_PODS" == "$SCALED_PODS" ]] \
    || fail "ASYMMETRY BROKEN — scaling wadm instances to $SCALE_UP_INSTANCES changed the Kubernetes Pod set (before=[$AFTER_BASELINE_PODS] after=[$SCALED_PODS]); expected ZERO Pod churn (the component scales INSIDE the existing host pod, not via new Pods)"
ok "ZERO Kubernetes Pod churn while wadm instances went 1 -> $SCALE_UP_INSTANCES: $SCALED_PODS"
```

A test that only checked traffic (the script also curls the Route through a CA-verified `https()` helper at every step, confirming the exact cargo JSON and the embargoed-id 404 both still work) could pass even if the operator had, for some reason, rescheduled the host Pod during the scale. Asserting the Pod set stays identical is what actually proves the claim this chapter makes about CRC: the component's instance count is changing *inside* an unchanged Pod, invisible to anything watching Kubernetes objects rather than the wasmCloud lattice's own state. Host-log evidence of the wasmCloud runtime's own scale-up and scale-down messages is captured for the record in a separate evidence step, but is not a pass/fail gate in this script; host and operator log wording is not a stable, versioned contract to assert against, so the Pod-set comparison and the `applied_instances` readback carry the actual proof.

<!-- LIVE-OUTPUT ch22 CRC wadm scaling: fill verbatim from openshift/evidence/<date>/1x-*.txt after the gated CRC run -->
```
(verified-live output lands here after the cluster run: the wadm Application's
spreadscaler instances value read back at 1 -> 4 -> 1, the wasmCloud host Pod
name(s) shown identical across all three states, and the CA-verified Route
responses for /cargo/CARGO-USNYC-DEHAM and /cargo/NOPE at each step, per
verify-scaling-crc.sh Steps 1-5 / capture-scaling-evidence.sh files 10-14 in
openshift/evidence/<date>/)
```

## Why the two substrates diverge

The divergence is not a gap in the wasmCloud operator's feature set measured against a plain Kubernetes Deployment; it is a direct consequence of where each platform draws the boundary between "a Kubernetes object" and "a thing running inside one." On minikube, `runtimeClassName: wasmtime` changes which shim executes the Pod's single container, and nothing about that choice moves the component out from under the kubelet's own Pod-level accounting: the Pod is the unit of both scheduling and scaling, same as it would be for any `runc` workload, and the entire chain from cgroup to cAdvisor to metrics-server to the HPA controller already knows how to work with that unit. On CRC, the wasmCloud operator inserts a second scheduling layer between the Kubernetes API and the running component: the Pod becomes the unit of *host* lifecycle, one Pod running one wasmCloud host, and the component becomes a unit the host's own runtime schedules inside that Pod according to the application's OAM manifest, a layer Kubernetes itself has no visibility into and no object representing.

That second layer is also exactly what let Chapter 19 show the wasmCloud host surviving an `oc delete pod` with zero application-visible downtime, the operator reconciling a fresh host Pod while `wadm`'s desired state for the application was unaffected. The same structural choice that bought Chapter 19 its resilience story is what removes a Kubernetes HPA's target here: a control plane that can transparently replace the host Pod underneath a running application is, by the same mechanism, a control plane where the component's instance count is not a property of any Pod a Kubernetes-native autoscaler could read. Neither substrate is incomplete; each one scales the unit it actually schedules, a Pod on minikube, a lattice instance inside a Pod on CRC, and the right autoscaling tool follows directly from asking which of those two units the workload in front of you actually is.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for a stock <code>autoscaling/v2</code> HorizontalPodAutoscaler when the Wasm workload is deployed as an ordinary Kubernetes Deployment, the way the raw containerd shim deploys it on minikube: the kubelet's cgroup accounting and metrics-server already see the Pod correctly, and no Wasm-specific controller is needed. While you are there, measure whether the component actually has a warm-up cost before copying a container workload's default <code>scaleDown.stabilizationWindowSeconds</code>; a component that starts serving within milliseconds of <code>Ready</code>, the way this chapter's does under <code>containerd-shim-wasmtime</code>, can safely run a much shorter window than the 300-second default sized for JVM or connection-pool warm-up, because that window is pure latency once the risk it protects against is gone. Reach for the operator's own OAM scaler trait, a <code>spreadscaler</code>'s <code>instances</code> count here, whenever the workload is managed by an operator that owns its own host-level Deployment, the way the wasmCloud Kubernetes operator does on CRC: a Kubernetes HPA pointed at that host Deployment does not scale the component, it fights the operator for a field the operator already reconciles, and the operator typically has no per-component Kubernetes metric for an HPA to read regardless. When two traits sit in the same manifest and only one of them needs to change, as the provider's <code>daemonscaler</code> and the component's <code>spreadscaler</code> do in <code>wadm-scaled.yaml</code>, check what each trait is actually responsible for (Service creation here) before changing the one that is not the lever you are reaching for.</p></div>

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023), "Elastic Scale" — the Horizontal Pod Autoscaler pattern this chapter's minikube half implements unmodified against a Wasm Deployment, and the resource-request sizing discipline behind `k8s/base/deployment.yaml`'s small `50m` CPU request.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning) — the component instantiation cost model behind this chapter's cold-start scaling-math figure: why a Wasm component's linear-memory startup carries none of a JVM's class-loading or connection-pool warm-up.
- [Kubernetes: Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) — the `autoscaling/v2` API, the utilization-target metric type, and the `behavior.scaleDown`/`scaleUp` stabilization-window fields `hpa.yaml` tunes in this chapter.
- [wasmCloud Kubernetes operator documentation](https://wasmcloud.com/docs/deployment/k8s/operator) — the `WasmCloudHostConfig` reconciliation into one host Deployment this chapter's CRC half explains as the reason a Kubernetes HPA has no per-component object to target.
- [wasmCloud documentation](https://wasmcloud.com/docs/) — the OAM Application model and its scaler traits (`spreadscaler`, `daemonscaler`) this chapter's `wadm-scaled.yaml` relies on as the correct, operator-aware scaling lever.
- Chapter 17, "Wasm on Kubernetes" — the four deployment paths this part has worked through, and the operator fallback this chapter's CRC scaling lever builds directly on.
- Chapter 18, "Deploying on minikube" — the raw containerd shim, the `cargo-http` Deployment, and the `runtimeClassName: wasmtime` mechanism this chapter's stock HPA scales unmodified.
- Chapter 19, "Deploying on OpenShift Local (CRC)" — the `WasmCloudHostConfig`, the `wadm.yaml` Application, and the host-Pod resilience story that is the other side of the same operator layer this chapter shows removing a Kubernetes HPA's target.
- Chapter 20, "Wasm as a Sidecar" — the per-invocation component statelessness on CRC's wasmCloud lattice, the same underlying mechanism (every component call resolved by the lattice, not pinned to a Kubernetes Pod) that this chapter's zero-Pod-churn scaling proof depends on.

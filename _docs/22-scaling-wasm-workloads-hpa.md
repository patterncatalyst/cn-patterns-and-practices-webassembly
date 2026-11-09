---
title: "Scaling Wasm Workloads: HPA"
order: 22
part: "Deploying to Kubernetes"
description: "A stock HPA attaches cleanly to a Wasm Deployment on minikube but never sees enough CPU to scale it; on CRC the wadm spreadscaler instance count is the lever, because the operator leaves an HPA nothing to target."
duration: "19 min read"
---

## Learning objectives

By the end of this chapter you can:

- Attach a stock `autoscaling/v2` HorizontalPodAutoscaler to a Wasm Deployment on minikube and say why it works without Wasm-specific tooling.
- Tell "the HPA has nothing to read" from "the HPA reads real CPU and the workload never produces enough of it", using `kubectl top pod` and `kubectl describe hpa`.
- Explain why a Wasm component's lack of warm-up justifies a shorter `scaleDown.stabilizationWindowSeconds`.
- Explain why an HPA has nothing correct to target on OpenShift Local (CRC), and use the wadm `spreadscaler` `instances` field as the lever instead.
- Say why the `httpserver` provider stays a `daemonscaler` while only the `cargo-http` component becomes a `spreadscaler`.

## Why this matters

"Scale it out" does not mean the same operation on both platforms.

On minikube a Wasm Pod is an ordinary Pod to the Kubernetes API. `runtimeClassName: wasmtime` picks the shim; it does not remove the Pod from cgroup accounting, the kubelet summary API, metrics-server or the HPA controller. A stock HPA, the object that scales a Spring Boot or Node.js Deployment, works against `cargo-http` unchanged.

On CRC the workload is not a Deployment on a different shim. The wasmCloud operator reconciles one `WasmCloudHostConfig` into one host Deployment and one host Pod, and inside that Pod `wadm` and the host runtime run as many instances of each component as the application's OAM manifest asks for. There is no per-component Kubernetes object for an HPA to point at. Pointing it at the host Deployment would add wasmCloud hosts, not `cargo-http` instances, and fight the operator for a field it reconciles.

{% include excalidraw.html file="22-hpa-two-substrates" alt="Two bands. Top, minikube: the cargo-http Deployment runs with runtimeClassName wasmtime; cAdvisor reads cgroup CPU from the containerd-shim-wasmtime shim, metrics-server scrapes it, and an autoscaling/v2 HPA scales the replica count between 1 and 5. Bottom, CRC: the wasmCloud operator reconciles one WasmCloudHostConfig into one host Deployment and one Pod, so an HPA has no per-component object to target; the lever is the spreadscaler trait on the cargo-http component, which changes the in-host instance count with no Pod change, while the httpserver provider stays on a daemonscaler so the operator keeps creating the Service the Route needs." caption="Figure 22.1: Two scaling levers: a Kubernetes HPA reading cgroup metrics on minikube, and a wadm spreadscaler changing the in-host instance count with no Pod churn on CRC." %}

## minikube: a Wasm Pod is a cgrouped Pod

`k8s/scaling/base/hpa.yaml` targets the existing `cargo-http` Deployment:

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

Nothing in it names Wasm or a shim. `containerd-shim-wasmtime` reports CPU into the cgroup hierarchy cAdvisor already reads for a `runc` Pod, the kubelet summary API exposes it, metrics-server scrapes it, and the HPA controller reads metrics-server.

`k8s/base/deployment.yaml` sets `resources.requests.cpu` to `50m`. Utilization is computed against the request, so a small request makes the 50% target easy to cross. `k8s/scaling/load/load-generator.yaml` supplies load inside the cluster: a `busybox` Deployment, shipped at `replicas: 0` so applying it never drives load by accident, running `CONCURRENCY` (default 8) parallel `wget` loops against the Service's in-cluster DNS name, never a port-forward.

### Why the scale-down window can shrink

`scaleDown.stabilizationWindowSeconds` is `60`, against the Kubernetes default of `300`. The default exists because a freshly scaled-out replica of a conventional workload is often not ready to absorb load when it reports `Ready`: a JVM is still warming its JIT and loading classes, a connection pool has not opened connections, and removing capacity too eagerly causes flapping. A Wasm component under `wasmtime` has no such phase. `containerd-shim-wasmtime` instantiates `app.wasm` and serves within milliseconds of `Ready`, so the long window is pure latency. The `policies` entry removes at most one Pod every 30 seconds, which keeps scale-down gradual. `scaleUp` keeps the default, no stabilization and fastest-wins, because fast scale-out is already right.

{% include excalidraw.html file="22-cold-start-scaling-math" alt="Timeline comparing scale-down stabilization windows. For a JVM-style container the HPA holds a 300 second default window because a new replica needs JIT and connection-pool warm-up. For the Wasm component the shim starts serving within milliseconds of the Pod reporting Ready, so hpa.yaml shortens the window to 60 seconds. The same fast start is what the KEDA HTTP add-on uses to scale from zero." caption="Figure 22.2: A conventional workload needs a long scale-down window for warm-up; a Wasm component starts serving within milliseconds of Ready, so the window can shrink." %}

The measurement below never reaches a scale-out, so this window goes unused here. The property still matters for any HPA fronting a Wasm Deployment, and it is most of what keeps a scale-from-zero cold start low in the KEDA HTTP add-on.

### What the measurement shows

`k8s/scaling/capture-hpa-evidence.sh` drives three load-generator replicas of 64 loops each (192 concurrent loops) and samples `cargo-http` every 20 seconds for two minutes:

| Observation | Value |
| --- | --- |
| Each load Pod's CPU | about 248m |
| `cargo-http` CPU | 1m, 2% of its 50m request, for the whole window |
| HPA target | `cpu: 2%/50%` |
| Replicas | 1 throughout |
| `ScalingActive` | `True` (`ValidMetricFound`) |

Right after the HPA is created it reports `ScalingActive=False` (`FailedGetResourceMetric`, "did not receive metrics for targeted pods") until metrics-server has scraped the new Pod; that is "nothing to read", not a Wasm problem. Once metrics arrive, the controller works as designed. It computes a replica count from real CPU data and arrives at 1, because 1 is what 2% against a 50% target gives. CPU is the wrong signal for a cheap, stateless Wasm handler: it does so little per request that 192 concurrent loops stay an order of magnitude below the target. A workload like this needs a signal that tracks what is scarce for it, in-flight request concurrency, which is what the KEDA HTTP add-on scales on, down to zero and back.

## CRC: the wadm spreadscaler

`openshift/wadm-scaled.yaml` deploys the same application as `wadm.yaml` with one change: the `cargo-http` component's trait is a `spreadscaler` with a templated `instances` count in place of a fixed `daemonscaler`:

```yaml
  components:
    - name: cargo-http
      type: component
      properties:
        # deploy.sh / verify-scaling-crc.sh rewrite __COMPONENT_REF__ -> the
        # pushed ghcr component ref (same image this app already runs).
        image: __COMPONENT_REF__
      traits:
        # spreadscaler, NOT daemonscaler: `instances` is the wadm-managed
        # component instance count inside the host pod, the autoscaling
        # lever. verify-scaling-crc.sh re-applies this manifest with
        # __INSTANCES__ set first to a scaled-up count, then back to 1, and
        # asserts the instance count read back from the Application changed
        # both times.
        - type: spreadscaler
          properties:
            instances: __INSTANCES__

    - name: httpserver
      type: capability
      properties:
        # Unchanged from wadm.yaml: same provider, same image.
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
        # Left as daemonscaler, unchanged: this is what makes the operator
        # create (and keep) the Service "cargo-http" on port 8000 that the
        # edge-TLS Route targets. See README.md "The daemonscaler edit".
        - type: daemonscaler
          properties:
            replicas: 1
```

The `spreadscaler` is the operator-aware lever because it is the same mechanism `wadm.yaml` uses to fix the instance count at deploy time. Applying the manifest with a different number is an update in place under the same Application name, a redeploy and not a new app. The operator does not expose instance count as a metric any Kubernetes controller could read.

The `httpserver` provider stays a `daemonscaler`, and that is required. The operator creates the Kubernetes Service for an application only when its `httpserver` provider uses a `daemonscaler`; Service creation for a `spreadscaler` is not implemented. Changing the provider's trait removes the Service that the edge-TLS Route depends on and breaks every external path, for no scaling benefit, since the provider is one listener regardless of how many `cargo-http` instances sit behind it.

Re-applying `wadm-scaled.yaml` at `instances` 1, then 4, then 1 changes the `instances` value on the `Application` object while the set of wasmCloud host Pods stays identical, and the Route keeps serving throughout. Traffic alone would not show where the scaling happened, because the operator could have rescheduled the host Pod; an unchanged Pod set shows the instance count moved inside it. Read the instance count back from the `Application`, not from host-log messages: their wording is not a stable, versioned contract.

## Why the substrates diverge

Each platform draws the boundary between "a Kubernetes object" and "a thing running inside one" in a different place. On minikube the Pod is the unit of scheduling and scaling, and the whole chain from cgroup to HPA already understands it. On CRC the operator inserts a second scheduling layer: the Pod is the unit of host lifecycle, and the component is a unit the host schedules inside it from the OAM manifest, with no Kubernetes object to represent it. The same layer lets the operator replace a deleted host Pod while `wadm` keeps the application's desired state, and it is what removes an HPA's target. Neither substrate is incomplete. Each scales the unit it schedules, a Pod on minikube and a lattice instance inside a Pod on CRC.

## When not to use it

- **CPU-based HPA for a cheap stateless handler.** Confirm the workload's CPU approaches the target under real load first; if it does not, scale on concurrency.
- **A Kubernetes HPA on an operator-managed host Deployment.** It scales hosts, not components.
- **Changing the `httpserver` provider's scaler to a `spreadscaler`.** The operator stops creating the Service.

> **Decision**
>
> Use a stock HPA when the Wasm workload is an ordinary Deployment, and check that its CPU actually approaches the target before trusting it: a correctly wired HPA reading a signal the workload never produces is not an autoscaler for that workload. Measure warm-up before copying a container's 300-second scale-down window. Use the operator's own scaler trait, here `spreadscaler` `instances`, when an operator owns the host Deployment, and before changing one of two traits in a manifest, check what the other is responsible for.

> **🤖 Explore with your agent**
>
> "In examples/part5-kubernetes, review k8s/scaling/base/hpa.yaml and openshift/wadm-scaled.yaml. Tell me, using the rule that you scale the unit the platform schedules, which lever applies to cargo-http on minikube and on CRC. Then change `SCALE_UP_INSTANCES` for openshift/verify-scaling-crc.sh to 6 and say what must stay unchanged in the cluster for the script to pass."
>
> Check: the reply should name the HPA for minikube and the `spreadscaler` `instances` field for CRC, and state that the wasmCloud host Pod set must stay identical.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s/scaling && ./capture-hpa-evidence.sh
```

The script brings up the `part5` minikube profile, builds and loads `app.wasm`, installs the `wasmtime` shim and `RuntimeClass`, applies the scaling overlay, drives 3 x 64 load loops, and records the measurement above under `k8s/evidence/`. Neither script enables `metrics-server`; enable it first with `minikube addons enable metrics-server -p part5`. `verify-hpa-minikube.sh` in the same directory runs the same load and prints `PASS` when the HPA is wired (`ScalingActive=True` with a numeric CPU utilization) and the Ingress still returns the exact cargo JSON once the load stops. It does not require a scale-out: under 50% it reports the no-signal finding, and at or above 50% it prints a note that the finding needs re-evaluation on that machine. Both scripts first delete any HPA, `HTTPScaledObject` or `ScaledObject` left on `cargo-http`, because KEDA's admission webhook refuses a workload that already has a plain HPA, and the reverse. On CRC, run `openshift/deploy.sh`, then `openshift/verify-scaling-crc.sh`, which prints `PASS` when the instance count cycles 1, 4, 1 with the Pod set unchanged and the Route serving the exact cargo JSON throughout.

Experiments:

- Set `LOAD_REPLICAS` and `LOAD_CONCURRENCY` (defaults 3 and 64) for `capture-hpa-evidence.sh` and compare the sampled CPU lines with the recorded 2% at 3 x 64.
- Change the `httpserver` trait in `wadm-scaled.yaml` to a `spreadscaler`: the operator no longer creates the Service the Route targets.

## For deeper coverage

- Bilgin Ibryam & Roland Huß, *Kubernetes Patterns*, 2nd ed. (O'Reilly, 2023), "Elastic Scale": the Horizontal Pod Autoscaler pattern and request sizing.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the instantiation cost model behind the cold-start figure.
- [Kubernetes: Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/): the `autoscaling/v2` API, utilization targets and `behavior` stabilization windows.
- [wasmCloud Kubernetes operator](https://wasmcloud.com/docs/deployment/k8s/operator): the `WasmCloudHostConfig` reconciliation into one host Deployment.
- [wasmCloud documentation](https://wasmcloud.com/docs/): the OAM Application model and the `spreadscaler` and `daemonscaler` traits.
- Wasm on Kubernetes: the four deployment paths and the operator fallback.
- Deploying on minikube: the containerd shim, the `cargo-http` Deployment and `runtimeClassName: wasmtime`.
- Deploying on OpenShift Local (CRC): the `WasmCloudHostConfig`, the `wadm.yaml` Application and host-Pod resilience.
- Wasm as a sidecar: per-invocation statelessness on the wasmCloud lattice.
- Serverless Wasm: scale-to-zero with KEDA: concurrency-based scaling that picks up where CPU finds no signal.

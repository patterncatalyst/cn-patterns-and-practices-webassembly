---
title: "Wasm on Kubernetes"
order: 17
part: "Deploying to Kubernetes"
description: "How a Wasm component runs on Kubernetes: the containerd Wasm shim that replaces runc for a Pod, the RuntimeClass that routes a Pod to it, how the shim gets onto a node, and where it sits among SpinKube, the wasmCloud operator and Krustlet."
duration: "15 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what a containerd shim is and why `containerd-shim-wasmtime` can replace `runc` for one Pod without changing kubelet or the scheduler.
- Name the field on each object (`RuntimeClass.handler`, `runtimeClassName`) that routes a Pod to the Wasm shim.
- Install the shim on a node in four steps, and say why registering the runtime restarts containerd and what that costs.
- Choose between a node-install script and a DaemonSet installer (KWasm, Runtime-Class-Manager) by who owns the node image.
- Place the containerd shim, SpinKube, the wasmCloud operator and Krustlet on one map by what each schedules and runs.

## Why this matters

Moving to a cluster doesn't change the component. `app.wasm` in `examples/part5-kubernetes/` is the same `wasi:http/incoming-handler` artifact that runs under `wasmtime serve` and on a wasmCloud lattice. What changes is who starts the process that runs it.

Kubernetes knows nothing about WebAssembly. It schedules Pods onto nodes and hands each Pod spec to the node's container runtime, containerd. Whether containerd turns the spec into a Linux container or a Wasm execution depends on the plugin it resolves for that Pod. That plugin is a **shim**, and the `runwasi` project supplies the scaffolding for Wasm shims.

The generic, vendor-neutral `containerd-shim-wasmtime` served the cargo component with no feature gap (the open runwasi issue #1004 tracks that class of gap), so the shim and `RuntimeClass` path is the primary mechanism here. The wasmCloud operator is the fallback for a cluster where the shim doesn't fit.

{% include excalidraw.html file="17-shim-and-runtimeclass-layering" alt="Two columns show kubelet scheduling the same kind of Pod. Left, no runtimeClassName: containerd resolves the runc handler, runc creates a Linux container with an OS userland, a language runtime and the app. Right, runtimeClassName wasmtime: containerd resolves the handler to runtime_type io.containerd.wasmtime.v1, containerd-shim-wasmtime-v1 starts, detects the wasi:http/incoming-handler export and runs wasmtime serve on 0.0.0.0:8080 against a scratch OCI image holding only a roughly 290 KiB app.wasm. A RuntimeClass object with handler wasmtime makes runtimeClassName a valid field value. A side note warns that installing the shim restarts containerd, which bounces every running Pod on the node." caption="Figure 17.1: The same kubelet and containerd node, forked onto runc or the Wasm shim by one Pod-spec field." %}

## The containerd Wasm shim

For a Linux container, containerd resolves the runtime handler to `runc`, which sets up namespaces, cgroups and a root filesystem and execs the entrypoint. A `.wasm` file has no rootfs to chroot into and no process to exec. Without a second runtime, a Wasm component can't be a Pod.

A **containerd shim** is the process containerd forks to run a workload. A Wasm shim runs the component's bytes in an embedded runtime with no Linux userland underneath.

`containerd-shim-wasmtime` does the job of `runc` in the same Pod lifecycle slot, except it runs the `wasmtime` embedding. The install script states the resolution chain:

```
# containerd resolves a CRI runtime of type `io.containerd.wasmtime.v1` to the
# binary `containerd-shim-wasmtime-v1` on its PATH; a Pod that sets
# `runtimeClassName: wasmtime` is then scheduled onto that shim, which detects
# our component targets wasi:http/proxy and serves it on 0.0.0.0:8080.
```

Two separate lookups happen here. The `runtime_type` (`io.containerd.wasmtime.v1`) is a string containerd maps to a binary on its `PATH` by convention: append `-v1`. The `handler` (`wasmtime`) is a shorter name that exists only at the Kubernetes API layer, carried by the `RuntimeClass` and referenced from a Pod's `runtimeClassName`. Nothing requires the two strings to match.

When the component exports `wasi:http/incoming-handler`, the shim runs it behind a built-in hyper server on `0.0.0.0:8080` in the Pod's network namespace, the same behavior as `wasmtime serve`. A component targeting `wasi:cli/run` gets a one-shot execution instead of a long-running server.

The shim binary is not a CLI. Invoking it with `--version`, or any flag it doesn't define, panics with `flag provided but not defined`, because it expects containerd's shim protocol on its file descriptors. Confirm it with `ls -l` and let the running Pod be the proof.

## RuntimeClass routes a Pod to the shim

`RuntimeClass` is a cluster-scoped object (`node.k8s.io/v1`) whose only spec is a `handler` string. It gives a Pod a name to reference instead of a containerd runtime string:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: wasmtime
handler: wasmtime
```

`handler` must match the CRI runtime key the install script registers in `/etc/containerd/config.toml`. The Deployment is the consumer side, and its Pod template sets one field beyond an ordinary workload:

```yaml
    spec:
      runtimeClassName: wasmtime
      containers:
        - name: cargo-http
          image: cargo-http-wasm:dev
          imagePullPolicy: IfNotPresent
          command: ["/app.wasm"]
```

The scheduler places the Pod as it always does; `RuntimeClass` doesn't change scheduling, though `scheduling.nodeSelector` on the object can restrict it to Wasm-capable nodes in a mixed cluster. Kubelet then hands the Pod to containerd with the resolved handler.

The component is packaged as a single-layer `scratch` OCI image (`FROM scratch; COPY app.wasm /app.wasm`), so `kubectl`, kustomize and registries treat it as an ordinary image until containerd hands it to the shim. The `Deployment`, `Service` and `Ingress` have nothing else Wasm-specific.

`RuntimeClass` alone buys nothing. `kubectl apply` creates only the API object and leaves containerd's configuration untouched. A Pod whose handler containerd can't resolve fails to start with a `RuntimeClass` resolution error and never falls back to `runc`. The object and the node installation both have to be true.

## Getting the shim onto a node

On a cluster where you can reach the node (minikube), `install-shim.sh` does four things:

1. Downloads the pinned shim tarball and verifies its SHA256 against the value in `lib.sh`.
2. Installs the extracted `containerd-shim-wasmtime-v1` at `/usr/bin` with mode `0755`.
3. Registers `io.containerd.wasmtime.v1` under the CRI plugin's runtimes table in `/etc/containerd/config.toml`, restarts containerd and waits for it to answer.
4. Applies the `RuntimeClass`.

The config edit is idempotent, and containerd restarts only when the config changed:

```bash
if grep -q 'containerd.runtimes.wasmtime\]' "$CFG"; then
  # Already registered: the config is unchanged, so DO NOT restart containerd.
  # An unconditional restart here needlessly bounces every running Pod on the
  # node, and a Wasm Pod that was mid-flight across the restart gets SIGKILLed
  # (exit 137) and wedges into CrashLoopBackOff. Re-running install-shim (e.g.
  # between Part 5 chapters) must be a no-op when nothing changed.
  echo "install-shim.sh(node): wasmtime runtime already registered, config unchanged, NOT restarting containerd"
else
  cp "$CFG" "${CFG}.bak.$(date +%s)"
  awk '
    { print }
    /\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\]/ {
      print "        [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.wasmtime]"
      print "          runtime_type = \"io.containerd.wasmtime.v1\""
    }
  ' "$CFG" > "${CFG}.new"
  mv "${CFG}.new" "$CFG"
  echo "install-shim.sh(node): inserted wasmtime runtime block:"
  grep -n 'wasmtime' "$CFG" || true
  echo "install-shim.sh(node): restarting containerd (config changed) ..."
  systemctl restart containerd
```

The restart is unavoidable: the CRI plugin reads its runtimes table at startup. It bounces every Pod on that node, and a Wasm Pod caught mid-flight is killed and can wedge in `CrashLoopBackOff`. So install the shim before other addons (ingress-nginx, a CNI) and pay the disruption once.

Editing `/etc/containerd/config.toml` over SSH works only on a node you fully control. On a managed cluster (EKS, GKE, AKS, OpenShift) the node image is the platform's, and a node image update reverts hand edits. The answer there is a DaemonSet installer: a Pod per matching node that mounts the host's `/etc/containerd` through a privileged `hostPath` volume and does the same install, edit and restart, then reconciles itself when a node is replaced. **KWasm** and its successor **Runtime-Class-Manager** ship a DaemonSet plus a small controller, install the shim and runtime registration on every labeled node, and apply the `RuntimeClass`.

| | Node-install script | DaemonSet installer |
| --- | --- | --- |
| Where it runs | Over SSH, once | In-cluster, per labeled node |
| Added to the cluster | Nothing | A controller (and a CRD for Runtime-Class-Manager) |
| Survives node replacement | No, re-run it | Yes |
| Easy to read and debug | Every step in one script | A reconciliation loop to reason about |
| Fits | One box you own end to end | A fleet you don't SSH into |

## The landscape: four projects, four scopes

The containerd shim isn't the only project putting WebAssembly inside Kubernetes. Each of the others answers a narrower or differently shaped question.

**SpinKube** ships `containerd-shim-spin`, built on runwasi with the same `RuntimeClass` pattern. It runs Spin applications (a `spin.toml` manifest, Spin triggers), not arbitrary `wasi:http/proxy` or `wasi:cli` components. It adds a `SpinApp` custom resource and a `spin-operator`, so a Spin app is its own Kubernetes object rather than a Deployment with a `runtimeClassName`. Components built straight against the WIT contract have no use for it.

**The wasmCloud operator** makes a whole wasmCloud host a Pod, and `wash` and `wadm` deploy applications onto that in-cluster lattice as they would anywhere. The component and `wadm.yaml` don't change; the host is now a Kubernetes workload supervised by the operator. It is the fallback when the raw shim hits a feature gap for a component, at the cost of carrying a lattice rather than a bare shim. It is also the mechanism for a cluster where node changes are off the table: on OpenShift Local, installing the shim needs a privileged RHCOS `MachineConfig`, which fights the `restricted-v2` security posture, so the operator runs an in-cluster wasmCloud host instead.

**Krustlet** is history. It implemented an alternative kubelet in Rust that registered as a node and ran WASI workloads directly, bypassing containerd, so every piece of node machinery that assumes a CRI-compliant runtime had to be reimplemented or worked around. Its maintainers archived it in 2022 in favor of the containerd-shim direction. Treat it as noise when it turns up in older articles.

{% include excalidraw.html file="17-wasm-on-kubernetes-landscape" alt="A table of four projects with mechanism and scope. runwasi containerd-shim-wasmtime: a generic containerd shim plus RuntimeClass, installed by a node script or DaemonSet installer, runs any wasi:http/proxy or wasi:cli component. SpinKube containerd-shim-spin: a shim plus a SpinApp CRD and spin-operator, scoped to Spin applications. wasmCloud operator: schedules a wasmCloud host as a Pod, then wadm deploys onto that in-cluster lattice; the fallback when the raw shim hits a gap. Krustlet, drawn dashed: a kubelet replacement running wasmtime or WAGI providers directly, archived in 2022. A footer says the four don't compete head-on; pick by what you deploy and what you control." caption="Figure 17.2: Four projects putting Wasm inside Kubernetes's scheduling model, each answering a differently scoped question." %}

> **Decision**
>
> Default to `containerd-shim-wasmtime`, a `RuntimeClass` and `runtimeClassName` when the component exports a world the shim supports (`wasi:http/proxy` or `wasi:cli/run` cover most services) and you own the node image, with a script on a small cluster or a DaemonSet installer on a fleet. It adds one binary per node and one `RuntimeClass`, and leaves `Deployment`, `Service` and `Ingress` unchanged. Reach for the wasmCloud operator when the workload needs the lattice (capability providers, declarative links, `wadm` self-healing), when a test against the raw shim shows a gap for the component's WASI imports, or when you can't change the node. Use SpinKube only for Spin applications. Don't use Krustlet.

> **🤖 Explore with your agent**
>
> "In examples/part5-kubernetes/k8s, read base/runtimeclass.yaml, base/deployment.yaml and install-shim.sh. Tell me which field on which object routes the Pod to the Wasm shim, which two strings must match for containerd to resolve the handler, and which step of install-shim.sh restarts containerd and why. Then say whether this cluster should use the node-install script or a DaemonSet installer if I don't own the node image."
>
> Check: the reply names `runtimeClassName: wasmtime` on the Deployment, `handler: wasmtime` on the RuntimeClass matching the key in `/etc/containerd/config.toml`, and the restart in step 3.

## Build, run, observe

```bash
cd examples/part5-kubernetes/k8s
PROFILE=part5 ./install-shim.sh
kubectl get runtimeclass wasmtime
```

`install-shim.sh` needs a running minikube profile. It prints `OK` once the shim is installed, the runtime registered and the `RuntimeClass` applied. The next chapter deploys the component and requests it end to end.

- Re-run `install-shim.sh`: the config is already registered, so containerd isn't restarted and running Pods stay up.
- Point `handler` at a name containerd has no registered runtime for: a Pod that references the class fails to start with a `RuntimeClass` resolution error rather than falling back to `runc`.
- Run `containerd-shim-wasmtime-v1 --version` on the node: it panics with `flag provided but not defined`.

## For deeper coverage

- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): how a host embeds `wasmtime`, and what a container-runtime integration like a containerd shim supplies that a library embedding doesn't.
- Shashank Jain, *WebAssembly for Cloud* (Apress): deployment patterns for Wasm workloads, including the orchestration surface a containerd shim sits under.
- [runwasi](https://github.com/containerd/runwasi): the shared containerd-shim scaffolding `containerd-shim-wasmtime` is built on, including the feature-gap issue #1004.
- [Kubernetes documentation, RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/): the object, including the `scheduling.nodeSelector` field for mixed-node clusters.
- [SpinKube documentation](https://www.spinkube.dev/): `containerd-shim-spin`, the `SpinApp` CRD and `spin-operator`.
- [wasmCloud documentation, Kubernetes](https://wasmcloud.com/docs/): the wasmCloud operator and deploying a `wadm` application onto an in-cluster lattice.
- HTTP from a component: the `wasi:http/proxy` world and `wasi:http/incoming-handler` export the shim drives the way `wasmtime serve` does.
- wasmtime: the embedding and `wasmtime serve` behavior the shim reproduces inside a Pod.
- wasmCloud: the lattice, `wadm` and capability-provider model the operator schedules into a cluster unchanged.
- Deploying on minikube: the full live deploy of this mechanism, with the Ingress request path and recorded evidence.
- OpenShift Local (CRC): the cluster where the wasmCloud operator fallback is the mechanism in use.
- cloud-native-design-patterns, the Kubernetes extension patterns: a `RuntimeClass` and shim pair as one case of pluggable node-level execution.

# ch26 Spin app on OpenShift Local (CRC): the container path

This is the OpenShift counterpart to the minikube SpinKube deploy one
directory up (`../base`, `../overlays`, which run `containerd-shim-spin` via
the `runtime-class-manager` Helm chart and a `SpinApp` custom resource). That
path needs a privileged RHCOS node install (the shim chart writes a
node-level containerd plugin and, on OpenShift, a `MachineConfig` that
restarts the node), and that fights the `restricted-v2` security posture CRC
chapters hold to. It is the same constraint ch18/ch19 already hit with the
raw `containerd-shim-wasmtime` path; there the substitute was the wasmCloud
*operator* running an in-cluster host
(`../../../part5-kubernetes/openshift/wasmcloud-host.yaml`).

Here the substitute is simpler: the Spin CLI itself (`spin up`) is the whole
runtime for `cargo-spin.wasm`, so an ordinary `Deployment` under
restricted-v2 is enough: no operator, no CRD, no node install.

```
ghcr.io/patterncatalyst/cargo-spin-runtime:crc  ──pulled by──▶  cargo-spin pod (restricted-v2)
  (debian:trixie-slim + spin v4.2.4 CLI                           │ spin up --listen 0.0.0.0:8080
   + cargo-spin.wasm + spin.toml, uid 10001)                      ▼
                                              Service cargo-spin:8080  ◀─ edge-TLS Route ◀─ curl --cacert
```

The image is built by `../../spin/Dockerfile` (owned by the Spin example
directory, not this one); see that directory's README for the build command
and the pinned `spin` v4.2.4 SHA-256. `contracts/wit` is untouched; this
chapter composes the Part 2 provider via `wac plug`, same as every earlier
runtime target.

## Run order (headless)

```bash
eval "$(crc oc-env)"
./openshift/deploy.sh             # project; ghcr-pull secret; Deployment/Service/Route; wait for 200
./openshift/verify-crc.sh         # CA-verified curl through the Route: JSON + 404 + resilience
./openshift/capture-evidence.sh   # re-runs verify + records evidence/<date>/
./openshift/teardown.sh           # remove everything (pass --stop-cluster to also crc stop)
```

The live bring-up/teardown of CRC itself is the orchestrator's call: `crc
start` before, `crc stop` only if `teardown.sh --stop-cluster` is used.

## restricted-v2 / SCC

Everything runs in the dedicated **`part6-spin`** project (a normal project,
so it is governed by `restricted-v2`: the `default` namespace is PodSecurity
`privileged` and would not prove anything).

`deployment.yaml` sets no `runAsUser` anywhere. The image's `USER 10001` (a
fixed, non-zero numeric uid) already satisfies the `runAsNonRoot: true`
admission check, and `restricted-v2` assigns its own uid from the project's
allocated SCC range at admission time: overriding the image's uid, the same
way it already does for the wasmCloud host container in
`../../../part5-kubernetes/openshift/wasmcloud-host.yaml` (that CRD also sets
no `securityContext`, for the identical reason). Pinning `runAsUser: 10001`
in the Deployment would fight that range instead of living inside it. The
rest of the posture is explicit: `allowPrivilegeEscalation: false`, every
capability dropped, `seccompProfile: RuntimeDefault`. No `anyuid`/`nonroot`
SCC exception is granted.

## The CA-verified curl (no -k, no port-forward, no NodePort)

Every HTTP assertion goes through the edge-TLS Route and is verified against
the cluster's own ingress CA, combined with the system trust store, the same
`combined_ca_bundle` helper as every other CRC chapter in this book:

```bash
# combined bundle = system trust store + the cluster ingress CA
oc get configmap default-ingress-cert -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}'   # appended to /etc/ssl/certs/ca-certificates.crt
curl --cacert <combined-bundle> https://cargo-spin-part6-spin.apps-crc.testing/cargo/CARGO-USNYC-DEHAM
```

The ingress CA **alone** is not enough: any other TLS the scripts do (e.g.
reaching ghcr) would then fail `UnknownIssuer`.

## What `verify-crc.sh` proves (live)

1. Readiness is a real **200** through the Route (the router reconciles its
   backend *after* the pod is Ready, "pod Ready" is not "serving").
2. `GET /cargo/CARGO-USNYC-DEHAM` returns the **exact** cargo JSON, the same
   bytes `spin up` serves locally (see `../../spin/README.md`, "Verify (no
   cluster)").
3. `GET /cargo/NOPE` returns **404**.
4. **Resilience:** delete the pod; the Deployment recreates it and traffic
   recovers to 200 with no redeploy.

## Teardown

`teardown.sh` removes the Route, Service, Deployment, the `ghcr-pull` secret
(unlinked from the default ServiceAccount), and the `part6-spin` project.
No CRDs, no operator, no PVCs: this stack is a plain Deployment, so cleanup
is correspondingly small. `crc stop` only runs with `--stop-cluster`.

## Evidence

`evidence/<YYYY-MM-DD>/` (committed): `00-versions`, `01-pods`,
`02-service-route`, `03-http`, `04-verify-crc.log`, `05-scrub`.

# shellcheck shell=bash
# examples/part5-kubernetes/openshift/lib.sh
#
# Shared helpers for the Part 5 OpenShift Local (CRC) scripts (sourced, not
# run). Every oc/helm call targets the "crc-admin" kubeconfig context that
# `crc start` writes — the kubeconfig's current-context is never read or
# changed — so no password is ever typed, printed or stored. Run
# `eval "$(crc oc-env)"` first if `oc` is not on PATH.
#
# This is the CRC counterpart to ../k8s/lib.sh (minikube + the raw containerd
# Wasm shim). Here the deploy mechanism is the wasmCloud *operator* instead of
# a node-level RuntimeClass/shim: the containerd-shim-wasmtime path needs a
# privileged RHCOS MachineConfig that fights restricted-v2, so on OpenShift we
# run an in-cluster wasmCloud host (managed by the operator) and deploy the
# SAME app.wasm onto it as a wadm OAM application — byte-for-byte the component
# Part 2/3/4 build (sha256 eff7f5ee…). contracts/wit stays pristine.
#
# Adapted from the worked CRC reference
# api-patterns-and-practices-websockets/examples/part4-backplane/openshift/lib.sh
# (require_crc / require_single_cluster / install_operator-style pinning /
# wait_route_serving / the combined-CA lesson), retargeted from Kafka+Helm-app
# to the wasmCloud platform chart + operator.

PROJECT="part5-kubernetes"
APP="cargo-http"                 # OAM Application name == the Service the operator creates
HOSTCFG="wasmcloud-host"         # WasmCloudHostConfig name
# Dedicated namespace (a normal project), so it is governed by restricted-v2 —
# the "default" namespace is PodSecurity "privileged" and would NOT prove
# restricted-v2 compliance. The chart hard-codes NATS DNS at *.default.svc, so
# values-crc.yaml and wasmcloud-host.yaml repoint every NATS address at
# *.$NS.svc.cluster.local to match.
NS="${PROJECT_NAMESPACE:-wasmcloud}"
RELEASE="${RELEASE:-wasmcloud-platform}"
OCP_CONTEXT="${OCP_CONTEXT:-crc-admin}"
OPENSHIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# openshift/ -> part5-kubernetes -> examples -> repo root
REPO_ROOT="$(cd "$OPENSHIFT_DIR/../../.." && pwd)"

# Pinned versions (surveyed live 2026-10-21; see README "Pinned versions").
#   wasmcloud-platform chart = 0.1.2 (the last tagged release of the now-archived
#     wasmCloud v1 chart; bundles nats 1.2.3, wadm 0.2.7, operator 0.1.5
#     [image 0.4.0], host subchart 0.8.4, appVersion/host 1.2.1).
#   wasmCloud host           = 1.9.1 (WasmCloudHostConfig .spec.version) — the
#     chart's default host 1.2.1 is too old for provider 0.27.0's wRPC protocol
#     (HTTP 500 "not connected"); 1.9.1 is Part 4's proven pairing.
#   httpserver provider      = ghcr.io/wasmcloud/http-server:0.27.0 (reused from
#                              part4-runtimes/wasmcloud/wadm.yaml)
CHART_VERSION="${CHART_VERSION:-0.1.2}"
CHART_REF="${CHART_REF:-oci://ghcr.io/wasmcloud/charts/wasmcloud-platform}"
WASMCLOUD_VERSION="${WASMCLOUD_VERSION:-1.9.1}"

# The deployable component, pushed to ghcr for the in-cluster host to pull.
# Private package + a docker-registry pull secret (ghcr-pull) referenced by the
# WasmCloudHostConfig — no public artifact is created, and no registry TLS/CA
# dance (ghcr is a real, publicly-trusted CA).
GHCR_OWNER="${GHCR_OWNER:-patterncatalyst}"
IMAGE_TAG="${IMAGE_TAG:-crc}"
COMPONENT_REF="${COMPONENT_REF:-ghcr.io/$GHCR_OWNER/cargo-http:$IMAGE_TAG}"
PULL_SECRET="${PULL_SECRET:-ghcr-pull}"

# The byte-for-byte component these scripts deploy (Part 2/3/4 identical).
EXPECTED_SHA="${EXPECTED_SHA:-eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3}"
APP_WASM="$OPENSHIFT_DIR/../app.wasm"

oc()   { command oc --context "$OCP_CONTEXT" "$@"; }
helm() { command helm --kube-context "$OCP_CONTEXT" "$@"; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \xe2\x9c\x93 %s\n' "$1"; }
warn() { printf '    ! %s\n' "$1" >&2; }
fail() { printf '\n\xe2\x9c\x97 %s\n' "$1" >&2; exit 1; }

# require_single_cluster: one local cluster at a time. A running minikube
# profile competes with the CRC VM for memory; stop it first.
require_single_cluster() {
    command -v minikube >/dev/null 2>&1 || return 0
    local running
    running="$(minikube profile list -o json 2>/dev/null \
        | python3 -I -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print("\n".join(p.get("Name","") for p in (d.get("valid") or []) if p.get("Status") in ("OK","Running")))' 2>/dev/null)"
    [[ -z "$running" ]] || fail "minikube profile(s) running: $running. Stop them first (minikube stop -p <profile>); run one cluster at a time"
}

# require_crc: oc on PATH, the crc-admin context reachable, and the API server
# is OpenShift Local's. Fails fast instead of touching another cluster.
require_crc() {
    command -v oc >/dev/null 2>&1 || fail "oc not on PATH: run eval \"\$(crc oc-env)\""
    command -v crc >/dev/null 2>&1 || fail "crc not on PATH"
    require_single_cluster
    crc status 2>/dev/null | grep -q 'OpenShift:.*Running' || fail "OpenShift Local is not running: crc start"
    command oc config get-contexts "$OCP_CONTEXT" >/dev/null 2>&1 \
        || fail "kubeconfig context $OCP_CONTEXT not found (crc start writes it)"
    local api
    api="$(oc whoami --show-server 2>/dev/null)" || fail "cannot reach the OpenShift API"
    [[ "$api" == *api.crc.testing* ]] || fail "context $OCP_CONTEXT points at $api, not OpenShift Local"
}

# wait_for <seconds> <description> <command...>: poll every 5 s until the
# command succeeds.
wait_for() {
    local timeout="$1" what="$2"; shift 2
    local waited=0
    until "$@" >/dev/null 2>&1; do
        (( waited >= timeout )) && fail "timed out after ${timeout}s waiting for $what"
        sleep 5; waited=$(( waited + 5 ))
    done
    ok "$what"
}

# combined_ca_bundle: write the system trust store PLUS the cluster's ingress CA
# to a temp file and echo its path. curl --cacert <that> verifies the edge-TLS
# Route cert against the cluster's OWN ingress CA while STILL trusting public
# CAs — never -k/--insecure. The combined-bundle lesson from the WebSockets CRC
# reference: the ingress CA ALONE would break any other TLS the script does.
# Caller is responsible for rm-ing the returned file.
combined_ca_bundle() {
    local ca sys combined
    ca="$(mktemp -t part5-crc-ingress-ca.XXXXXX.crt)"
    oc get configmap default-ingress-cert -n openshift-config-managed \
        -o jsonpath='{.data.ca-bundle\.crt}' > "$ca" 2>/dev/null \
        || { rm -f "$ca"; return 1; }
    [[ -s "$ca" ]] || { rm -f "$ca"; return 1; }
    sys=""
    local c
    for c in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
             /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
        [[ -r "$c" ]] && { sys="$c"; break; }
    done
    combined="$(mktemp -t part5-crc-combined-ca.XXXXXX.crt)"
    { [[ -n "$sys" ]] && cat "$sys"; echo; cat "$ca"; } > "$combined"
    rm -f "$ca"
    echo "$combined"
}

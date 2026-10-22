# shellcheck shell=bash
# examples/part6-deviations/spinkube/openshift/lib.sh
#
# Shared helpers for the ch26 Spin-on-CRC scripts (sourced, not run). Every
# oc call targets the "crc-admin" kubeconfig context that `crc start` writes —
# the kubeconfig's current-context is never read or changed — so no password
# is ever typed, printed or stored. Run `eval "$(crc oc-env)"` first if `oc`
# is not on PATH.
#
# Adapted verbatim (require_crc / require_single_cluster / wait_for /
# combined_ca_bundle) from ../../../part5-kubernetes/openshift/lib.sh, which
# itself traces to the worked CRC reference
# api-patterns-and-practices-websockets/examples/part4-backplane/openshift/lib.sh.
# No SpinKube/wasmCloud-operator concepts here: this stack is a plain
# Deployment + Service + Route (./deployment.yaml, ./service.yaml,
# ./route.yaml) running the Spin CLI itself inside a restricted-v2 container
# (../../spin/Dockerfile) — the containerd-shim-spin path needs a privileged
# RHCOS node install that restricted-v2 forbids, the same constraint ch18/
# ch19 already worked around with the wasmCloud operator instead of the raw
# wasmtime shim.
PROJECT="part6-spin"
APP="cargo-spin"             # Deployment, Service, and Route all named this
NS="${PROJECT_NAMESPACE:-part6-spin}"
OCP_CONTEXT="${OCP_CONTEXT:-crc-admin}"
OPENSHIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# openshift/ -> spinkube -> part6-deviations -> examples -> repo root
REPO_ROOT="$(cd "$OPENSHIFT_DIR/../../.." && pwd)"

# The runtime image built by ../../spin/Dockerfile: debian:trixie-slim + the
# pinned spin v4.2.4 CLI + cargo-spin.wasm + spin.toml, non-root numeric uid
# 10001, ENTRYPOINT `spin up --listen 0.0.0.0:8080 -f /app/spin.toml`.
GHCR_OWNER="${GHCR_OWNER:-patterncatalyst}"
IMAGE_TAG="${IMAGE_TAG:-crc}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-ghcr.io/$GHCR_OWNER/cargo-spin-runtime:$IMAGE_TAG}"
PULL_SECRET="${PULL_SECRET:-ghcr-pull}"

# The canonical cargo record every example in this book serves, byte-for-byte
# — the same value ../../../part5-kubernetes/openshift/verify-crc.sh checks.
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

oc() { command oc --context "$OCP_CONTEXT" "$@"; }

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

# combined_ca_bundle: write the system trust store PLUS the cluster's ingress
# CA to a temp file and echo its path. curl --cacert <that> verifies the
# edge-TLS Route cert against the cluster's OWN ingress CA while STILL
# trusting public CAs — never -k/--insecure. Caller is responsible for rm-ing
# the returned file.
combined_ca_bundle() {
    local ca sys combined
    ca="$(mktemp -t part6-spin-crc-ingress-ca.XXXXXX.crt)"
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
    combined="$(mktemp -t part6-spin-crc-combined-ca.XXXXXX.crt)"
    { [[ -n "$sys" ]] && cat "$sys"; echo; cat "$ca"; } > "$combined"
    rm -f "$ca"
    echo "$combined"
}

# wait_route_serving <host> <path>: block until the router serves a 200 on
# <path> through <host>, CA-verified against the combined bundle in $CA
# (caller must have set CA via combined_ca_bundle first). 503/000 means the
# backend is not (re)wired yet — "pod Ready" is not "Route serving".
wait_route_serving() {
    local host="$1" path="$2" waited=0 code
    while (( waited < 180 )); do
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$CA" \
            "https://$host$path" 2>/dev/null)" || true
        [[ -z "$code" ]] && code=000
        [[ "$code" == "200" ]] && { ok "Route serving (HTTP 200) on $path after ${waited}s"; return 0; }
        sleep 5; waited=$(( waited + 5 ))
    done
    fail "Route https://$host$path still not 200 after ${waited}s (last '$code')"
}

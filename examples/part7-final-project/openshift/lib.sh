# shellcheck shell=bash
# examples/part7-final-project/openshift/lib.sh
#
# Shared helpers for the Part 7 final project's REDUCED OpenShift Local (CRC)
# pass (sourced, not run). Every oc/helm call targets the "crc-admin"
# kubeconfig context `crc start` writes — the kubeconfig's current-context is
# never read or changed — so no password is ever typed, printed or stored.
# Run `eval "$(crc oc-env)"` first if `oc` is not on PATH.
#
# Reduced scope vs. minikube: both language composites (cargo-rust.wasm,
# cargo-go.wasm) deployed via the wasmCloud operator — the SAME Part 5/Ch19
# CRC tier — fronted by edge-TLS Routes. NO service mesh on CRC; the ch25
# Istio proxy-wasm gateway filter and the Ch23 KEDA scale-to-zero pass stay
# minikube-only for this project (build-plan.md r08).
#
# Byte-for-byte reuse of examples/part5-kubernetes/openshift/lib.sh's
# conventions (require_crc / require_single_cluster / combined_ca_bundle /
# wait_for / the oc+helm context wrappers / step/ok/warn/fail), retargeted
# from ONE component to TWO. That file stays untouched — this is a sibling,
# not an edit.

PROJECT="part7-final-project"
APP="cargo-final"                # OAM Application name == the Service name the operator creates
HOSTCFG="wasmcloud-host"         # WasmCloudHostConfig name
# A dedicated namespace distinct from Part 5's "wasmcloud" project, so this
# reduced pass can run standalone (its own restricted-v2 enforcement; no
# collision with a Part 5 deploy left running in the same cluster).
NS="${PROJECT_NAMESPACE:-wasmcloud-final}"
RELEASE="${RELEASE:-wasmcloud-platform}"
OCP_CONTEXT="${OCP_CONTEXT:-crc-admin}"
OPENSHIFT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# openshift/ -> part7-final-project -> examples -> repo root
REPO_ROOT="$(cd "$OPENSHIFT_DIR/../../.." && pwd)"

# Pinned versions — the firm Part 5/Ch19 CRC tier, reused as-is (build-plan.md
# r08: "No new version pins ... CRC 2.64.0/OCP 4.22.14, wasmcloud-platform
# chart 0.1.2"). See examples/part5-kubernetes/openshift/README.md "Pinned
# versions" for the full survey.
CHART_VERSION="${CHART_VERSION:-0.1.2}"
CHART_REF="${CHART_REF:-oci://ghcr.io/wasmcloud/charts/wasmcloud-platform}"
WASMCLOUD_VERSION="${WASMCLOUD_VERSION:-1.9.1}"
HTTPSERVER_PROVIDER="${HTTPSERVER_PROVIDER:-ghcr.io/wasmcloud/http-server:0.27.0}"

# The two deployable composites, pushed to private ghcr for the in-cluster
# host to pull — same private-package + pull-secret pattern as Ch19, no public
# artifact and no registry-TLS dance (ghcr chains to a public CA).
GHCR_OWNER="${GHCR_OWNER:-patterncatalyst}"
IMAGE_TAG="${IMAGE_TAG:-crc-final}"
RUST_REF="${RUST_REF:-ghcr.io/$GHCR_OWNER/cargo-rust:$IMAGE_TAG}"
GO_REF="${GO_REF:-ghcr.io/$GHCR_OWNER/cargo-go:$IMAGE_TAG}"
PULL_SECRET="${PULL_SECRET:-ghcr-pull}"

# The two httpserver listen ports — one per language — so both components can
# coexist on one in-cluster host pod without fighting over a socket.
RUST_PORT="${RUST_PORT:-8000}"
GO_PORT="${GO_PORT:-8001}"

# The byte-for-byte composites this script deploys. cargo-rust.wasm is the
# same composite Part 4/Part 5 already deploy as app.wasm (sha256 eff7f5ee…).
# cargo-go.wasm is recorded at Part 7 r08 authoring time — rebuild with
# ../build.sh if the Go toolchain changes and this sha needs to move.
RUST_WASM="$OPENSHIFT_DIR/../cargo-rust.wasm"
GO_WASM="$OPENSHIFT_DIR/../cargo-go.wasm"
EXPECTED_RUST_SHA="${EXPECTED_RUST_SHA:-eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3}"
EXPECTED_GO_SHA="${EXPECTED_GO_SHA:-17b0fca2f591650d89ee2f854ac9af1dfd6fccee17dacec9417bc2dfbb439839}"

# The canonical cargo contract (byte-identical across both languages).
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'
VALID_PATH="/cargo/CARGO-USNYC-DEHAM"
NOPE_PATH="/cargo/NOPE"

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
# is OpenShift Local's. Fails fast instead of touching another cluster. Never
# starts or stops the cluster itself.
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
    ca="$(mktemp -t part7-crc-ingress-ca.XXXXXX.crt)"
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
    combined="$(mktemp -t part7-crc-combined-ca.XXXXXX.crt)"
    { [[ -n "$sys" ]] && cat "$sys"; echo; cat "$ca"; } > "$combined"
    rm -f "$ca"
    echo "$combined"
}

# curl_code_ca <ca> <url>: HTTP status only, CA-verified (never -k). 000 on failure.
curl_code_ca() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --cacert "$1" "$2" 2>/dev/null || echo 000
}
# curl_body_ca <ca> <url>: response body, CA-verified.
curl_body_ca() {
    curl -sS --max-time 15 --cacert "$1" "$2" 2>/dev/null || true
}

# route_host <route-name>: the edge-TLS Route host (empty if no route yet).
route_host() { oc get route "$1" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null; }

# wait_route_serving <ca> <host> <path> [timeout]: block until the router
# serves a 200 on <path>, CA-verified. 503/000 means the backend is not
# (re)wired yet — readiness is a real 200 through the Route, not just "pod
# Ready", because the router reconciles its backend AFTER the pod is Ready.
wait_route_serving() {
    local ca="$1" host="$2" path="$3" timeout="${4:-240}" waited=0 code
    while (( waited < timeout )); do
        code="$(curl_code_ca "$ca" "https://$host$path")"
        [[ "$code" == "200" ]] && { ok "https://$host$path -> 200 after ${waited}s"; return 0; }
        sleep 5; waited=$(( waited + 5 ))
    done
    fail "https://$host$path still not 200 after ${waited}s (last '$code'); oc get pods,svc,ep,route -n $NS"
}

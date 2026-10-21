# shellcheck shell=bash
# examples/part5-kubernetes/openshift/lib-interposed.sh
#
# Shared config + helpers for the ch20/ch21 INTERPOSED deploy on OpenShift Local
# (CRC), expressed as the RUNTIME-LINK form: the provider, the interposer and the
# HTTP front door run as THREE separate wasmCloud components wired by wadm links
# at runtime (instead of one `wac plug` composite as on minikube). This file is
# sourced, never run. It layers on top of the r06b lib.sh (require_crc /
# combined_ca_bundle / the oc+helm context wrappers / step/ok/warn/fail /
# wait_for / NS / GHCR_OWNER / IMAGE_TAG / PULL_SECRET / OPENSHIFT_DIR /
# REPO_ROOT) — lib.sh stays byte-for-byte pristine.
#
# The link graph the manifests encode (verified live, see README-interposed.md):
#
#   httpserver (provider)  --wasi:http/incoming-handler-->  front door (component)
#   front door             --patterncatalyst:cargo/booking--> interposer (component)
#   interposer             --patterncatalyst:cargo/booking,handling--> provider
#
# Only `booking` carries the functions the /cargo path exercises; `types` is a
# pure type interface (no functions, so nothing to link), and the front door does
# not import `handling` at all — so the front door -> interposer link is `booking`
# only. See the "front door imports only booking" gotcha.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# --- The three (four, counting both interposers) separate component images ------
# Each raw per-component .wasm (NOT a wac-plug composite) is pushed to private
# ghcr with `wash push`; the in-cluster host pulls them with the ghcr-pull secret
# that deploy.sh/deploy-interposed.sh create (reused from r06b).
PROVIDER_REF="${PROVIDER_REF:-ghcr.io/$GHCR_OWNER/cargo-provider:$IMAGE_TAG}"
FRONTDOOR_REF="${FRONTDOOR_REF:-ghcr.io/$GHCR_OWNER/cargo-frontdoor:$IMAGE_TAG}"
FILTER_REF="${FILTER_REF:-ghcr.io/$GHCR_OWNER/cargo-filter:$IMAGE_TAG}"
ADAPTER_REF="${ADAPTER_REF:-ghcr.io/$GHCR_OWNER/cargo-adapter:$IMAGE_TAG}"

# --- Where the raw component wasms are produced (cargo component build) ---------
PART2_RUST_DIR="$OPENSHIFT_DIR/../../part2-building-components/rust"
PART3_HTTP_DIR="$OPENSHIFT_DIR/../../part3-interfaces/http-rust"
FILTER_DIR="$OPENSHIFT_DIR/../sidecar-filter"
ADAPTER_DIR="$OPENSHIFT_DIR/../adapter"

# --- OAM Application names (== the operator-created Service == the Route) -------
FILTERED_APP="${FILTERED_APP:-cargo-filtered}"
ADAPTED_APP="${ADAPTED_APP:-cargo-adapted}"
AMB_APP="${AMB_APP:-cargo-ambassador}"
AMB_NOGRANT_APP="${AMB_NOGRANT_APP:-cargo-ambassador-nogrant}"

# Distinct httpserver listen ports so the three provider instances can coexist in
# one in-cluster host pod without fighting over a socket. The operator creates one
# Service per app on that app's listen port.
FILTERED_PORT="${FILTERED_PORT:-8000}"
ADAPTED_PORT="${ADAPTED_PORT:-8001}"
AMB_PORT="${AMB_PORT:-8002}"
AMB_NOGRANT_PORT="${AMB_NOGRANT_PORT:-8003}"

# The exact contract response (same bytes across Parts 2-5) and the paths.
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'
VALID_PATH="/cargo/CARGO-USNYC-DEHAM"
EMBARGO_PATH="/cargo/CARGO-USNYC-CUHAV"
NOPE_PATH="/cargo/NOPE"

# find_wasm <dir> <basename>: locate a cargo-component build output, excluding deps.
find_wasm() {
    find "$1/target" -name "$2" -not -path '*/deps/*' 2>/dev/null | head -1
}

# build_raw_components: (re)build the four raw per-component wasms. Idempotent;
# cargo skips unchanged crates. Does NOT wac-plug — these are the SEPARATE
# components the lattice links at runtime.
build_raw_components() {
    for d in "$PART2_RUST_DIR" "$PART3_HTTP_DIR" "$FILTER_DIR" "$ADAPTER_DIR"; do
        ( cd "$d" && cargo component build --release ) >/dev/null 2>&1 \
            || fail "cargo component build failed in $d"
    done
    PROVIDER_WASM="$(find_wasm "$PART2_RUST_DIR" cargo_rust.wasm)"
    FRONTDOOR_WASM="$(find_wasm "$PART3_HTTP_DIR" cargo_http_rust.wasm)"
    FILTER_WASM="$(find_wasm "$FILTER_DIR" cargo_filter_rust.wasm)"
    ADAPTER_WASM="$(find_wasm "$ADAPTER_DIR" cargo_adapter_rust.wasm)"
    for v in PROVIDER_WASM FRONTDOOR_WASM FILTER_WASM ADAPTER_WASM; do
        [[ -s "${!v}" ]] || fail "$v not produced"
    done
}

# push_component <ref> <wasm>: push a raw component to private ghcr via wash.
# $GH_TOKEN must be set by the caller (gh auth token).
push_component() {
    local ref="$1" wasm="$2"
    wash push "$ref" "$wasm" --user "$GHCR_OWNER" --password "$GH_TOKEN" >/dev/null \
        || fail "wash push $ref failed"
    ok "pushed $ref ($(sha256sum "$wasm" | awk '{print $1}' | cut -c1-12)...)"
}

# route_host <app>: the edge-TLS Route host for an app (empty if no route yet).
route_host() { oc get route "$1" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null; }

# curl_code_ca <ca> <url>: HTTP status only, CA-verified (never -k). 000 on failure.
curl_code_ca() {
    curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --cacert "$1" "$2" 2>/dev/null || echo 000
}
# curl_body_ca <ca> <url>: response body, CA-verified.
curl_body_ca() {
    curl -sS --max-time 15 --cacert "$1" "$2" 2>/dev/null || true
}

# wait_route_code <ca> <host> <path> <expected> [timeout]: poll the edge Route
# until it returns <expected> on <path>, CA-verified. Returns non-zero on timeout.
wait_route_code() {
    local ca="$1" host="$2" path="$3" want="$4" timeout="${5:-180}" waited=0 code
    while (( waited < timeout )); do
        code="$(curl_code_ca "$ca" "https://$host$path")"
        [[ "$code" == "$want" ]] && { ok "https://$host$path -> $want after ${waited}s"; return 0; }
        sleep 5; waited=$(( waited + 5 ))
    done
    warn "https://$host$path never returned $want within ${timeout}s (last '$code')"
    return 1
}

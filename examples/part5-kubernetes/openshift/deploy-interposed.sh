#!/usr/bin/env bash
#
# deploy-interposed.sh — deploy the ch20/ch21 interposition patterns onto the
# in-cluster wasmCloud host on OpenShift Local (CRC) as the RUNTIME-LINK form:
# the provider, the interposer and the HTTP front door run as THREE SEPARATE
# wasmCloud components, wired by wadm links at runtime (not one `wac plug`
# composite). Run after install-operator.sh.
#
# Brings up three coexisting apps, each its own operator-created Service + edge-TLS
# Route (distinct httpserver ports so the providers share one host pod):
#   cargo-filtered    (ch20)  :8000
#   cargo-adapted     (ch21)  :8001
#   cargo-ambassador  (ch21)  :8002
#
# Steps per app: build+push the raw components, create the ghcr pull secret, apply
# the WasmCloudHostConfig, then sed the ghcr refs into the manifest, apply it, wait
# for the operator Service, put an edge-TLS Route in front, and wait until the
# router serves a real CA-verified 200 on the cargo path.
#
# Idempotent. Never starts/stops the cluster.
#
#   eval "$(crc oc-env)"
#   ./openshift/install-operator.sh
#   ./openshift/deploy-interposed.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-interposed.sh"

require_crc
for t in wash gh oc; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

# ---------------------------------------------------------------------------
step "1/5 Build the four RAW per-component wasms (no wac plug)"
build_raw_components
ok "provider $(sha256sum "$PROVIDER_WASM" | awk '{print $1}' | cut -c1-12)... / front door $(sha256sum "$FRONTDOOR_WASM" | awk '{print $1}' | cut -c1-12)... / filter $(sha256sum "$FILTER_WASM" | awk '{print $1}' | cut -c1-12)... / adapter $(sha256sum "$ADAPTER_WASM" | awk '{print $1}' | cut -c1-12)..."

# ---------------------------------------------------------------------------
step "2/5 Push the separate components to private ghcr"
GH_TOKEN="$(gh auth token 2>/dev/null)" || fail "gh auth token failed (gh auth status)"
[[ -n "$GH_TOKEN" ]] || fail "empty gh token"
push_component "$PROVIDER_REF"  "$PROVIDER_WASM"
push_component "$FRONTDOOR_REF" "$FRONTDOOR_WASM"
push_component "$FILTER_REF"    "$FILTER_WASM"
push_component "$ADAPTER_REF"   "$ADAPTER_WASM"

# ---------------------------------------------------------------------------
step "3/5 ghcr pull secret ($PULL_SECRET) in $NS"
oc create secret docker-registry "$PULL_SECRET" \
    --docker-server=ghcr.io --docker-username="$GHCR_OWNER" --docker-password="$GH_TOKEN" \
    -n "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null \
    || fail "create pull secret"
ok "pull secret $PULL_SECRET applied"

# ---------------------------------------------------------------------------
step "4/5 WasmCloudHostConfig -> wasmCloud host pod"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/wasmcloud-host.yaml" >/dev/null || fail "apply WasmCloudHostConfig"
wait_for 300 "host Deployment created" oc get deploy "$HOSTCFG" -n "$NS"
oc rollout status "deploy/$HOSTCFG" -n "$NS" --timeout=300s >/dev/null \
    || fail "host $HOSTCFG did not roll out (oc get pods -n $NS)"
ok "wasmCloud host $HOSTCFG ready"

# ---------------------------------------------------------------------------
# deploy_linked_app <manifest> <app> <port>: sed the ghcr refs into the manifest,
# apply it, wait for the operator Service, create the edge-TLS Route, and wait for
# a real CA-verified 200 on the cargo path.
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$CA" "${TMP_FILES[@]}"' EXIT
TMP_FILES=()

deploy_linked_app() {
    local manifest="$1" app="$2" port="$3"
    local tmp; tmp="$(mktemp -t "part5-crc-$app.XXXXXX.yaml")"; TMP_FILES+=("$tmp")
    sed -e "s|__PROVIDER_REF__|$PROVIDER_REF|g" \
        -e "s|__FRONTDOOR_REF__|$FRONTDOOR_REF|g" \
        -e "s|__FILTER_REF__|$FILTER_REF|g" \
        -e "s|__ADAPTER_REF__|$ADAPTER_REF|g" \
        "$OPENSHIFT_DIR/$manifest" > "$tmp"
    oc apply -n "$NS" -f "$tmp" >/dev/null || fail "apply $app"
    ok "wadm Application $app applied"
    wait_for 300 "operator created Service $app" oc get svc "$app" -n "$NS"
    local svc_port; svc_port="$(oc get svc "$app" -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
    ok "Service $app on port ${svc_port:-$port}"
    if ! oc get route "$app" -n "$NS" >/dev/null 2>&1; then
        oc create route edge "$app" --service="$app" --port="${svc_port:-$port}" -n "$NS" >/dev/null \
            || fail "create edge Route $app"
    fi
    local host; host="$(route_host "$app")"
    [[ -n "$host" ]] || fail "Route $app has no host"
    ok "edge-TLS Route https://$host/"
    # Readiness = the full runtime-link chain is live end to end. An unknown id
    # drives front door -> (interposer ->) provider across the cargo wRPC links and
    # comes back as the provider's own NotFound -> 404, which proves every link is
    # wired and the provider is reachable. (The exact-JSON 200 is NOT a valid gate
    # here: the front door's book-then-get round-trip needs shared provider state,
    # which per-invocation component instantiation does not preserve across a
    # runtime link — see README-interposed.md "the state gotcha".)
    wait_route_code "$CA" "$host" "$NOPE_PATH" 404 240 \
        || fail "Route $app never served 404 on $NOPE_PATH (oc get pods,svc,ep,route -n $NS)"
}

step "5/5 Deploy the three linked apps (filtered / adapted / ambassador)"
deploy_linked_app wadm-filtered.yaml   "$FILTERED_APP" "$FILTERED_PORT"
deploy_linked_app wadm-adapted.yaml    "$ADAPTED_APP"  "$ADAPTED_PORT"
deploy_linked_app wadm-ambassador.yaml "$AMB_APP"      "$AMB_PORT"

printf '\n    next: ./openshift/verify-interposed-crc.sh\n'

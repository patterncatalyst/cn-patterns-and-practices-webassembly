#!/usr/bin/env bash
#
# verify-scaling-crc.sh — ch22 autoscaler asymmetry, CRC HALF.
#
# This is the OpenShift counterpart to ../k8s/scaling/verify-hpa-minikube.sh,
# and it proves the OPPOSITE of that script on purpose.
#
# On minikube, cargo-http is a plain Kubernetes Deployment (runtimeClassName:
# wasmtime just redirects the Pod to a different shim), so a stock
# autoscaling/v2 HorizontalPodAutoscaler reading metrics-server scales its
# replica count exactly like any other workload.
#
# On OpenShift Local here, the wasmCloud OPERATOR owns the workload: it
# reconciles ONE WasmCloudHostConfig into ONE host Deployment/Pod (see
# verify-crc.sh's resilience proof, which deletes THAT pod), and the component
# instance count inside that pod is managed by wadm's OAM scaler trait, not by
# Kubernetes. A HorizontalPodAutoscaler has nothing correct to point at:
#   * pointed at the host Deployment, it would fight the operator for control
#     of a field the operator already reconciles, and scaling it would add
#     MORE HOSTS (lattice nodes), not more cargo-http instances;
#   * there is no per-component Kubernetes object to scale at all — the
#     component runs as an in-process instance inside the host pod.
#
# So the lever here is wadm-scaled.yaml's `spreadscaler` `instances` count,
# re-applied under the SAME Application name ("cargo-http") that deploy.sh
# already deployed — a wadm update-in-place, not a new app. This script proves
# the asymmetry two ways:
#   1. The DESIRED instance count really changes (oc get application.core.oam.dev
#      jsonpath on the just-applied spec) each time the manifest is re-applied.
#   2. The set of Kubernetes Pods for the wasmCloud host does NOT change at
#      all across the whole 1 -> N -> 1 cycle — zero Pod churn, unlike the
#      minikube half where `kubectl get deploy` visibly climbs. That absence
#      IS the asymmetry; this script asserts it, not just claims it.
#   3. Traffic through the edge-TLS Route (CA-verified, never -k, never
#      port-forward) stays a 200 across every redeploy — a wadm instances
#      change must not be visible to callers.
#
# Host-log evidence of the actual wadm/host-runtime reconciliation (component
# scale-up/scale-down messages) is captured for the record but is NOT a
# pass/fail gate here: wasmCloud host/operator log wording is not a stable,
# versioned contract this script can assert against, and capture-scaling-
# evidence.sh (not this script) is where that best-effort capture belongs.
#
# Prerequisite: ./openshift/deploy.sh has already deployed "cargo-http" (host
# + pull secret + Service + Route all exist). This script does NOT start/stop
# the cluster and does NOT run install-operator.sh / deploy.sh.
#
#   eval "$(crc oc-env)"
#   ./openshift/verify-scaling-crc.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
for t in wash gh oc curl python3; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

SCALE_UP_INSTANCES="${SCALE_UP_INSTANCES:-4}"

# ---------------------------------------------------------------------------
step "0/5 Preflight: the base app is already deployed"
HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$HOST" ]] || fail "Route $APP not found in $NS — run ./openshift/deploy.sh first"
ok "edge-TLS Route https://$HOST/"

CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
tmp_wadm=""
cleanup() { rm -f "$CA" "$tmp_wadm"; }
trap cleanup EXIT
https() { curl -sS --max-time 15 --cacert "$CA" "$@"; }

# wait_route_serving <path> — block until the router serves a 200 on <path>.
wait_route_serving() {
    local path="$1" waited=0 code
    while (( waited < 120 )); do
        code="$(https -o /dev/null -w '%{http_code}' "https://$HOST$path" 2>/dev/null)" || true
        [[ -z "$code" ]] && code=000
        [[ "$code" == "200" ]] && { ok "Route serving (HTTP 200) on $path after ${waited}s"; return 0; }
        sleep 3; waited=$(( waited + 3 ))
    done
    fail "Route https://$HOST$path still not 200 after ${waited}s (last '$code')"
}

# host_pods — the wasmCloud host Pod name(s), one per line, sorted. Used to
# assert ZERO Kubernetes Pod churn across a wadm instances change.
host_pods() {
    oc get pods -n "$NS" -l "app.kubernetes.io/name=$HOSTCFG" -o name 2>/dev/null | sort
}

# applied_instances — the `instances` value wadm currently has on record for
# the cargo-http component's spreadscaler trait (the DESIRED count we just
# applied, read back from the cluster object, not from our own variable).
applied_instances() {
    oc get application.core.oam.dev "$APP" -n "$NS" \
        -o jsonpath='{.spec.components[?(@.name=="cargo-http")].traits[?(@.type=="spreadscaler")].properties.instances}' 2>/dev/null
}

# apply_scaled <instances>: sed-template wadm-scaled.yaml (same pattern
# deploy.sh uses for __COMPONENT_REF__) and apply it as an update-in-place to
# the SAME Application name.
apply_scaled() {
    local instances="$1"
    tmp_wadm="$(mktemp -t part5-crc-wadm-scaled.XXXXXX.yaml)"
    sed -e "s|__COMPONENT_REF__|$COMPONENT_REF|g" -e "s|__INSTANCES__|$instances|g" \
        "$OPENSHIFT_DIR/wadm-scaled.yaml" > "$tmp_wadm"
    oc apply -n "$NS" -f "$tmp_wadm" >/dev/null || fail "apply wadm-scaled.yaml (instances=$instances)"
    rm -f "$tmp_wadm"; tmp_wadm=""
    local got; got="$(applied_instances)"
    [[ "$got" == "$instances" ]] || fail "wadm Application $APP: expected instances=$instances on record, got '${got:-<empty>}'"
    ok "wadm Application $APP updated in place: cargo-http spreadscaler instances=$got"
}

# ---------------------------------------------------------------------------
step "1/5 Baseline: switch cargo-http to the spreadscaler trait at instances=1"
BEFORE_PODS="$(host_pods)"
[[ -n "$BEFORE_PODS" ]] || fail "no wasmCloud host Pod found in $NS (is the host up? run ./openshift/deploy.sh)"
apply_scaled 1
wait_route_serving "/cargo/CARGO-USNYC-DEHAM"
AFTER_BASELINE_PODS="$(host_pods)"
[[ "$BEFORE_PODS" == "$AFTER_BASELINE_PODS" ]] \
    || fail "host Pod set changed just from the scaler-type switch (unexpected): before=[$BEFORE_PODS] after=[$AFTER_BASELINE_PODS]"
ok "host Pod set unchanged after switching to spreadscaler: $AFTER_BASELINE_PODS"

# ---------------------------------------------------------------------------
step "2/5 Scale OUT: wadm instances 1 -> $SCALE_UP_INSTANCES"
apply_scaled "$SCALE_UP_INSTANCES"
wait_route_serving "/cargo/CARGO-USNYC-DEHAM"
SCALED_PODS="$(host_pods)"
[[ "$AFTER_BASELINE_PODS" == "$SCALED_PODS" ]] \
    || fail "ASYMMETRY BROKEN — scaling wadm instances to $SCALE_UP_INSTANCES changed the Kubernetes Pod set (before=[$AFTER_BASELINE_PODS] after=[$SCALED_PODS]); expected ZERO Pod churn (the component scales INSIDE the existing host pod, not via new Pods)"
ok "ZERO Kubernetes Pod churn while wadm instances went 1 -> $SCALE_UP_INSTANCES: $SCALED_PODS"

step "3/5 Traffic survives the scale-out (CA-verified, through the Route)"
body="$(https "https://$HOST/cargo/CARGO-USNYC-DEHAM")" || fail "curl failed"
[[ "$body" == "$EXPECTED_JSON" ]] || { printf 'expected: %s\n     got: %s\n' "$EXPECTED_JSON" "$body" >&2; fail "cargo JSON mismatch after scale-out"; }
ok "GET /cargo/CARGO-USNYC-DEHAM returned the exact cargo JSON at instances=$SCALE_UP_INSTANCES"
code="$(https -o /dev/null -w '%{http_code}' "https://$HOST/cargo/NOPE")"
[[ "$code" == "404" ]] || fail "GET /cargo/NOPE returned $code, expected 404"
ok "GET /cargo/NOPE -> 404 at instances=$SCALE_UP_INSTANCES"

# ---------------------------------------------------------------------------
step "4/5 Scale back IN: wadm instances $SCALE_UP_INSTANCES -> 1"
apply_scaled 1
wait_route_serving "/cargo/CARGO-USNYC-DEHAM"
FINAL_PODS="$(host_pods)"
[[ "$BEFORE_PODS" == "$FINAL_PODS" ]] \
    || fail "host Pod set differs from the original baseline after scaling back down (before=[$BEFORE_PODS] final=[$FINAL_PODS])"
ok "host Pod set unchanged across the whole 1 -> $SCALE_UP_INSTANCES -> 1 wadm cycle: $FINAL_PODS"

step "5/5 Traffic survives the scale-in (CA-verified, through the Route)"
body="$(https "https://$HOST/cargo/CARGO-USNYC-DEHAM")" || fail "curl failed"
[[ "$body" == "$EXPECTED_JSON" ]] || { printf 'expected: %s\n     got: %s\n' "$EXPECTED_JSON" "$body" >&2; fail "cargo JSON mismatch after scale-in"; }
ok "GET /cargo/CARGO-USNYC-DEHAM returned the exact cargo JSON back at instances=1"

echo
echo "PASS — Part 5 ch22 autoscaler asymmetry on OpenShift Local (CRC):" \
     "the wadm spreadscaler took cargo-http's instance count 1 -> $SCALE_UP_INSTANCES -> 1" \
     "with the Route serving the exact cargo JSON throughout and ZERO Kubernetes" \
     "Pod churn — the opposite of the minikube half, where a stock HPA visibly" \
     "changes \`kubectl get deploy\` replicas. A K8s HPA has nothing correct to" \
     "target here; wadm is the lever."
echo "exit 0"

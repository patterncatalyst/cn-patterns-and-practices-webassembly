#!/usr/bin/env bash
#
# deploy.sh — deploy the ch26 Spin app on OpenShift Local (CRC): the Spin
# runtime (`spin up`) inside a plain restricted-v2 container, fronted by an
# edge-TLS Route. No SpinKube/shim/CRD/operator — see README.md for why.
#
# Steps:
#   1. Create/switch to the part6-spin project (a normal project, so it is
#      governed by restricted-v2 — the "default" namespace is PodSecurity
#      "privileged" and would NOT prove anything).
#   2. Create the ghcr-pull docker-registry secret from `gh auth token` and
#      link it to the default ServiceAccount (belt-and-braces alongside the
#      Deployment's own imagePullSecrets).
#   3. Apply deployment.yaml + service.yaml + route.yaml; wait for rollout.
#   4. Wait until the Route actually serves a real 200 on the cargo path (the
#      router reconciles its backend AFTER the pod is Ready).
#
# Idempotent. Never starts/stops the cluster.
#
#   eval "$(crc oc-env)"
#   ./openshift/deploy.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
for t in gh oc curl; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

# ---------------------------------------------------------------------------
step "1/4 Project $NS"
if oc get project "$NS" >/dev/null 2>&1; then
    ok "project $NS already exists"
else
    oc new-project "$NS" >/dev/null || fail "oc new-project $NS"
    ok "project $NS created"
fi

# ---------------------------------------------------------------------------
step "2/4 ghcr pull secret ($PULL_SECRET) in $NS, linked to default SA"
TOKEN="$(gh auth token 2>/dev/null)" || fail "gh auth token failed (gh auth status)"
[[ -n "$TOKEN" ]] || fail "empty gh token"
oc create secret docker-registry "$PULL_SECRET" \
    --docker-server=ghcr.io --docker-username="$GHCR_OWNER" --docker-password="$TOKEN" \
    -n "$NS" --dry-run=client -o yaml | oc apply -f - >/dev/null \
    || fail "create pull secret"
oc secrets link default "$PULL_SECRET" --for=pull -n "$NS" >/dev/null \
    || fail "link pull secret to default SA"
ok "pull secret $PULL_SECRET applied and linked"

# ---------------------------------------------------------------------------
step "3/4 Deployment + Service + Route"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/deployment.yaml" >/dev/null || fail "apply deployment.yaml"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/service.yaml" >/dev/null || fail "apply service.yaml"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/route.yaml" >/dev/null || fail "apply route.yaml"
oc rollout status "deploy/$APP" -n "$NS" --timeout=300s >/dev/null \
    || fail "$APP did not roll out (oc get pods -n $NS; oc describe deploy/$APP -n $NS)"
ok "Deployment $APP ready"

HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$HOST" ]] || fail "Route $APP has no host"
ok "edge-TLS Route https://$HOST/"

# ---------------------------------------------------------------------------
step "4/4 Wait for the Route to serve a real 200"
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$CA"' EXIT
wait_route_serving "$HOST" "/cargo/CARGO-USNYC-DEHAM"

printf '    next: ./openshift/verify-crc.sh\n'

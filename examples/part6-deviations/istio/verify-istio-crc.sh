#!/usr/bin/env bash
#
# examples/part6-deviations/istio/verify-istio-crc.sh
#
# Applies the ch25 Istio manifests (openshift/gateway.yaml,
# openshift/virtualservice.yaml, openshift/route.yaml into the app's
# namespace/istio-system as noted per-file, plus openshift/wasmplugin.yaml
# into istio-system — the GATEWAY's namespace, not the app's) on top of an
# ALREADY-RUNNING Part 5 wasmCloud deployment + OSSM3 install
# (../../part5-kubernetes/openshift/install-operator.sh + deploy.sh, then
# ./install-ossm.sh), and proves, LIVE, through a real edge-TLS Route
# (CA-verified against the cluster's own ingress CA, never -k, never
# port-forward):
#
#   1. GET /cargo/CARGO-USNYC-DEHAM WITHOUT x-cargo-tenant -> 403 (the
#      proxy-wasm filter denies).
#   2. GET /cargo/CARGO-USNYC-DEHAM WITH x-cargo-tenant: acme -> 200, the EXACT
#      cargo JSON, AND a response header x-cargo-filtered-by: cargo-wasmfilter
#      (proof the filter ran, not just that the app answered).
#
# NO SIDECAR: same gateway-level design as ../verify-istio-minikube.sh (see
# ../gateway-wasmplugin.yaml and ../README-istio.md) — the proxy-wasm filter
# loads into the istio-ingressgateway's own Envoy via openshift/wasmplugin.yaml,
# in istio-system. This script never labels the wasmCloud namespace for
# injection and never rolls deploy/$HOSTCFG to pick up a sidecar; it stays an
# ordinary operator-managed Deployment with no mesh-sidecar container.
#
# AUTHOR-ONLY (this BUILD pass does not touch a cluster): a later live-verify
# pass runs this and commits the evidence.
#
# Does NOT start/stop the cluster, does NOT install the wasmCloud platform or
# OSSM3 — run ../../part5-kubernetes/openshift/install-operator.sh + deploy.sh,
# then ./install-ossm.sh, first.
#
#   eval "$(crc oc-env)"
#   ./verify-istio-crc.sh
set -uo pipefail
OPENSHIFT_ISTIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../part5-kubernetes/openshift/lib.sh
source "$OPENSHIFT_ISTIO_DIR/../../part5-kubernetes/openshift/lib.sh"

require_crc
for t in oc curl; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'
CARGO_PATH="/cargo/CARGO-USNYC-DEHAM"

step "0/5 Preflight: the wasmCloud app + OSSM3 control plane are up"
oc get "deploy/$HOSTCFG" -n "$NS" >/dev/null 2>&1 \
    || fail "deploy/$HOSTCFG not found in $NS — run ../../part5-kubernetes/openshift/deploy.sh first"
oc get deploy istiod -n istio-system >/dev/null 2>&1 \
    || fail "istiod not found in istio-system — run ./install-ossm.sh first"
ok "wasmCloud app + Istio control plane present"
echo "    expect READY 1/1 below (pure wasmCloud-host container, no istio-proxy sidecar):"
oc get pods -n "$NS" -l "app.kubernetes.io/name=$HOSTCFG" \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready' 2>/dev/null || true

step "1/5 Apply the ch25 manifests (idempotent): Gateway + VirtualService in $NS, WasmPlugin + Route in istio-system"
oc apply -n "$NS" -f "$OPENSHIFT_ISTIO_DIR/openshift/gateway.yaml" >/dev/null || fail "apply gateway.yaml"
oc apply -n "$NS" -f "$OPENSHIFT_ISTIO_DIR/openshift/virtualservice.yaml" >/dev/null || fail "apply virtualservice.yaml"
oc create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username=patterncatalyst \
    --docker-password="$(gh auth token)" \
    -n istio-system \
    --dry-run=client -o yaml | oc apply -f - >/dev/null || fail "apply ghcr-pull secret in istio-system"
oc apply -n istio-system -f "$OPENSHIFT_ISTIO_DIR/openshift/wasmplugin.yaml" >/dev/null || fail "apply wasmplugin.yaml"
oc apply -n istio-system -f "$OPENSHIFT_ISTIO_DIR/openshift/route.yaml" >/dev/null || fail "apply route.yaml"
ok "Gateway + VirtualService + WasmPlugin (gateway-scoped) + Route applied"

step "2/5 Resolve the live Route host, patch Gateway + VirtualService to match"
HOST="$(oc get route cargo-http-istio -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$HOST" ]] || fail "Route cargo-http-istio has no host (oc get route -n istio-system)"
oc patch gateway.networking.istio.io cargo-http-gateway -n "$NS" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/servers/0/hosts/0\",\"value\":\"$HOST\"}]" >/dev/null \
    || fail "patch Gateway host"
oc patch virtualservice.networking.istio.io cargo-http -n "$NS" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/hosts/0\",\"value\":\"$HOST\"}]" >/dev/null \
    || fail "patch VirtualService host"
ok "edge-TLS Route https://$HOST/ -> Gateway/VirtualService re-pointed"

step "3/5 Wait for the gateway to pick up the WasmPlugin"
oc -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s >/dev/null \
    || fail "istio-ingressgateway did not report ready"
ok "istio-ingressgateway ready"

CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle (is the Route serving yet?)"
trap 'rm -f "$CA"' EXIT
https() { curl -sS --max-time 15 --cacert "$CA" "$@"; }

step "4/5 WITHOUT x-cargo-tenant -> expect 403 (the filter denies)"
waited=0
code=""
while (( waited < 180 )); do
    code="$(https -o /dev/null -w '%{http_code}' "https://$HOST$CARGO_PATH" 2>/dev/null)"
    [[ -z "$code" ]] && code=000
    { [[ "$code" == "403" ]] || [[ "$code" == "200" ]]; } && break
    sleep 5; waited=$(( waited + 5 ))
done
[[ "$code" == "403" ]] || fail "GET $CARGO_PATH without x-cargo-tenant returned '$code' after ${waited}s, expected 403 (filter not attached yet? check: oc get wasmplugin -n istio-system, oc get pods -n istio-system)"
ok "GET $CARGO_PATH (no x-cargo-tenant) -> 403 after ${waited}s"

step "5/5 WITH x-cargo-tenant: acme -> expect 200 + exact JSON + x-cargo-filtered-by header"
tmp_body="$(mktemp -t istio-crc-body.XXXXXX)"
trap 'rm -f "$CA" "$tmp_body"' EXIT
headers="$(https -D - -o "$tmp_body" -H 'x-cargo-tenant: acme' "https://$HOST$CARGO_PATH")" || fail "curl failed"
body="$(cat "$tmp_body")"
echo "$headers" | grep -qi '^HTTP/.* 200' || fail "GET $CARGO_PATH with x-cargo-tenant did not return 200 (headers above)"
echo "$headers" | grep -qi '^x-cargo-filtered-by: *cargo-wasmfilter' \
    || fail "response missing 'x-cargo-filtered-by: cargo-wasmfilter' header — filter did not run"
[[ "$body" == "$EXPECTED_JSON" ]] || fail "cargo JSON mismatch: expected '$EXPECTED_JSON', got '$body'"
ok "GET $CARGO_PATH (x-cargo-tenant: acme) -> 200, exact cargo JSON, x-cargo-filtered-by: cargo-wasmfilter"

echo
echo "PASS — ch25 Istio + Wasm on OpenShift Local (CRC, OSSM3/Sail operator):" \
     "the proxy-wasm filter, running in the istio-ingressgateway's own Envoy" \
     "(no sidecar), denied the request without x-cargo-tenant (403) and, with" \
     "it, added x-cargo-filtered-by before proxying on to the same" \
     "wasmCloud-hosted cargo-http app, which answered with the exact cargo" \
     "JSON -- through a real edge-TLS Route, CA-verified, never -k, never" \
     "port-forward."
echo "exit 0"

#!/usr/bin/env bash
# examples/part6-deviations/istio/verify-istio-minikube.sh
#
# Applies the ch25 Istio overlay (overlays/minikube, which layers
# base/wasmplugin.yaml + base/gateway.yaml + base/virtualservice.yaml on TOP of
# the EXISTING Part 5 cargo-http Deployment/Service/RuntimeClass) onto an
# ALREADY-RUNNING Part 5 minikube profile with Istio installed
# (../../part5-kubernetes/k8s/verify-minikube.sh --keep, then
# ./istio-install.sh), and proves, LIVE, through the istio-ingressgateway's
# NodePort + a nip.io-style host (NO port-forward):
#
#   1. GET /cargo/CARGO-USNYC-DEHAM WITHOUT x-cargo-tenant -> 403 (the
#      proxy-wasm filter denies).
#   2. GET /cargo/CARGO-USNYC-DEHAM WITH x-cargo-tenant: acme -> 200, the EXACT
#      cargo JSON, AND a response header x-cargo-filtered-by: cargo-wasmfilter
#      (proof the filter ran, not just that the app answered).
#
# AUTHOR-ONLY (this BUILD pass does not touch a cluster): a later live-verify
# pass runs this for real and commits the evidence.
#
# Does NOT start/stop minikube, does NOT install Istio — run
# ../../part5-kubernetes/k8s/verify-minikube.sh --keep then ./istio-install.sh
# first.
#
# Usage: PROFILE=part5 NAMESPACE=part5-kubernetes ./verify-istio-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../part5-kubernetes/k8s/lib.sh
source "$SCRIPT_DIR/../../part5-kubernetes/k8s/lib.sh"

CARGO_PATH="/cargo/CARGO-USNYC-DEHAM"

for tool in kubectl curl; do require_cmd "$tool"; done

step "0/6 Preflight: Part 5 app + Istio control plane are up"
kubectl get deployment/cargo-http -n "$NAMESPACE" >/dev/null 2>&1 \
  || { echo "verify-istio-minikube.sh: FAIL — deployment/cargo-http not found in $NAMESPACE (run ../../part5-kubernetes/k8s/verify-minikube.sh --keep first)" >&2; exit 1; }
kubectl get deployment/istiod -n istio-system >/dev/null 2>&1 \
  || { echo "verify-istio-minikube.sh: FAIL — istiod not found in istio-system (run ./istio-install.sh first)" >&2; exit 1; }
echo "verify-istio-minikube.sh: Part 5 app + Istio control plane present"

step "1/6 Apply the ch25 overlay (WasmPlugin + Gateway + VirtualService on the existing app)"
kubectl apply -k "$SCRIPT_DIR/overlays/minikube"

step "2/6 Roll cargo-http so the sidecar webhook + WasmPlugin attach"
kubectl rollout restart deployment/cargo-http -n "$NAMESPACE"
kubectl rollout status deployment/cargo-http -n "$NAMESPACE" --timeout=180s
echo "verify-istio-minikube.sh: expect READY 2/2 below (app container + istio-proxy sidecar)"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=cargo-http \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready'

step "3/6 Resolve the istio-ingressgateway NodePort + minikube ip; patch Gateway/VirtualService host"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
NODE_PORT="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
[[ -n "$NODE_PORT" ]] || { echo "verify-istio-minikube.sh: FAIL — istio-ingressgateway has no NodePort for port 'http2' (is it type NodePort? see istio-install.sh step 4)" >&2; exit 1; }
CARGO_HOST="cargo-istio.${MINIKUBE_IP}.nip.io"
echo "verify-istio-minikube.sh: minikube ip = $MINIKUBE_IP; istio-ingressgateway NodePort (http2) = $NODE_PORT"
echo "verify-istio-minikube.sh: cargo gateway host = http://${CARGO_HOST}:${NODE_PORT}/"
kubectl patch gateway cargo-http-gateway -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/servers/0/hosts/0\",\"value\":\"$CARGO_HOST\"}]"
kubectl patch virtualservice cargo-http -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/hosts/0\",\"value\":\"$CARGO_HOST\"}]"

# Every request below targets the raw minikube-ip:nodeport URL with an explicit
# Host header — this is the SAME vhost-matching mechanism nip.io DNS resolution
# would produce, but it does not depend on an external DNS lookup succeeding
# during the live run.
GW_URL="http://${MINIKUBE_IP}:${NODE_PORT}${CARGO_PATH}"

step "4/6 Wait for the gateway to actually route (readiness = a real response, not just Ready)"
waited=0
while (( waited < 120 )); do
  code="$(curl_code "$GW_URL" "$CARGO_HOST")"
  { [[ "$code" == "403" ]] || [[ "$code" == "200" ]]; } && break
  sleep 3; waited=$(( waited + 3 ))
done
{ [[ "$code" == "403" ]] || [[ "$code" == "200" ]]; } \
  || { echo "verify-istio-minikube.sh: FAIL — gateway never routed within ${waited}s (last code '$code')" >&2; exit 1; }
echo "verify-istio-minikube.sh: gateway routing confirmed after ${waited}s (code $code)"

step "5/6 WITHOUT x-cargo-tenant -> expect 403 (the filter denies)"
code="$(curl_code "$GW_URL" "$CARGO_HOST")"
assert_eq "403" "$code" "minikube GET $CARGO_PATH (no x-cargo-tenant) through the istio gateway"

step "6/6 WITH x-cargo-tenant: acme -> expect 200 + exact JSON + x-cargo-filtered-by header"
tmp_body="$(mktemp -t istio-mk-body.XXXXXX)"
register_cleanup "rm -f '$tmp_body'"
headers="$(curl -sS -D - -o "$tmp_body" --max-time 8 -H "Host: $CARGO_HOST" -H 'x-cargo-tenant: acme' "$GW_URL")"
body="$(cat "$tmp_body")"
echo "$headers" | grep -qi '^HTTP/.* 200' \
  || { echo "verify-istio-minikube.sh: FAIL — expected 200 with x-cargo-tenant, got headers:" >&2; echo "$headers" >&2; exit 1; }
echo "$headers" | grep -qi '^x-cargo-filtered-by: *cargo-wasmfilter' \
  || { echo "verify-istio-minikube.sh: FAIL — missing 'x-cargo-filtered-by: cargo-wasmfilter' response header (filter did not run):" >&2; echo "$headers" >&2; exit 1; }
assert_eq "$EXPECTED_JSON" "$body" "minikube GET $CARGO_PATH (x-cargo-tenant: acme) through the istio gateway"

echo
echo "PASS — ch25 Istio + Wasm on minikube (docker+containerd, Istio layered on the Part 5 profile):"
echo "  the proxy-wasm filter denied the request without x-cargo-tenant (403) and,"
echo "  with it, Envoy's injected sidecar added x-cargo-filtered-by before the SAME"
echo "  Component-Model cargo-http app (under containerd-shim-wasmtime) answered"
echo "  with the exact cargo JSON -- through the istio-ingressgateway NodePort +"
echo "  a nip.io-style host, no port-forward."
echo "exit 0"

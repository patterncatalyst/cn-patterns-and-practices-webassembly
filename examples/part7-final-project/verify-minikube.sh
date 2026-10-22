#!/usr/bin/env bash
# examples/part7-final-project/verify-minikube.sh
#
# Deploys BOTH halves of the final project's two-language assembly
# (cargo-rust.wasm, cargo-go.wasm — ../build.sh) to the SAME minikube profile
# Part 5 and ch25 already use ("part5", docker driver + containerd runtime),
# fronts them with the ch25 Istio gateway filter (the proxy-wasm WasmPlugin
# loaded into the istio-ingressgateway's own Envoy), wires the containerd
# wasmtime shim's OTel export into the shared otel-lgtm sink, and proves all
# of it live:
#
#   1. Through the plain ingress-nginx edge, both languages answer the EXACT
#      same cargo JSON byte-for-byte (the two-language-one-contract thesis)
#      and 404 on an unknown id.
#   2. Through the Istio gateway edge, the x-cargo-tenant contract holds for
#      BOTH languages: 403 without the header, 200 + x-cargo-filtered-by with
#      it — the ONE shared filter gates traffic to either backend.
#   3. The containerd shim emitted at least one trace per service, readable
#      from Tempo with no port-forward (bounded trace scope — see Step 14 below for
#      exactly what this does and does not prove).
#
# Request paths proven (NO port-forward, NO `minikube service`; the Istio
# edge uses a NodePort for istio-ingressgateway, the same documented exception
# ch25's own verify-istio-minikube.sh already uses, because the `demo`
# profile's istio-ingressgateway Service is type LoadBalancer and stays
# <pending> on minikube's docker driver without a separate `minikube tunnel`):
#
#   curl -> cargo-rust.<ip>.nip.io / cargo-go.<ip>.nip.io  (ingress-nginx)
#        -> Service cargo-rust|cargo-go:8080 -> Pod (runtimeClassName: wasmtime)
#        -> containerd-shim-wasmtime -> cargo-rust.wasm | cargo-go.wasm
#
#   curl -> <minikube-ip>:<NodePort> + Host: cargo-rust-istio.../cargo-go-istio...
#        -> istio-ingressgateway Envoy (proxy-wasm cargo-wasmfilter, AUTHZ)
#        -> Service cargo-rust|cargo-go:8080 -> Pod -> shim -> composite
#
# Idempotent and self-contained: starts the profile if needed, builds + loads
# both images, installs the shim, enables shim OTel export BEFORE any
# (re)deploy (restarting containerd bounces every Pod on the node — see
# ../part5-kubernetes/k8s/observability/enable-shim-otel.sh), deploys the
# otel-lgtm sink + both app overlays, installs Istio + the gateway filter,
# force-deletes both app Pods so their shims are started AFTER every
# containerd-affecting step above, then asserts.
#
# Usage:
#   ./verify-minikube.sh            # full run; tears the profile down at the end
#   ./verify-minikube.sh --keep     # leave the profile running
#   KUBERNETES_VERSION=v1.37.1 ./verify-minikube.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PART5_K8S="$(cd "$SCRIPT_DIR/../part5-kubernetes/k8s" && pwd)"
PART6_ISTIO="$(cd "$SCRIPT_DIR/../part6-deviations/istio" && pwd)"
# shellcheck source=../part5-kubernetes/k8s/lib.sh
source "$PART5_K8S/lib.sh"

# This unit's own app namespace — distinct from lib.sh's $NAMESPACE
# (part5-kubernetes), which stays the home of the shared otel-lgtm sink and
# the original Part 5 / ch25 objects. See k8s/base/namespace.yaml.
APP_NS="part7-final-project"
CARGO_PATH="/cargo/CARGO-USNYC-DEHAM"

KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h|--help) echo "Usage: $0 [--keep]"; exit 0 ;;
    *) echo "verify-minikube.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

for tool in minikube kubectl docker curl python3; do
  require_cmd "$tool"
done

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "verify-minikube.sh: --keep set — leaving profile '$PROFILE' running" >&2
  else
    echo "verify-minikube.sh: tearing down minikube profile '$PROFILE'" >&2
    minikube delete -p "$PROFILE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# urlencode / http_in_pod — same Tempo-via-kubectl-exec pattern as
# ../part5-kubernetes/k8s/observability/verify-otel-minikube.sh: no
# port-forward, no Grafana UI, a plain GET against the otel-lgtm Pod's own
# localhost ports from inside its network namespace.
# ---------------------------------------------------------------------------
urlencode() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

http_in_otel_pod() {
  local otel_pod="$1" url="$2"
  kubectl exec -n "$NAMESPACE" "$otel_pod" -- sh -c \
    'if command -v curl >/dev/null 2>&1; then curl -sS "$0"; else wget -qO- "$0"; fi' \
    "$url"
}

# tempo_trace_count <otel-pod> <service-name> — number of distinct traceIDs
# Tempo currently holds for that resource.service.name.
tempo_trace_count() {
  local otel_pod="$1" svc="$2"
  local q url json
  q="{resource.service.name=\"${svc}\"}"
  url="http://127.0.0.1:3200/api/search?q=$(urlencode "$q")&limit=200"
  json="$(http_in_otel_pod "$otel_pod" "$url" || true)"
  printf '%s' "$json" | grep -o '"traceID"' | wc -l | tr -d ' '
}

step "Step 0: tool + version checks"
mk_ver="$(minikube version --short 2>/dev/null || echo v0.0.0)"
[[ "$(printf '%s\n%s\n' "$MINIKUBE_MIN" "$mk_ver" | sort -V | head -1)" == "$MINIKUBE_MIN" ]] \
  || { echo "verify-minikube.sh: FAIL — minikube $mk_ver older than required $MINIKUBE_MIN" >&2; exit 1; }
echo "verify-minikube.sh: minikube $mk_ver OK (>= $MINIKUBE_MIN); shim $SHIM_VERSION; Kubernetes $KUBERNETES_VERSION"

step "Step 1: minikube profile '$PROFILE' (docker driver, containerd, Kubernetes $KUBERNETES_VERSION) — shared with Part 5/ch25"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "verify-minikube.sh: profile '$PROFILE' already running — reusing it"
else
  minikube start -p "$PROFILE" \
    --driver=docker \
    --container-runtime=containerd \
    --kubernetes-version="$KUBERNETES_VERSION"
fi
kubectl get nodes

step "Step 2: build both composites + OCI images, load both into the node (no registry)"
"$SCRIPT_DIR/build.sh" --load
assert_file "$SCRIPT_DIR/cargo-rust.wasm" "cargo-rust.wasm"
assert_file "$SCRIPT_DIR/cargo-go.wasm" "cargo-go.wasm"
echo "verify-minikube.sh: cargo-rust:final + cargo-go:final loaded into profile '$PROFILE'"

step "Step 3: install the runwasi wasmtime shim + RuntimeClass (idempotent; restarts containerd only if the runtime is not yet registered)"
PROFILE="$PROFILE" "$PART5_K8S/install-shim.sh"

step "Step 4: ingress-nginx addon"
minikube addons enable ingress -p "$PROFILE"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

step "Step 5: deploy the shared otel-lgtm sink (if not already up)"
kubectl apply -k "$SCRIPT_DIR/k8s/observability/overlays/minikube"
kubectl rollout status deployment/otel-lgtm -n "$NAMESPACE" --timeout=240s

step "Step 6: point the containerd shim at otel-lgtm — BEFORE (re)deploying either app (restarts containerd)"
# Same ordering gotcha ch24 documents: a shim already running when this env
# changes does not retroactively pick it up, so this MUST run before the app
# overlays below, and both app Pods are force-deleted again in Step 8 to
# guarantee a fresh shim regardless of what was already running from an
# earlier invocation of this idempotent script.
PROFILE="$PROFILE" "$PART5_K8S/observability/enable-shim-otel.sh"
# That restart bounces ingress-nginx too; re-confirm it is routing before
# deploying on top of it.
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

step "Step 7: deploy both app overlays (cargo-rust + cargo-go, namespace $APP_NS)"
kubectl apply -k "$SCRIPT_DIR/k8s/overlays/minikube"
kubectl rollout status deployment/cargo-rust -n "$APP_NS" --timeout=180s
kubectl rollout status deployment/cargo-go -n "$APP_NS" --timeout=180s
kubectl get pods -n "$APP_NS" -o wide

step "Step 8: install Istio (idempotent) + apply the ch25 gateway filter (unchanged) + both Istio objects"
if kubectl get deployment/istiod -n istio-system >/dev/null 2>&1; then
  echo "verify-minikube.sh: istiod already present — reusing the existing Istio control plane"
else
  PROFILE="$PROFILE" "$PART6_ISTIO/istio-install.sh"
fi
kubectl apply -k "$SCRIPT_DIR/istio/overlays/minikube"
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=patterncatalyst \
  --docker-password="$(gh auth token)" \
  -n istio-system \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$SCRIPT_DIR/istio/gateway-wasmplugin.yaml"
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s

step "Step 9: force-delete both app Pods so their shims start AFTER every containerd-affecting step above"
kubectl delete pod -n "$APP_NS" -l app.kubernetes.io/name=cargo-rust --ignore-not-found >/dev/null
kubectl delete pod -n "$APP_NS" -l app.kubernetes.io/name=cargo-go --ignore-not-found >/dev/null
kubectl rollout status deployment/cargo-rust -n "$APP_NS" --timeout=180s
kubectl rollout status deployment/cargo-go -n "$APP_NS" --timeout=180s
kubectl get pods -n "$APP_NS" -o wide

step "Step 10: resolve + patch both ingress-nginx hosts + both Istio hosts to their live nip.io names"
MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
RUST_HOST="cargo-rust.${MINIKUBE_IP}.nip.io"
GO_HOST="cargo-go.${MINIKUBE_IP}.nip.io"
RUST_ISTIO_HOST="cargo-rust-istio.${MINIKUBE_IP}.nip.io"
GO_ISTIO_HOST="cargo-go-istio.${MINIKUBE_IP}.nip.io"
echo "verify-minikube.sh: minikube ip = $MINIKUBE_IP"
echo "verify-minikube.sh: ingress hosts = http://$RUST_HOST/ , http://$GO_HOST/"
echo "verify-minikube.sh: istio hosts   = $RUST_ISTIO_HOST , $GO_ISTIO_HOST"

kubectl patch ingress cargo-final -n "$APP_NS" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$RUST_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/rules/1/host\",\"value\":\"$GO_HOST\"}]"
kubectl patch gateway cargo-final-gateway -n "$APP_NS" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/servers/0/hosts/0\",\"value\":\"$RUST_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/servers/0/hosts/1\",\"value\":\"$GO_ISTIO_HOST\"}]"
kubectl patch virtualservice cargo-final -n "$APP_NS" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/hosts/0\",\"value\":\"$RUST_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/hosts/1\",\"value\":\"$GO_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/http/0/match/0/authority/exact\",\"value\":\"$RUST_ISTIO_HOST\"},{\"op\":\"replace\",\"path\":\"/spec/http/1/match/0/authority/exact\",\"value\":\"$GO_ISTIO_HOST\"}]"

# Wait until ingress-nginx is actually routing OUR rules (affinity cookie —
# the "my rule actually matched" deterministic signal, same as Part 5).
wait_for_ingress_rule() {
  local host="$1" waited=0
  while (( waited < 90 )); do
    if curl -sS -D - -o /dev/null "http://${host}${CARGO_PATH}" 2>/dev/null | grep -qi "part7-cargo-affinity"; then
      echo "verify-minikube.sh: ingress routing confirmed for Host $host after ${waited}s"
      return 0
    fi
    sleep 2; waited=$(( waited + 2 ))
  done
  echo "verify-minikube.sh: FAIL — ingress never routed Host $host (no affinity cookie) within 90s" >&2
  return 1
}
wait_for_ingress_rule "$RUST_HOST"
wait_for_ingress_rule "$GO_HOST"

step "Step 11: resolve the istio-ingressgateway NodePort"
NODE_PORT="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
[[ -n "$NODE_PORT" ]] || { echo "verify-minikube.sh: FAIL — istio-ingressgateway has no NodePort for 'http2' (see ../part6-deviations/istio/istio-install.sh step 4)" >&2; exit 1; }
echo "verify-minikube.sh: istio-ingressgateway NodePort (http2) = $NODE_PORT"

# Gate on a with-header 200, not the filter's 403 — a 403 arrives as soon as
# the filter loads, which races Envoy's route reconcile for the just-patched
# Gateway/VirtualService hosts (same fix ch25's verify-istio-minikube.sh uses).
wait_for_istio_route() {
  local host="$1" waited=0 code=""
  local url="http://${MINIKUBE_IP}:${NODE_PORT}${CARGO_PATH}"
  while (( waited < 150 )); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $host" -H 'x-cargo-tenant: acme' "$url" || true)"
    [[ "$code" == "200" ]] && { echo "verify-minikube.sh: istio route + filter ready for Host $host after ${waited}s"; return 0; }
    sleep 3; waited=$(( waited + 3 ))
  done
  echo "verify-minikube.sh: FAIL — istio route + filter not ready for Host $host within ${waited}s (last code '$code')" >&2
  return 1
}
wait_for_istio_route "$RUST_ISTIO_HOST"
wait_for_istio_route "$GO_ISTIO_HOST"

step "Step 12: TWO-LANGUAGE PROOF — through ingress-nginx, both composites return byte-identical JSON + 404"
rust_body="$(curl_body "http://$RUST_HOST$CARGO_PATH")"
echo "verify-minikube.sh: GET $CARGO_PATH (rust) -> $rust_body"
assert_eq "$EXPECTED_JSON" "$rust_body" "minikube GET $CARGO_PATH through ingress (cargo-rust)"
rust_404="$(curl_code "http://$RUST_HOST/cargo/NOPE")"
assert_eq "404" "$rust_404" "minikube GET /cargo/NOPE through ingress (cargo-rust)"

go_body="$(curl_body "http://$GO_HOST$CARGO_PATH")"
echo "verify-minikube.sh: GET $CARGO_PATH (go) -> $go_body"
assert_eq "$EXPECTED_JSON" "$go_body" "minikube GET $CARGO_PATH through ingress (cargo-go)"
go_404="$(curl_code "http://$GO_HOST/cargo/NOPE")"
assert_eq "404" "$go_404" "minikube GET /cargo/NOPE through ingress (cargo-go)"

assert_eq "$rust_body" "$go_body" "cargo-rust and cargo-go responses are byte-identical"

step "Step 13: ISTIO FILTER CONTRACT — both languages, through the gateway"
# One NodePort URL; only the Host header changes which backend the
# VirtualService's authority match sends the request to.
ISTIO_URL="http://${MINIKUBE_IP}:${NODE_PORT}${CARGO_PATH}"

echo "--- cargo-rust, WITHOUT x-cargo-tenant -> expect 403 ---"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $RUST_ISTIO_HOST" "$ISTIO_URL")"
assert_eq "403" "$code" "minikube GET $CARGO_PATH (no x-cargo-tenant) through istio gateway (cargo-rust)"

echo "--- cargo-rust, WITH x-cargo-tenant: acme -> expect 200 + exact JSON + x-cargo-filtered-by ---"
tmp_rust_body="$(mktemp -t istio-rust-body.XXXXXX)"
register_cleanup "rm -f '$tmp_rust_body'"
headers="$(curl -sS -D - -o "$tmp_rust_body" --max-time 8 -H "Host: $RUST_ISTIO_HOST" -H 'x-cargo-tenant: acme' "$ISTIO_URL")"
echo "$headers" | grep -qi '^HTTP/.* 200' \
  || { echo "verify-minikube.sh: FAIL — expected 200 with x-cargo-tenant (cargo-rust), got headers:" >&2; echo "$headers" >&2; exit 1; }
echo "$headers" | grep -qi '^x-cargo-filtered-by: *cargo-wasmfilter' \
  || { echo "verify-minikube.sh: FAIL — missing x-cargo-filtered-by header (cargo-rust):" >&2; echo "$headers" >&2; exit 1; }
assert_eq "$EXPECTED_JSON" "$(cat "$tmp_rust_body")" "minikube GET $CARGO_PATH (x-cargo-tenant: acme) through istio gateway (cargo-rust)"

echo "--- cargo-go, WITHOUT x-cargo-tenant -> expect 403 ---"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $GO_ISTIO_HOST" "$ISTIO_URL")"
assert_eq "403" "$code" "minikube GET $CARGO_PATH (no x-cargo-tenant) through istio gateway (cargo-go)"

echo "--- cargo-go, WITH x-cargo-tenant: acme -> expect 200 + exact JSON + x-cargo-filtered-by ---"
tmp_go_body="$(mktemp -t istio-go-body.XXXXXX)"
register_cleanup "rm -f '$tmp_go_body'"
headers="$(curl -sS -D - -o "$tmp_go_body" --max-time 8 -H "Host: $GO_ISTIO_HOST" -H 'x-cargo-tenant: acme' "$ISTIO_URL")"
echo "$headers" | grep -qi '^HTTP/.* 200' \
  || { echo "verify-minikube.sh: FAIL — expected 200 with x-cargo-tenant (cargo-go), got headers:" >&2; echo "$headers" >&2; exit 1; }
echo "$headers" | grep -qi '^x-cargo-filtered-by: *cargo-wasmfilter' \
  || { echo "verify-minikube.sh: FAIL — missing x-cargo-filtered-by header (cargo-go):" >&2; echo "$headers" >&2; exit 1; }
assert_eq "$EXPECTED_JSON" "$(cat "$tmp_go_body")" "minikube GET $CARGO_PATH (x-cargo-tenant: acme) through istio gateway (cargo-go)"

step "Step 14: ONE SHIM TRACE PER SERVICE — bounded trace scope (see comment below before reading this step)"
# TRACE SCOPE: ../part5-kubernetes/k8s/observability/enable-shim-otel.sh sets
# OTEL_SERVICE_NAME as a systemd Environment= on the containerd.service UNIT
# ITSELF, which every shim process inherits as a CHILD of that one containerd
# process — there is no per-Pod or per-namespace override available, so
# cargo-rust's shim and cargo-go's shim report the IDENTICAL
# resource.service.name ("containerd-shim-wasmtime"). Tempo cannot be asked
# "show me only cargo-go's traces" by service name; nothing in the pinned
# toolchain gives a shim-emitted span a k8s.pod.name or image-name attribute
# to filter on either (the shim's OTel integration predates and is unaware of
# Kubernetes metadata — see ../../_docs/24-observability-on-cluster.md).
#
# What IS provable with that constraint: drive traffic to ONE
# language at a time and show the shared service's trace COUNT grows after
# each language's traffic, proving a SEPARATE shim (cargo-rust's, then
# cargo-go's) emitted a span neither account can be attributed to the other
# backend by name — a before/after count, not a per-service label.
sleep 5  # let in-flight exporter batches from Steps 12-13 flush first
OTEL_POD="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=otel-lgtm -o jsonpath='{.items[0].metadata.name}')"
assert_contains "otel-lgtm" "$OTEL_POD" "otel-lgtm Pod name resolved"

SHIM_SVC="${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}"
baseline_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
echo "verify-minikube.sh: Tempo trace count for '$SHIM_SVC' before this step's traffic = $baseline_count"

echo "verify-minikube.sh: driving cargo-rust-only traffic ..."
for i in 1 2 3; do curl_body "http://$RUST_HOST$CARGO_PATH" >/dev/null; done
sleep 10
after_rust_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
echo "verify-minikube.sh: Tempo trace count for '$SHIM_SVC' after cargo-rust traffic = $after_rust_count"
if (( after_rust_count <= baseline_count )); then
  echo "verify-minikube.sh: FAIL — no new shim trace appeared in Tempo after cargo-rust traffic (baseline=$baseline_count, after=$after_rust_count)" >&2
  exit 1
fi
echo "verify-minikube.sh: ok — cargo-rust's shim contributed at least one new trace ($baseline_count -> $after_rust_count)"

echo "verify-minikube.sh: driving cargo-go-only traffic ..."
for i in 1 2 3; do curl_body "http://$GO_HOST$CARGO_PATH" >/dev/null; done
sleep 10
after_go_count="$(tempo_trace_count "$OTEL_POD" "$SHIM_SVC")"
echo "verify-minikube.sh: Tempo trace count for '$SHIM_SVC' after cargo-go traffic = $after_go_count"
if (( after_go_count <= after_rust_count )); then
  echo "verify-minikube.sh: FAIL — no new shim trace appeared in Tempo after cargo-go traffic (after-rust=$after_rust_count, after-go=$after_go_count)" >&2
  exit 1
fi
echo "verify-minikube.sh: ok — cargo-go's shim (a SEPARATE shim process from cargo-rust's) contributed at least one new trace ($after_rust_count -> $after_go_count)"

echo
echo "PASS — part7-final-project on minikube (docker+containerd, Kubernetes $KUBERNETES_VERSION, Istio $([[ -n "${ISTIO_VERSION:-}" ]] && echo "$ISTIO_VERSION" || echo "1.31.2")):"
echo "  cargo-rust.wasm and cargo-go.wasm both run as Wasm Pods via the"
echo "  containerd wasmtime shim and answer BYTE-IDENTICAL cargo JSON through"
echo "  ingress-nginx (+ 404 on an unknown id); the ch25 proxy-wasm filter,"
echo "  running once in the shared istio-ingressgateway's own Envoy, enforces"
echo "  the x-cargo-tenant contract (403 / 200+x-cargo-filtered-by) for BOTH"
echo "  languages; and each language's shim independently contributed a new"
echo "  trace to the shared otel-lgtm sink's Tempo backend, read with no"
echo "  port-forward."
echo "exit 0"

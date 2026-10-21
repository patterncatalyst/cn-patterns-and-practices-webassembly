#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/capture-interposed-evidence.sh
#
# Headless live run of the ch20/ch21 INTERPOSED compositions on minikube that
# produces the committed evidence. Brings up (idempotently): the profile, both
# Wasm images (filtered + adapted) built and `minikube image load`ed, the
# shim + RuntimeClass, the shared namespace, the ingress addon, and the
# interposed overlay (two sibling Wasm Pods) — then asserts, through the REAL
# ingress-nginx edge (NO port-forward, NO NodePort, NO `minikube service`):
#
#   * FILTERED  (ch20): GET /cargo/CARGO-USNYC-DEHAM -> exact cargo JSON (200)
#                        GET /cargo/CARGO-USNYC-CUHAV -> embargo POLICY 400
#                        GET /cargo/NOPE              -> 404
#   * ADAPTED   (ch21): GET /cargo/CARGO-USNYC-DEHAM -> exact cargo JSON (200),
#                        proving the canonical->legacy->canonical round-trip is
#                        lossless
#                        GET /cargo/NOPE             -> 404
#
# It then runs the ch21 AMBASSADOR local `wasmtime -S inherit-network` smoke
# (the shim has no outbound-network knob, so the ambassador's minikube evidence
# is this local serve/run — see ambassador/build.sh), and captures everything to
# evidence/<YYYY-MM-DD>/1N-*.txt with a secret scrub.
#
# Nothing is faked: every assertion that misses fails the script (set -e). It
# does NOT tear the cluster down — run ./teardown.sh afterwards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

for tool in minikube kubectl docker curl sha256sum python3 wasmtime cargo-component wac wasm-tools; do
  require_cmd "$tool"
done

# Interposed-specific pins (the plain-base IMAGE/VALID_PATH/EXPECTED_JSON come
# from lib.sh and are reused verbatim).
FILTER_IMAGE="cargo-http-filtered:minikube"
ADAPTER_IMAGE="cargo-http-adapted:minikube"
EMBARGO_PATH="/cargo/CARGO-USNYC-CUHAV"
FILTERED_WASM="$PART5_DIR/sidecar-filter/app-filtered.wasm"
ADAPTED_WASM="$PART5_DIR/adapter/app-adapted.wasm"

OUT="$SCRIPT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

step "guard: exactly one cluster (CRC must be stopped)"
# require_single_cluster — the ambassador/CRC split assumes only minikube is up.
if command -v crc >/dev/null 2>&1; then
  if crc status 2>/dev/null | grep -qiE 'CRC VM:\s*Running|OpenShift:\s*Running'; then
    echo "capture-interposed-evidence.sh: FAIL — CRC appears to be running; stop it first (this is the minikube-only run)" >&2
    exit 1
  fi
fi

step "ensure the cluster + both interposed deploys are up (idempotent)"
if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd --kubernetes-version="$KUBERNETES_VERSION"
fi

# Build + load BOTH images, then install the shim (restarts containerd) BEFORE
# enabling the ingress addon so the controller comes up cleanly after the bounce.
IMAGE="$FILTER_IMAGE"  "$PART5_DIR/sidecar-filter/build.sh"
IMAGE="$ADAPTER_IMAGE" "$PART5_DIR/adapter/build.sh"
minikube image load "$FILTER_IMAGE"  -p "$PROFILE"
minikube image load "$ADAPTER_IMAGE" -p "$PROFILE"

PROFILE="$PROFILE" "$SCRIPT_DIR/install-shim.sh"

# The interposed overlay does not carry the Namespace object (kustomize forbids
# referencing files above its root); apply the shared one directly first.
kubectl apply -f "$SCRIPT_DIR/base/namespace.yaml"

minikube addons enable ingress -p "$PROFILE" >/dev/null 2>&1 || true
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

# ingress-nginx's admission webhook can refuse the Ingress create for a few
# seconds after the controller rollout reports Ready (the webhook endpoint is
# still registering) — a known race. Retry the apply until it is accepted.
apply_tries=0
until kubectl apply -k "$SCRIPT_DIR/interposed/overlays/minikube"; do
  apply_tries=$(( apply_tries + 1 ))
  [[ "$apply_tries" -ge 24 ]] && { echo "capture-interposed-evidence.sh: FAIL — apply -k never accepted (ingress admission webhook)" >&2; exit 1; }
  echo "capture-interposed-evidence.sh: ingress admission webhook not ready; retrying apply in 5s ($apply_tries/24)" >&2
  sleep 5
done
kubectl rollout status deployment/cargo-http-filtered -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/cargo-http-adapted  -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

MINIKUBE_IP="$(minikube ip -p "$PROFILE")"
FILTERED_HOST="cargo-filtered.${MINIKUBE_IP}.nip.io"
ADAPTED_HOST="cargo-adapted.${MINIKUBE_IP}.nip.io"
FILTERED_BASE="http://$FILTERED_HOST"
ADAPTED_BASE="http://$ADAPTED_HOST"

kubectl patch ingress cargo-http-filtered -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$FILTERED_HOST\"}]"
kubectl patch ingress cargo-http-adapted -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"$ADAPTED_HOST\"}]"

# wait_for_cookie <url> <cookie-name> — the async ingress reload has happened
# only once OUR rule stamps its affinity cookie (never on the default backend).
wait_for_cookie() {
  local url="$1" cookie="$2" waited=0
  while (( waited < 90 )); do
    if curl -sS -D - -o /dev/null "$url" 2>/dev/null | grep -qi "$cookie"; then return 0; fi
    sleep 2; waited=$(( waited + 2 ))
  done
  echo "capture-interposed-evidence.sh: FAIL — ingress never routed $url within 90s" >&2
  return 1
}
wait_for_cookie "$FILTERED_BASE$VALID_PATH" "part5-filtered-affinity"
wait_for_cookie "$ADAPTED_BASE$VALID_PATH" "part5-adapted-affinity"
wait_for_200 "$FILTERED_BASE$VALID_PATH" 90
wait_for_200 "$ADAPTED_BASE$VALID_PATH" 90

echo "=== 10 interposed images (loaded into the node, no registry) ==="
{
  printf '$ minikube image ls | grep cargo-http\n'
  minikube image ls -p "$PROFILE" 2>/dev/null | grep -E 'cargo-http-(filtered|adapted)' | sort
} | tee "$OUT/10-interposed-images.txt"

echo "=== 11 interposed deploy (Deployments/Services/Ingresses) ==="
{
  printf '$ kubectl get deploy,svc,ingress -n %s -o wide\n' "$NAMESPACE"
  kubectl get deploy,svc,ingress -n "$NAMESPACE" -o wide
  printf '\n# runtimeClassName routing each Pod to the Wasm shim:\n'
  for d in cargo-http-filtered cargo-http-adapted; do
    printf '$ kubectl get deploy %s -o jsonpath={...runtimeClassName}\n' "$d"
    kubectl get deploy "$d" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.runtimeClassName}'; printf '\n'
  done
} | tee "$OUT/11-interposed-deploy.txt"

echo "=== 12 interposed pods (get + describe) ==="
{
  printf '$ kubectl get pods -n %s -o wide\n' "$NAMESPACE"
  kubectl get pods -n "$NAMESPACE" -o wide
  printf '\n$ kubectl describe pods (RuntimeClass + node)\n'
  kubectl describe pod -l app.kubernetes.io/part-of=part5-kubernetes -n "$NAMESPACE" \
    | grep -Ei 'Name:|Node:|Runtime Class Name:|Status:|Image:|Started|Ready' | head -40
} | tee "$OUT/12-interposed-pods.txt"

echo "=== 13 FILTERED composition over the ingress edge (ch20) ==="
{
  printf '# path: host -> ingress-nginx -> cargo-http-filtered:8080 -> Pod -> shim -> app-filtered.wasm\n'
  printf '# chain: part2 provider -> sidecar-filter (embargo + log) -> part3 http door\n\n'
  printf '$ curl -s %s%s   # normal destination -> exact cargo JSON\n' "$FILTERED_BASE" "$VALID_PATH"
  curl_body "$FILTERED_BASE$VALID_PATH"; printf '\n'
  printf '$ curl -s -w %%{http_code} %s%s   # embargoed destination -> policy 4xx\n' "$FILTERED_BASE" "$EMBARGO_PATH"
  printf 'body: %s\n' "$(curl_body "$FILTERED_BASE$EMBARGO_PATH")"
  printf 'code: %s\n' "$(curl_code "$FILTERED_BASE$EMBARGO_PATH")"
  printf '$ curl -s -o /dev/null -w %%{http_code} %s/cargo/NOPE   # unknown -> 404\n' "$FILTERED_BASE"
  printf '%s\n' "$(curl_code "$FILTERED_BASE/cargo/NOPE")"
} | tee "$OUT/13-filtered-http.txt"
assert_eq "$EXPECTED_JSON" "$(curl_body "$FILTERED_BASE$VALID_PATH")" "FILTERED normal GET $VALID_PATH"
assert_eq "400" "$(curl_code "$FILTERED_BASE$EMBARGO_PATH")" "FILTERED embargo GET $EMBARGO_PATH"
assert_eq "404" "$(curl_code "$FILTERED_BASE/cargo/NOPE")" "FILTERED unknown GET /cargo/NOPE"

echo "=== 14 ADAPTED composition over the ingress edge (ch21) ==="
{
  printf '# path: host -> ingress-nginx -> cargo-http-adapted:8080 -> Pod -> shim -> app-adapted.wasm\n'
  printf '# chain: part2 provider -> adapter (canonical<->legacy round-trip) -> part3 http door\n\n'
  printf '$ curl -s %s%s   # round-trip must still yield the exact cargo JSON\n' "$ADAPTED_BASE" "$VALID_PATH"
  curl_body "$ADAPTED_BASE$VALID_PATH"; printf '\n'
  printf '$ curl -s -o /dev/null -w %%{http_code} %s/cargo/NOPE   # unknown -> 404\n' "$ADAPTED_BASE"
  printf '%s\n' "$(curl_code "$ADAPTED_BASE/cargo/NOPE")"
} | tee "$OUT/14-adapted-http.txt"
assert_eq "$EXPECTED_JSON" "$(curl_body "$ADAPTED_BASE$VALID_PATH")" "ADAPTED round-trip GET $VALID_PATH"
assert_eq "404" "$(curl_code "$ADAPTED_BASE/cargo/NOPE")" "ADAPTED unknown GET /cargo/NOPE"

echo "=== 15 AMBASSADOR local wasmtime -S inherit-network smoke (ch21) ==="
# The shim has no outbound-network knob, so the ambassador's minikube evidence
# is the LOCAL serve/run (documented substrate reason). NOT a faked cluster run.
"$PART5_DIR/ambassador/build.sh" 2>&1 | tee "$OUT/15-ambassador-localserve.txt"

echo "=== 16 sha256 of the composed artifacts ==="
{
  printf '# filtered + adapted compositions (interposers spliced in; distinct from the plain app.wasm)\n'
  sha256sum "$FILTERED_WASM" "$ADAPTED_WASM"
  printf '\n# ambassador (reused sockets-rust resilience component)\n'
  sha256sum "$PART5_DIR/ambassador/ambassador.wasm"
} | tee "$OUT/16-interposed-sha256.txt"

echo "=== 17 secret scrub ==="
scrub() {
  python3 -I - "$OUT" <<'PY'
import os, re, sys
root = sys.argv[1]
pats = [
    re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', re.S),
    re.compile(r'(?i)bearer\s+[A-Za-z0-9._\-]{16,}'),
    re.compile(r'(?i)(client-certificate-data|client-key-data|token):\s*\S+'),
]
changed = 0
for name in os.listdir(root):
    p = os.path.join(root, name)
    if not os.path.isfile(p):
        continue
    t = open(p, encoding="utf-8", errors="replace").read()
    o = t
    for pat in pats:
        t = pat.sub("[REDACTED]", t)
    if t != o:
        open(p, "w", encoding="utf-8").write(t)
        changed += 1
print(f"scrub: redacted {changed} file(s)")
PY
}
scrub | tee "$OUT/17-interposed-scrub.txt"
if grep -rEl 'BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}|client-key-data: [A-Za-z0-9+/=]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

echo
echo "PASS — part5-kubernetes interposed (minikube, docker+containerd, Kubernetes $KUBERNETES_VERSION):"
echo "  FILTERED (ch20): normal 200 exact JSON, embargo 400, unknown 404 via ingress."
echo "  ADAPTED  (ch21): round-trip 200 exact JSON, unknown 404 via ingress."
echo "  AMBASSADOR (ch21): local -S inherit-network backoff + capability-deny smoke."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ./teardown.sh to leave the box clean."

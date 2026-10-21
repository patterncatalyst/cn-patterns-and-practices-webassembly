#!/usr/bin/env bash
# examples/part4-runtimes/wasmcloud/capture-evidence.sh
#
# Headless live run of the ch15 wasmCloud example. Brings up a local lattice,
# builds and deploys app.wasm behind the HTTP server capability provider, proves
# the link with real HTTP, exercises self-healing resilience, records app.wasm's
# sha256 (for ch16's same-bytes claim), and tees every step to
# evidence/<YYYY-MM-DD>/NN-*.txt with a secret scrub.
#
# Nothing here is faked: every assertion that misses fails the script (set -e),
# and the scrub refuses to leave credential material in the evidence. It does
# NOT tear the lattice down — run ./teardown.sh afterwards to leave the box clean.
#
# Order:
#   00 wash --version
#   01 wash up -d  + poll `wash get hosts` until ready
#   02 ./build.sh  (writes app.wasm, prints its sha256)
#   03 wash app deploy wadm.yaml + poll until the component, provider and link
#      are live (gated on a real 200 from the service)
#   04 GET /cargo/CARGO-USNYC-DEHAM  -> exact JSON ; GET /cargo/NOPE -> 404
#   05 resilience: scale the component to 0 -> traffic fails -> wadm self-heals
#      -> traffic recovers (before / fail / after captured)
#   06 sha256sum app.wasm  (same bytes ch16 runs under wasmtime serve)
#   07 secret scrub over the evidence directory
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"
export WASH_DISABLE_INTERACTIVE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run from the example dir so the wadm manifest's file://./app.wasm resolves and
# the host (started here) can read the local component.
cd "$SCRIPT_DIR"
# shellcheck source=../../_lib/lib.sh
source "$SCRIPT_DIR/../../_lib/lib.sh"

require_cmd wash
require_cmd curl
require_cmd python3
require_cmd sha256sum

APP_NAME="cargo-http"
BASE="http://127.0.0.1:8000"
VALID_PATH="/cargo/CARGO-USNYC-DEHAM"
EXPECTED_JSON='{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}'

OUT="$SCRIPT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

# cap NN-name -- cmd...   run a command, tee combined output to the evidence file
# and to the console.
cap() {
  local file="$OUT/$1.txt"; shift
  [[ "$1" == "--" ]] && shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; } | tee "$file"
}

curl_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || echo "000"; }
curl_body() { curl -s --max-time 5 "$1" 2>/dev/null || true; }

echo "=== 00. wash version ==="
cap 00-wash-version -- wash --version

echo "=== 01. bring up the lattice ==="
cap 01-wash-up -- wash up -d
# Poll until a host reports ready.
host_ready() {
  wash get hosts -o json 2>/dev/null | python3 -I -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
hosts = d.get("hosts", d) if isinstance(d, dict) else d
sys.exit(0 if hosts else 1)
'
}
for i in $(seq 1 60); do
  if host_ready; then echo "host ready after ${i}s"; break; fi
  sleep 1
  [[ $i -eq 60 ]] && { echo "no host after 60s" >&2; exit 1; }
done
cap 01b-wash-hosts -- wash get hosts

echo "=== 02. build app.wasm ==="
cap 02-build -- ./build.sh
assert_file "$SCRIPT_DIR/app.wasm" "app.wasm"

echo "=== 03. deploy + wait for the link to come up ==="
cap 03-deploy -- wash app deploy wadm.yaml
# Readiness gate: a real 200 from the service proves component + provider + link
# are all live. Poll up to 90s.
ready=0
for i in $(seq 1 90); do
  if [[ "$(curl_code "$BASE$VALID_PATH")" == "200" ]]; then
    echo "service answered 200 after ${i}s"; ready=1; break
  fi
  sleep 1
done
cap 03b-app-status -- wash app status "$APP_NAME"
cap 03c-inventory -- wash get inventory
[[ "$ready" == "1" ]] || { echo "service never returned 200" >&2; exit 1; }

echo "=== 04. HTTP assertions through the httpserver link ==="
{
  printf '$ curl -s %s%s\n' "$BASE" "$VALID_PATH"
  body="$(curl_body "$BASE$VALID_PATH")"
  printf '%s\n' "$body"
  printf '$ curl -s -o /dev/null -w %%{http_code} %s/cargo/NOPE\n' "$BASE"
  code404="$(curl_code "$BASE/cargo/NOPE")"
  printf '%s\n' "$code404"
} | tee "$OUT/04-http.txt"
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "wasmCloud GET $VALID_PATH"
code404="$(curl_code "$BASE/cargo/NOPE")"
assert_eq "404" "$code404" "wasmCloud GET /cargo/NOPE"

echo "=== 05. resilience: scale to 0 -> fail -> self-heal -> recover ==="
HOST_ID="$(wash get hosts -o json | python3 -I -c '
import sys, json
d = json.load(sys.stdin)
hosts = d.get("hosts", d) if isinstance(d, dict) else d
h = hosts[0]
print(h["id"] if isinstance(h, dict) else h)
')"
COMPONENT_REF="file://$SCRIPT_DIR/app.wasm"
COMPONENT_ID="cargo_http-cargo_http"
{
  printf '# before: service is healthy\n'
  printf 'GET %s -> %s  %s\n' "$VALID_PATH" "$(curl_code "$BASE$VALID_PATH")" "$(curl_body "$BASE$VALID_PATH")"

  printf '\n# scale the component to 0 instances (provider/listener stays up)\n'
  printf '$ wash scale component <host> %s %s --max-instances 0\n' "$COMPONENT_REF" "$COMPONENT_ID"
  wash scale component "$HOST_ID" "$COMPONENT_REF" "$COMPONENT_ID" --max-instances 0 2>&1 | sed '/^$/d'

  printf '\n# burst while the component is gone: the provider answers but the\n'
  printf '# invoke fails (no component to handle it) -> non-200\n'
  fail_seen=0
  for _ in $(seq 1 40); do
    c="$(curl_code "$BASE$VALID_PATH")"
    printf '%s ' "$c"
    [[ "$c" != "200" ]] && fail_seen=1
    [[ "$fail_seen" == "1" ]] && break
  done
  printf '\nfail_observed=%s\n' "$fail_seen"

  printf '\n# wadm reconciles the SpreadScaler back to 1 instance; poll to recovery\n'
  recovered=0
  for i in $(seq 1 60); do
    if [[ "$(curl_code "$BASE$VALID_PATH")" == "200" ]]; then
      printf 'recovered after %ss\n' "$i"; recovered=1; break
    fi
    sleep 1
  done
  printf '\n# after: service healthy again\n'
  printf 'GET %s -> %s  %s\n' "$VALID_PATH" "$(curl_code "$BASE$VALID_PATH")" "$(curl_body "$BASE$VALID_PATH")"
  printf 'fail_observed=%s recovered=%s\n' "$fail_seen" "$recovered"
} | tee "$OUT/05-resilience.txt"
grep -q 'fail_observed=1' "$OUT/05-resilience.txt" || { echo "resilience: never observed a failure window" >&2; exit 1; }
grep -q 'recovered=1'     "$OUT/05-resilience.txt" || { echo "resilience: service did not recover" >&2; exit 1; }
# Confirm the healed service still returns the exact JSON.
body="$(curl_body "$BASE$VALID_PATH")"
assert_eq "$EXPECTED_JSON" "$body" "wasmCloud GET $VALID_PATH after self-heal"

echo "=== 06. same-bytes sha256 (ch16) ==="
cap 06-sha256 -- sha256sum app.wasm

echo "=== 07. secret scrub ==="
# Redact any nkey seed (S[A-Z]... 56+ base32 chars), private-key block, or bearer
# token that might have landed in a captured output, then confirm none remain.
scrub() {
  python3 -I - "$OUT" <<'PY'
import os, re, sys
root = sys.argv[1]
pats = [
    re.compile(r'S[A-Z][A-Z2-7]{54,}'),            # wasmCloud / nkey seeds
    re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', re.S),
    re.compile(r'(?i)bearer\s+[A-Za-z0-9._\-]{16,}'),
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
scrub | tee "$OUT/07-scrub.txt"
# Verify nothing credential-looking survives.
if grep -rEl 'S[A-Z][A-Z2-7]{54,}|BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer [A-Za-z0-9._-]{16,}' "$OUT" >/dev/null 2>&1; then
  echo "scrub: FAIL — credential material remains in $OUT" >&2
  exit 1
fi
echo "scrub: ok — no secrets in evidence"

echo
echo "PASS — wasmcloud (ch15): lattice up, app deployed, httpserver link live,"
echo "  GET $VALID_PATH returned the exact cargo JSON, /cargo/NOPE -> 404,"
echo "  resilience (scale-to-0 -> fail -> wadm self-heal -> recover) captured."
echo "  evidence: ${OUT#"$REPO_ROOT"/}"
echo "  run ./teardown.sh to stop the lattice."

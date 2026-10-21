#!/usr/bin/env bash
# examples/part5-kubernetes/ambassador/build.sh
#
# Build + LOCALLY smoke-test the ch21 AMBASSADOR: an out-of-process sidecar that
# owns a service's RESILIENT OUTBOUND calls (retry with exponential backoff +
# jitter) behind a capability-scoped network grant. The resilience artifact is
# the Part 3 `sockets-rust` command component (reused, not edited): it attempts
# an outbound TCP connect and, on failure, backs off exponentially with jitter
# and retries, up to a bounded number of attempts — exactly the behaviour an
# ambassador interposes in front of a flaky upstream.
#
# WHY LOCAL (not a minikube Pod): the runwasi containerd shim runs ONE component
# per container behind a fixed hyper server on :8080 and exposes no outbound
# `-S inherit-network` knob, so an outbound-only command component cannot express
# the ambassador's egress on the minikube shim path. The MINIKUBE evidence for
# the ambassador is therefore this LOCAL `wasmtime run -S inherit-network` smoke;
# the cluster-live, lattice-linked ambassador form is a wasmCloud/CRC concern
# (the CRC executor links it as an outbound capability provider).
#
# Three smokes prove the two ambassador properties:
#   A. backoff   — connect to a DEAD port WITH the network grant: every attempt
#                  fails "connection refused", the component backs off with
#                  growing + jittered delays, then gives up (exit 1). This is the
#                  retry/backoff transcript.
#   B. success   — connect to a LIVE listener WITH the grant: connects on the
#                  first attempt (exit 0).
#   C. capability— connect WITHOUT the grant: the connect is denied at the
#                  capability boundary ("access-denied"), the component fails
#                  fast (non-zero exit) rather than retrying. Egress is a GRANT,
#                  not a default. (wasmtime collapses any non-zero guest exit to
#                  process code 1 — wasi exit is success/failure only — so the
#                  distinguishing signal is the "access-denied" transcript, not a
#                  specific numeric code.)
#
# Output: ./ambassador.wasm (gitignored; a copy of the reused sockets-rust
# component) + the smoke transcript on stdout. Re-runnable from a clean checkout.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SOCKETS="$SCRIPT_DIR/../../part3-interfaces/sockets-rust"
OUT="$SCRIPT_DIR/ambassador.wasm"

for tool in cargo cargo-component wasmtime python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ambassador/build.sh: FAIL — required tool '$tool' not found on PATH" >&2
    exit 1
  fi
done

echo "ambassador/build.sh: [1/2] building the Part 3 sockets-rust resilience component (reused, not edited) ..."
( cd "$SOCKETS" && cargo component build --release )
WASM="$(find "$SOCKETS/target" -name 'sockets-client-rust.wasm' -not -path '*/deps/*' | head -1)"
if [[ ! -s "$WASM" ]]; then
  echo "ambassador/build.sh: FAIL — sockets-rust component not produced" >&2
  exit 1
fi
cp "$WASM" "$OUT"
echo "ambassador/build.sh: wrote $OUT (sha256 $(sha256sum "$OUT" | awk '{print $1}'))"

echo "ambassador/build.sh: [2/2] local wasmtime -S inherit-network smoke ..."

DEAD_PORT=34571
LIVE_PORT=34572

echo
echo "=== SMOKE A: retry + exponential backoff with jitter (dead port $DEAD_PORT, WITH network grant) ==="
# 4 attempts, 50ms base: the growing + jittered backoff is visible in the transcript.
set +e
wasmtime run -S inherit-network "$OUT" "$DEAD_PORT" 4 50
rcA=$?
set -e
echo "ambassador/build.sh: smoke A exit code = $rcA (expected 1 — gave up after retries)"
[[ "$rcA" -eq 1 ]] || { echo "ambassador/build.sh: FAIL — smoke A expected exit 1" >&2; exit 1; }

echo
echo "=== SMOKE B: connects on attempt 1 (live listener $LIVE_PORT, WITH network grant) ==="
# A one-shot TCP listener in the background; -I isolates the interpreter per the
# untrusted-data rule even though this is our own inline code.
python3 -I -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $LIVE_PORT))
s.listen(1)
s.settimeout(15)
try:
    c, _ = s.accept()
    c.close()
except Exception:
    pass
s.close()
" &
LISTENER_PID=$!
sleep 1
set +e
wasmtime run -S inherit-network "$OUT" "$LIVE_PORT" 4 50
rcB=$?
set -e
kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
echo "ambassador/build.sh: smoke B exit code = $rcB (expected 0 — connected)"
[[ "$rcB" -eq 0 ]] || { echo "ambassador/build.sh: FAIL — smoke B expected exit 0" >&2; exit 1; }

echo
echo "=== SMOKE C: capability boundary (dead port $DEAD_PORT, WITHOUT network grant) ==="
set +e
outC="$(wasmtime run "$OUT" "$DEAD_PORT" 4 50 2>&1)"
rcC=$?
set -e
printf '%s\n' "$outC"
echo "ambassador/build.sh: smoke C exit code = $rcC (non-zero — failed fast, no retries)"
[[ "$rcC" -ne 0 ]] || { echo "ambassador/build.sh: FAIL — smoke C expected a non-zero exit" >&2; exit 1; }
printf '%s' "$outC" | grep -q 'access-denied' || { echo "ambassador/build.sh: FAIL — smoke C expected an 'access-denied' capability denial" >&2; exit 1; }
# Fail-fast proof: the capability denial stops after the FIRST attempt (no
# "attempt 2/4"), unlike the connection-refused backoff in smoke A.
printf '%s' "$outC" | grep -q 'attempt 2/4' && { echo "ambassador/build.sh: FAIL — smoke C retried; a capability denial must fail fast" >&2; exit 1; }
echo "ambassador/build.sh: smoke C denied egress on the first attempt (no retry) — capability boundary held"

echo
echo "ambassador/build.sh: OK — backoff transcript (A), connect (B), and capability-deny (C) all as expected."
echo "ambassador/build.sh: NOTE — this is the LOCAL ambassador evidence; the cluster-live,"
echo "                     lattice-linked form is a wasmCloud/CRC concern (not the minikube shim path)."

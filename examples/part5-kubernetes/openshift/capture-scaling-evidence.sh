#!/usr/bin/env bash
#
# capture-scaling-evidence.sh — ch22 autoscaler asymmetry, CRC HALF: run
# verify-scaling-crc.sh live and write what it saw to
# openshift/evidence/<date>/, in the same shape as ../capture-evidence.sh.
#
# Captures:
#   10 BEFORE snapshot: current wadm Application spec + the wasmCloud host
#      Pod(s) (name + count) — the baseline this run's Pod-churn assertion is
#      measured against.
#   11 verify-scaling-crc.sh, run live and captured in full (the 1 ->
#      SCALE_UP_INSTANCES -> 1 wadm cycle, the CA-verified traffic checks, and
#      the hard "zero Kubernetes Pod churn" assertions), gated on its PASS line.
#   12 AFTER snapshot: same two facts, for side-by-side comparison with 10 —
#      the wadm Application's `instances` is back at 1, and the host Pod
#      name(s) are IDENTICAL to 10 (visual confirmation of the hard assertion
#      verify-scaling-crc.sh already made).
#   13 best-effort host log excerpt around the scale-out/scale-in: NOT a
#      pass/fail gate (wasmCloud host/operator log wording is not a stable
#      contract to assert against) — captured for the record only, clearly
#      labeled as such.
#   14 secret scrub.
#
# Does NOT start/stop the cluster, does NOT run install-operator.sh or
# deploy.sh — prerequisite is the same as verify-scaling-crc.sh: cargo-http is
# already deployed (./openshift/deploy.sh has run).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
for t in oc curl python3; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

OUT="$OPENSHIFT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"

HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$HOST" ]] || fail "Route $APP not found — run ./openshift/deploy.sh first"

step "10/14 BEFORE snapshot: wadm Application spec + host Pod(s)"
{
    echo "--- wadm Application $APP (current spec, before this run) ---"
    oc get application.core.oam.dev "$APP" -n "$NS" -o yaml 2>/dev/null \
        | grep -A2 -E '^\s*- type: (spreadscaler|daemonscaler)' || true
    echo "--- wasmCloud host Pod(s) ---"
    oc get pods -n "$NS" -l "app.kubernetes.io/name=$HOSTCFG" -o wide 2>/dev/null
} > "$OUT/10-before.txt" 2>&1
ok "before snapshot -> 10-before.txt"

step "11/14 verify-scaling-crc.sh (live: wadm instances 1 -> N -> 1, CA-verified traffic, zero Pod churn)"
if ! "$OPENSHIFT_DIR/verify-scaling-crc.sh" > "$OUT/11-verify-scaling-crc.log" 2>&1; then
    tail -n 60 "$OUT/11-verify-scaling-crc.log" >&2
    fail "verify-scaling-crc.sh failed — see $OUT/11-verify-scaling-crc.log"
fi
grep -q '^PASS' "$OUT/11-verify-scaling-crc.log" || fail "verify-scaling-crc.sh did not PASS (see $OUT/11-verify-scaling-crc.log)"
ok "verify-scaling-crc.sh PASS -> 11-verify-scaling-crc.log"

step "12/14 AFTER snapshot: wadm Application spec + host Pod(s) (compare with 10)"
{
    echo "--- wadm Application $APP (spec after the 1 -> N -> 1 cycle; instances should read 1 again) ---"
    oc get application.core.oam.dev "$APP" -n "$NS" -o yaml 2>/dev/null \
        | grep -A2 -E '^\s*- type: (spreadscaler|daemonscaler)' || true
    echo "--- wasmCloud host Pod(s) (name + count should be IDENTICAL to 10-before.txt) ---"
    oc get pods -n "$NS" -l "app.kubernetes.io/name=$HOSTCFG" -o wide 2>/dev/null
} > "$OUT/12-after.txt" 2>&1
ok "after snapshot -> 12-after.txt"

step "13/14 best-effort host log excerpt (informational only, NOT a pass/fail gate)"
{
    echo "# wasmCloud host/operator log wording is not a stable, versioned contract;"
    echo "# this excerpt is captured for the record only. The HARD evidence that the"
    echo "# scale actually happened is 11-verify-scaling-crc.log's PASS (the applied"
    echo "# 'instances' value read back from the cluster object, plus traffic staying"
    echo "# 200 across every redeploy)."
    pod="$(oc get pods -n "$NS" -l "app.kubernetes.io/name=$HOSTCFG" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [[ -n "$pod" ]]; then
        oc logs "$pod" -n "$NS" --tail=200 2>/dev/null | grep -iE 'scal|instance|cargo-http' || echo "(no matching log lines in the last 200)"
    else
        echo "(no host pod found)"
    fi
} > "$OUT/13-host-log-excerpt.txt" 2>&1
ok "host log excerpt -> 13-host-log-excerpt.txt (informational)"

step "14/14 Secret scrub"
leaks=0
grep -rlE 'sha256~[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|kubeadmin-password|gh[pousr]_[A-Za-z0-9]{20,}|"auths"|dockerconfigjson' "$OUT" >&2 && leaks=1
(( leaks == 0 )) || fail "evidence contains secret material: delete $OUT and investigate"
echo "no secrets found under $OUT" > "$OUT/14-scrub.txt"
ok "no secrets in $OUT"

printf '\n    evidence: %s\n' "${OUT#"$REPO_ROOT"/}"

#!/usr/bin/env bash
#
# verify-otel-crc.sh — ch24 on-cluster observability, CRC path. Deploys the
# rootless otel-collector (otel-collector.yaml), points the ALREADY-RUNNING
# wasmCloud host at it (wasmcloud-host-otel.yaml — an in-place patch of the
# WasmCloudHostConfig deploy.sh applied), generates traffic through the
# existing edge-TLS Route, then proves a trace + the
# wasmcloud_host.handle_rpc_message.duration metric series + a log line left
# the host and were received — via `oc logs`/`oc exec` on the collector
# (debug exporter stdout + the file exporter's emptyDir). NO port-forward, NO
# SCC exception (restricted-v2 throughout — see otel-collector.yaml's header
# for exactly how a fixed-UID-free Deployment still gets write access to its
# emptyDir).
#
# Requires ../openshift/deploy.sh already run (host + app + Route live) —
# consistent with every other script here: never starts/stops the cluster.
#
# HONEST SCOPE: everything captured below is wasmCloud HOST-level telemetry
# (RPC dispatch, lattice/NATS plumbing) — not anything the Wasm guest code
# itself emitted. Guest-authored spans (wasi-otel) are an RC-only proposal,
# not in this project's pinned stable toolchain, so there is no
# component-authored signal in this pipeline, on either cluster path.
#
#   eval "$(crc oc-env)"
#   ./openshift/deploy.sh      # if not already applied
#   ./openshift/verify-otel-crc.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_crc
for t in oc curl; do command -v "$t" >/dev/null 2>&1 || fail "$t not on PATH"; done

HOST_DEPLOY="$HOSTCFG"
oc get deploy "$HOST_DEPLOY" -n "$NS" >/dev/null 2>&1 \
    || fail "wasmCloud host Deployment '$HOST_DEPLOY' not found in $NS — run ./openshift/deploy.sh first"
ROUTE_HOST="$(oc get route "$APP" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
[[ -n "$ROUTE_HOST" ]] || fail "Route $APP not found in $NS — run ./openshift/deploy.sh first"

step "1/6 Apply the rootless otel-collector (restricted-v2, no SCC exception)"
oc apply -f "$OPENSHIFT_DIR/otel-collector.yaml" >/dev/null || fail "apply otel-collector.yaml"
oc rollout status deploy/otel-collector -n "$NS" --timeout=180s >/dev/null \
    || fail "otel-collector did not roll out (oc get pods -n $NS; oc describe deploy/otel-collector -n $NS)"
ok "otel-collector ready"

step "2/6 Point the wasmCloud host at it (in-place WasmCloudHostConfig patch)"
oc apply -n "$NS" -f "$OPENSHIFT_DIR/wasmcloud-host-otel.yaml" >/dev/null || fail "apply wasmcloud-host-otel.yaml"
# The operator reconciles the spec change onto the existing host Deployment —
# the Pod template changes (new WASMCLOUD_OBSERVABILITY_ENABLED-style env), so
# wait for a fresh rollout, not just "the Deployment still exists". A named
# function (not `bash -c "..."`) so the `oc` wrapper (--context "$OCP_CONTEXT")
# defined in lib.sh is still in scope — a spawned `bash -c` subshell would not
# have it and would fall through to the bare `oc` binary on PATH.
host_has_otel_env() {
    oc get deploy "$HOST_DEPLOY" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null | grep -qi otel
}
wait_for 180 "host Deployment reflects the observability patch" host_has_otel_env
oc rollout status "deploy/$HOST_DEPLOY" -n "$NS" --timeout=180s >/dev/null \
    || fail "host $HOST_DEPLOY did not roll out after the observability patch"
ok "wasmCloud host re-rolled with observability enabled"

step "3/6 Generate traffic through the existing edge-TLS Route"
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$CA"' EXIT
for i in 1 2 3 4 5; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CA" "https://$ROUTE_HOST/cargo/CARGO-USNYC-DEHAM" 2>/dev/null)"
    [[ "$code" == "200" ]] || fail "traffic-gen request #$i returned '$code', expected 200"
done
ok "5x GET /cargo/CARGO-USNYC-DEHAM -> 200 through https://$ROUTE_HOST/"

step "4/6 Let the host's batch exporter flush"
sleep 10

step "5/6 Read what the collector received (debug exporter stdout)"
LOG="$(oc logs "deploy/otel-collector" -n "$NS" --tail=2000 2>/dev/null)"
echo "$LOG" | grep -qi 'TraceID' \
    || fail "no TraceID found in otel-collector logs (oc logs deploy/otel-collector -n $NS)"
ok "a real trace left the wasmCloud host and was received by the collector"
echo "$LOG" | grep -q 'wasmcloud_host.handle_rpc_message.duration' \
    || fail "metric wasmcloud_host.handle_rpc_message.duration not found in otel-collector logs"
ok "metric series wasmcloud_host.handle_rpc_message.duration received"
echo "$LOG" | grep -qi 'LogRecord #' \
    || fail "no LogRecord found in otel-collector logs"
ok "a real host log record was received"

step "6/6 Cross-check against the file exporter (emptyDir, oc exec)"
COLLECTOR_POD="$(oc get pods -n "$NS" -l app.kubernetes.io/name=otel-collector -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$COLLECTOR_POD" ]] || fail "otel-collector Pod not found"
FILE_SAMPLE="$(oc exec "$COLLECTOR_POD" -n "$NS" -- sh -c 'tail -c 200000 /data/otel-output.json 2>/dev/null' || true)"
echo "$FILE_SAMPLE" | grep -q 'wasmcloud_host.handle_rpc_message.duration' \
    || fail "file exporter output missing the handle_rpc_message.duration metric (oc exec $COLLECTOR_POD -n $NS -- cat /data/otel-output.json)"
ok "file exporter (/data/otel-output.json) independently confirms the metric"

echo
echo "PASS — ch24 on-cluster observability (CRC, restricted-v2, no SCC exception):"
echo "  the wasmCloud host (1.9.1) exported OTLP to a rootless"
echo "  otel-collector-contrib; a real trace, the"
echo "  wasmcloud_host.handle_rpc_message.duration metric series, and a real"
echo "  log record all arrived, confirmed via oc logs AND the file exporter."
echo "  This is HOST-level telemetry — no guest-authored span exists (wasi-otel"
echo "  is RC-only, not in the pinned stable toolchain)."

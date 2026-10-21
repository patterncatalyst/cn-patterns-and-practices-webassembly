#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/observability/enable-shim-otel.sh
#
# Point the runwasi containerd-shim-wasmtime (v0.6.1, already registered by
# ../install-shim.sh) at the otel-lgtm OTLP sink. The shim has emitted OTel
# traces ON BY DEFAULT since v0.5.0 (containerd/runwasi, "OpenTelemetry
# Integration") — there is no shim flag or Pod annotation for this, it is
# configured PURELY by the standard OTEL_EXPORTER_OTLP_* env vars in the
# environment of the containerd PROCESS itself, because the shim process is a
# child of containerd and inherits its environment. That means this is a
# node-level containerd config change, not a Kubernetes object.
#
# GOTCHA (same one ../install-shim.sh already documents): restarting containerd
# bounces every Pod on the node. Run this BEFORE (re)applying the cargo-http
# app overlay, not after — a shim process already running when you set this env
# does NOT retroactively pick it up; only a shim started fresh (i.e. after this
# script's containerd restart) will. verify-otel-minikube.sh gets this ordering
# right: observability stack -> this script -> (re)deploy the app.
#
# WHY A BAKED-IN IP, NOT A DNS NAME: containerd runs in the minikube NODE's
# host network namespace, not inside any Pod's network namespace, so it has no
# cluster DNS resolver and cannot look up
# otel-lgtm.<namespace>.svc.cluster.local. What IS reachable from the host
# namespace is the Service's ClusterIP: on a single-node minikube cluster,
# kube-proxy's iptables/ipvs NAT rules for ClusterIPs are installed in that
# same host network namespace (there is only one node), so a ClusterIP is
# routable from containerd even though containerd is not a cluster-aware
# process. This script resolves the ClusterIP once, at install time, with
# `kubectl get svc`, and bakes the IP (not the name) into the drop-in. If the
# otel-lgtm Service is ever recreated with a new ClusterIP, re-run this script.
#
# Usage: PROFILE=part5 ./enable-shim-otel.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_cmd minikube
require_cmd kubectl

minikube status -p "$PROFILE" >/dev/null 2>&1 || {
  echo "enable-shim-otel.sh: FAIL — minikube profile '$PROFILE' is not running" >&2
  exit 1
}

step "0. resolve the otel-lgtm Service ClusterIP in namespace $NAMESPACE"
OTEL_LGTM_IP="$(kubectl get svc otel-lgtm -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ -z "$OTEL_LGTM_IP" || "$OTEL_LGTM_IP" == "None" ]]; then
  echo "enable-shim-otel.sh: FAIL — Service otel-lgtm not found in $NAMESPACE." >&2
  echo "  Apply the observability overlay first:" >&2
  echo "    kubectl --context $PROFILE apply -k $SCRIPT_DIR/overlays/minikube" >&2
  exit 1
fi
echo "enable-shim-otel.sh: otel-lgtm ClusterIP = $OTEL_LGTM_IP"

OTEL_ENDPOINT="http://${OTEL_LGTM_IP}:4318"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-containerd-shim-wasmtime}"
OTEL_PROTOCOL="${OTEL_PROTOCOL:-http/protobuf}"

step "1. write the containerd.service systemd drop-in on the node"
TMPDIR_OTEL="$(mktemp -d -t part5-shim-otel.XXXXXX)"
register_cleanup "rm -rf '$TMPDIR_OTEL'"

# Same PTY-stdin lesson as install-shim.sh's node script: `minikube ssh`
# allocates a PTY, so a heredoc piped to `sudo bash -s` over that PTY never
# sees EOF and the session hangs. Copy a script file in and run it instead.
NODE_SCRIPT="$TMPDIR_OTEL/enable-shim-otel-node.sh"
cat > "$NODE_SCRIPT" <<NODE
#!/bin/bash
set -euo pipefail
DROPIN_DIR=/etc/systemd/system/containerd.service.d
DROPIN=\$DROPIN_DIR/10-otel.conf
mkdir -p "\$DROPIN_DIR"
NEW_CONTENT='[Service]
Environment="OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_ENDPOINT}"
Environment="OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}"
Environment="OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_PROTOCOL}"
'
if [ -f "\$DROPIN" ] && [ "\$(cat "\$DROPIN")" = "\$NEW_CONTENT" ]; then
  echo "enable-shim-otel.sh(node): drop-in already up to date — skipping edit"
else
  printf '%s' "\$NEW_CONTENT" > "\$DROPIN"
  echo "enable-shim-otel.sh(node): wrote \$DROPIN:"
  cat "\$DROPIN"
fi
echo "enable-shim-otel.sh(node): reloading units + restarting containerd ..."
systemctl daemon-reload
systemctl restart containerd
for i in \$(seq 1 30); do
  if ctr version >/dev/null 2>&1; then echo "enable-shim-otel.sh(node): containerd back after \${i}s"; break; fi
  sleep 1
  [ "\$i" -eq 30 ] && { echo "enable-shim-otel.sh(node): FAIL — containerd did not come back" >&2; exit 1; }
done
echo "enable-shim-otel.sh(node): confirming the env reached the containerd process:"
systemctl show containerd --property=Environment
NODE
minikube cp "$NODE_SCRIPT" "$PROFILE:/tmp/enable-shim-otel-node.sh" -p "$PROFILE"
minikube ssh -p "$PROFILE" -- "sudo bash /tmp/enable-shim-otel-node.sh && sudo rm -f /tmp/enable-shim-otel-node.sh"

echo
echo "enable-shim-otel.sh: OK — containerd (and the shims it spawns) now export"
echo "  OTLP to $OTEL_ENDPOINT as service '$OTEL_SERVICE_NAME' ($OTEL_PROTOCOL)."
echo "  Any Pod scheduled from here on gets a shim with this env; Pods already"
echo "  running do NOT — redeploy the app overlay to pick it up."

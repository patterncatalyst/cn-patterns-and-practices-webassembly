#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/install-shim.sh
#
# Install the runwasi `containerd-shim-wasmtime` into the running minikube node
# so Kubernetes can run a Wasm component as a Pod via a RuntimeClass. Idempotent:
# re-running is safe (checksum-verified download, `grep` guard on the config
# edit, `apply` for the RuntimeClass).
#
# Steps:
#   1. Download the PINNED shim tarball to a fresh temp dir and verify its
#      SHA256 against the value recorded in lib.sh (taken from the release's
#      SHA256SUMS). Extract the `containerd-shim-wasmtime-v1` binary.
#   2. Copy the binary into the node and install it at /usr/bin (on containerd's
#      PATH) as root, mode 0755.
#   3. Register the runtime `io.containerd.wasmtime.v1` under the CRI plugin's
#      `runtimes` table in /etc/containerd/config.toml (handler name `wasmtime`),
#      unless it is already there, then restart containerd and wait for the CRI
#      socket to come back.
#   4. Apply the RuntimeClass (handler `wasmtime`) to the cluster.
#
# containerd resolves a CRI runtime of type `io.containerd.wasmtime.v1` to the
# binary `containerd-shim-wasmtime-v1` on its PATH; a Pod that sets
# `runtimeClassName: wasmtime` is then scheduled onto that shim, which detects
# our component targets wasi:http/proxy and serves it on 0.0.0.0:8080.
#
# Usage: PROFILE=part5 ./install-shim.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd minikube
require_cmd kubectl
require_cmd curl
require_cmd sha256sum
require_cmd tar

minikube status -p "$PROFILE" >/dev/null 2>&1 || {
  echo "install-shim.sh: FAIL — minikube profile '$PROFILE' is not running" >&2
  exit 1
}

step "1. download + checksum-verify the pinned shim ($SHIM_VERSION)"
TMPDIR_SHIM="$(mktemp -d -t part5-shim.XXXXXX)"
register_cleanup "rm -rf '$TMPDIR_SHIM'"
echo "install-shim.sh: downloading $SHIM_URL"
curl -sSL -o "$TMPDIR_SHIM/$SHIM_TARBALL" "$SHIM_URL"
ACTUAL_SHA="$(sha256sum "$TMPDIR_SHIM/$SHIM_TARBALL" | awk '{print $1}')"
assert_eq "$SHIM_SHA256" "$ACTUAL_SHA" "shim tarball SHA256"
tar xzf "$TMPDIR_SHIM/$SHIM_TARBALL" -C "$TMPDIR_SHIM"
BIN="$TMPDIR_SHIM/$SHIM_BINARY"
assert_file "$BIN" "extracted shim binary"
chmod 0755 "$BIN"

step "2. install the shim binary into the node (/usr/bin/$SHIM_BINARY)"
minikube cp "$BIN" "$PROFILE:/tmp/$SHIM_BINARY" -p "$PROFILE"
# NB: the shim is a containerd shim binary, not a CLI — it has no --version
# flag (invoking it with one panics). Confirm it is in place and executable
# instead; `ctr version` after the restart is the real "containerd can use it"
# signal, and the go/no-go Pod is the definitive proof.
minikube ssh -p "$PROFILE" -- "sudo install -m 0755 /tmp/$SHIM_BINARY /usr/bin/$SHIM_BINARY && sudo rm -f /tmp/$SHIM_BINARY && ls -l /usr/bin/$SHIM_BINARY"

step "3. register io.containerd.wasmtime.v1 in containerd config + restart"
# Idempotent config edit done entirely inside the node (awk insert guarded by a
# grep). Insert the wasmtime runtime block right after the CRI runtimes table
# header, matching minikube's containerd config (version = 2).
#
# The node script is COPIED in and run with `sudo bash <file>`, NOT piped on
# stdin: `minikube ssh` allocates a PTY, and a heredoc fed to `sudo bash -s`
# over that PTY never receives EOF, so the session hangs after the work is done.
# A copied script file sidesteps the PTY-stdin problem entirely.
NODE_SCRIPT="$TMPDIR_SHIM/register-wasmtime-runtime.sh"
cat > "$NODE_SCRIPT" <<'NODE'
#!/bin/bash
set -euo pipefail
CFG=/etc/containerd/config.toml
if grep -q 'containerd.runtimes.wasmtime\]' "$CFG"; then
  # Already registered: the config is unchanged, so DO NOT restart containerd.
  # An unconditional restart here needlessly bounces every running Pod on the
  # node — and a Wasm Pod that was mid-flight across the restart gets SIGKILLed
  # (exit 137) and wedges into CrashLoopBackOff. Re-running install-shim (e.g.
  # between Part 5 chapters) must be a no-op when nothing changed.
  echo "install-shim.sh(node): wasmtime runtime already registered — config unchanged, NOT restarting containerd"
else
  cp "$CFG" "${CFG}.bak.$(date +%s)"
  awk '
    { print }
    /\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\]/ {
      print "        [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.wasmtime]"
      print "          runtime_type = \"io.containerd.wasmtime.v1\""
    }
  ' "$CFG" > "${CFG}.new"
  mv "${CFG}.new" "$CFG"
  echo "install-shim.sh(node): inserted wasmtime runtime block:"
  grep -n 'wasmtime' "$CFG" || true
  echo "install-shim.sh(node): restarting containerd (config changed) ..."
  systemctl restart containerd
  # Wait for the CRI socket to answer again.
  for i in $(seq 1 30); do
    if ctr version >/dev/null 2>&1; then echo "install-shim.sh(node): containerd back after ${i}s"; break; fi
    sleep 1
    [ "$i" -eq 30 ] && { echo "install-shim.sh(node): FAIL — containerd did not come back" >&2; exit 1; }
  done
fi
# Always confirm containerd is answering (whether or not we restarted it).
ctr version >/dev/null 2>&1 || { echo "install-shim.sh(node): FAIL — containerd not responding" >&2; exit 1; }
NODE
minikube cp "$NODE_SCRIPT" "$PROFILE:/tmp/register-wasmtime-runtime.sh" -p "$PROFILE"
minikube ssh -p "$PROFILE" -- "sudo bash /tmp/register-wasmtime-runtime.sh && sudo rm -f /tmp/register-wasmtime-runtime.sh"

step "4. apply the RuntimeClass (handler $SHIM_HANDLER)"
kubectl apply -f "$SCRIPT_DIR/base/runtimeclass.yaml"
kubectl get runtimeclass "$SHIM_HANDLER"

echo
echo "install-shim.sh: OK — shim $SHIM_VERSION installed, runtime registered, RuntimeClass '$SHIM_HANDLER' applied"

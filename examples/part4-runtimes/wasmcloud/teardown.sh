#!/usr/bin/env bash
# examples/part4-runtimes/wasmcloud/teardown.sh
#
# Idempotent teardown of the ch15 wasmCloud example: undeploy + delete the wadm
# application, then stop the whole local lattice (host + wadm + NATS). Safe to
# run whether or not anything is up — every step tolerates "not found".
set -uo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"
export WASH_DISABLE_INTERACTIVE=1

APP="cargo-http"

echo "teardown.sh: undeploying $APP (ignored if absent) ..."
wash app undeploy "$APP" 2>/dev/null || true
echo "teardown.sh: deleting $APP (ignored if absent) ..."
wash app delete "$APP" 2>/dev/null || true

echo "teardown.sh: stopping the local lattice (wash down --all) ..."
wash down --all 2>/dev/null || true

echo "teardown.sh: OK — lattice stopped, application removed (box clean)"

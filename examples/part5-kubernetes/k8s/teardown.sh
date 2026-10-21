#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/teardown.sh
#
# Idempotent teardown of the Part 5 minikube example. By default it deletes the
# whole minikube profile (the clean-box end state the verify/capture runs expect).
# Pass --app-only to remove just the app objects + RuntimeClass and leave the
# profile (and the installed shim) running for another iteration.
#
# Safe to run whether or not anything is up — every step tolerates "not found".
set -uo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${PROFILE:-part5}"
NAMESPACE="${NAMESPACE:-part5-kubernetes}"

APP_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --app-only) APP_ONLY=1 ;;
    -h|--help) echo "Usage: $0 [--app-only]"; exit 0 ;;
    *) echo "teardown.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

kubectl() { command kubectl --context "$PROFILE" "$@"; }

if [[ "$APP_ONLY" -eq 1 ]]; then
  echo "teardown.sh: removing app objects + RuntimeClass (profile stays up) ..."
  kubectl delete -k "$SCRIPT_DIR/overlays/minikube" --ignore-not-found 2>/dev/null || true
  kubectl delete runtimeclass wasmtime --ignore-not-found 2>/dev/null || true
  echo "teardown.sh: OK — app removed; profile '$PROFILE' left running"
else
  echo "teardown.sh: deleting minikube profile '$PROFILE' (full clean) ..."
  minikube delete -p "$PROFILE" 2>/dev/null || true
  echo "teardown.sh: OK — profile deleted (box clean)"
fi

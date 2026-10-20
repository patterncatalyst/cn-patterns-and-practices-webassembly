#!/usr/bin/env bash
# scripts/check-prereqs.sh
#
# Checks the BUILD toolchain Part 2's examples compile against (Ch0 covers
# installing every tool checked here). Does not install anything — it only
# confirms what's already on PATH, reports each tool's version against the
# pin in _plans/version-matrix.md, and fails loud with an install hint rather
# than letting a confusing cargo-component or wasm-tools error be the first
# symptom of a missing or wrong tool.
#
# This script does NOT check wasmCloud/wash (Part 4) or minikube/CRC/the LGTM
# stack (Part 5) — those are checked by their own parts' scripts when those
# chapters land; this is the Parts 2-4 BUILD toolchain only.
#
# Exits non-zero the moment the first required tool is missing or fails its
# minimum-version floor, so a reader's terminal and CI report the same
# failure the same way. Re-runnable, read-only, POSIX-ish bash.
set -euo pipefail

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.local/tinygo/bin:$PATH"

FAIL=0

# version_ge <have> <want> — true if <have> >= <want> as a dotted version.
version_ge() {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# check <label> <binary> <version-cmd> <extract-regex> <min-version> <pin> <install-hint>
#
# Runs <version-cmd>, extracts the first match of <extract-regex> (a POSIX ERE
# with one capture group) via sed, compares it against <min-version>, and
# prints one aligned OK/FAIL line. FAIL sets the script's overall exit code
# but keeps checking the rest, so a reader sees every gap in one run instead
# of fixing tools one at a time.
check() {
  local label="$1" binary="$2" vercmd="$3" regex="$4" min="$5" pin="$6" hint="$7"
  if ! command -v "$binary" >/dev/null 2>&1; then
    printf '%-18s %-10s not found\n' "$label" "missing"
    echo "    install: $hint"
    FAIL=1
    return
  fi
  local raw have
  raw="$(eval "$vercmd" 2>&1 || true)"
  have="$(printf '%s\n' "$raw" | sed -nE "s/.*${regex}.*/\\1/p" | head -n1)"
  if [ -z "$have" ]; then
    printf '%-18s %-10s version string not recognized (%s)\n' "$label" "FAIL" "$raw"
    FAIL=1
    return
  fi
  if version_ge "$have" "$min"; then
    printf '%-18s %-10s OK  (pin %s)\n' "$label" "$have" "$pin"
  else
    printf '%-18s %-10s FAIL (need >= %s, pin %s)\n' "$label" "$have" "$min" "$pin"
    echo "    install: $hint"
    FAIL=1
  fi
}

echo "checking the Part 2-4 build toolchain (Ch0) ..."
echo

check "rustc" rustc \
  "rustc --version" \
  "rustc ([0-9]+\.[0-9]+\.[0-9]+)" \
  "1.99.0" "1.99.1" \
  "https://rustup.rs"

check "cargo" cargo \
  "cargo --version" \
  "cargo ([0-9]+\.[0-9]+\.[0-9]+)" \
  "1.99.0" "1.99.1" \
  "ships with rustc above"

check "cargo-component" cargo-component \
  "cargo-component --version" \
  "cargo-component ([0-9]+\.[0-9]+\.[0-9]+)" \
  "0.21.1" "0.21.1" \
  "cargo install cargo-component --locked --version 0.21.1   # built from source, no prebuilt linux binary"

check "go" go \
  "go version" \
  "go([0-9]+\.[0-9]+\.[0-9]+)" \
  "1.26.0" "1.26.9" \
  "https://go.dev/dl/"

check "tinygo" tinygo \
  "tinygo version" \
  "tinygo version ([0-9]+\.[0-9]+\.[0-9]+)" \
  "0.43.0" "0.43.0" \
  "https://tinygo.org/getting-started/install/"

check "wit-bindgen-go" wit-bindgen-go \
  "wit-bindgen-go version" \
  "version v([0-9]+\.[0-9]+\.[0-9]+)" \
  "0.7.0" "v0.7.0" \
  "go install go.bytecodealliance.org/cmd/wit-bindgen-go@v0.7.0"

check "wasm-tools" wasm-tools \
  "wasm-tools --version" \
  "wasm-tools ([0-9]+\.[0-9]+\.[0-9]+)" \
  "1.262.0" "1.262.0" \
  "pinned release binary, see _plans/version-matrix.md (SHA-256 verified)"

check "wasmtime" wasmtime \
  "wasmtime --version" \
  "wasmtime ([0-9]+\.[0-9]+\.[0-9]+)" \
  "50.0.0" "50.0.0" \
  "pinned release binary, see _plans/version-matrix.md (SHA-256 verified)"

# The wasm32-wasip2 Rust target is a rustup component, not a binary on PATH —
# checked separately via `rustup target list --installed`.
if command -v rustup >/dev/null 2>&1; then
  if rustup target list --installed 2>/dev/null | grep -qx "wasm32-wasip2"; then
    printf '%-18s %-10s OK\n' "wasm32-wasip2" "installed"
  else
    printf '%-18s %-10s not installed\n' "wasm32-wasip2" "missing"
    echo "    install: rustup target add wasm32-wasip2"
    FAIL=1
  fi
else
  printf '%-18s %-10s rustup not found, cannot check target\n' "wasm32-wasip2" "FAIL"
  echo "    install: https://rustup.rs"
  FAIL=1
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "all checks passed: Part 2-4 build toolchain is ready"
else
  echo "one or more required build tools are missing or under-pinned (see above)" >&2
fi
exit "$FAIL"

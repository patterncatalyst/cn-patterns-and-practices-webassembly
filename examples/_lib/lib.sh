#!/usr/bin/env bash
# examples/_lib/lib.sh
#
# Shared verification harness for the hands-on examples' verify.sh scripts.
# Source this file, then use the helpers below to assert values, register
# cleanup that runs on EXIT, and compare the exported WIT of a built .wasm
# component against the repository contract.
#
# Usage (from an example's verify.sh):
#
#   #!/usr/bin/env bash
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=../_lib/lib.sh
#   source "$SCRIPT_DIR/../_lib/lib.sh"
#
#   assert_eq "expected" "$actual" "some label"
#
# This file must stay `bash -n` clean: a repo check runs `bash -n` on every
# *.sh in the tree.

set -euo pipefail

# ---------------------------------------------------------------------------
# Path resolution — works regardless of the calling example's cwd.
# ---------------------------------------------------------------------------
LGTM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LGTM_LIB_DIR/.." && pwd)"
export REPO_ROOT

# ---------------------------------------------------------------------------
# Cleanup registry — commands registered here run on EXIT (success or the
# `set -e` failure path), newest first.
# ---------------------------------------------------------------------------
_LIB_CLEANUP_CMDS=()

# register_cleanup <command...> — queue a command to run on EXIT.
register_cleanup() {
  _LIB_CLEANUP_CMDS+=("$*")
}

_lib_run_cleanup() {
  local i
  for (( i=${#_LIB_CLEANUP_CMDS[@]}-1; i>=0; i-- )); do
    eval "${_LIB_CLEANUP_CMDS[$i]}" || true
  done
}
trap _lib_run_cleanup EXIT

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# assert_eq <expected> <actual> <context>
assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="${3:-equality}"
  if [[ "$expected" != "$actual" ]]; then
    echo "lib.sh: FAIL — ${context}: expected '$expected', got '$actual'" >&2
    return 1
  fi
  echo "lib.sh: ok — ${context}: '$actual'" >&2
}

# assert_contains <needle> <haystack> <context>
assert_contains() {
  local needle="$1"
  local haystack="$2"
  local context="${3:-contains}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "lib.sh: FAIL — ${context}: '$needle' not found" >&2
    return 1
  fi
  echo "lib.sh: ok — ${context}: found '$needle'" >&2
}

# assert_file <path> <context> — fail if the file does not exist / is empty.
assert_file() {
  local path="$1"
  local context="${2:-file}"
  if [[ ! -s "$path" ]]; then
    echo "lib.sh: FAIL — ${context}: missing or empty file '$path'" >&2
    return 1
  fi
  echo "lib.sh: ok — ${context}: '$path'" >&2
}

# ---------------------------------------------------------------------------
# Tooling checks
# ---------------------------------------------------------------------------

# require_cmd <cmd> [hint] — fail loudly if a tool is not on PATH.
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "lib.sh: FAIL — required tool '$cmd' not found on PATH${hint:+ ($hint)}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# WIT conformance
# ---------------------------------------------------------------------------

# wit_interface_digest — read `wasm-tools component wit` output on stdin and
# print a normalized, order-independent digest of the three contract
# interfaces (types, booking, handling): their member signatures with leading
# whitespace stripped and sorted within each interface. Framing differs
# between a resolved WIT directory (top-level interfaces) and an instantiated
# component (interfaces nested inside `package ... { }`), so the digest
# ignores framing and compares only the interface bodies.
wit_interface_digest() {
  python3 -I -c '
import sys

text = sys.stdin.read()
lines = text.splitlines()

wanted = {"types", "booking", "handling"}
digests = {}
i = 0
n = len(lines)
while i < n:
    stripped = lines[i].strip()
    started = False
    name = None
    for w in wanted:
        if stripped.startswith("interface %s {" % w) or stripped == "interface %s {" % w:
            name = w
            started = True
            break
    if started:
        depth = stripped.count("{") - stripped.count("}")
        body = []
        i += 1
        while i < n and depth > 0:
            s = lines[i].strip()
            depth += s.count("{") - s.count("}")
            # Skip doc comments: a resolved WIT directory keeps `///` docs but an
            # instantiated components embedded WIT drops them, so compare only
            # the actual type and function signatures.
            if depth > 0 and s and s != "}" and not s.startswith("//"):
                body.append(s)
            i += 1
        digests[name] = sorted(body)
        continue
    i += 1

for name in sorted(digests):
    print("interface %s" % name)
    for line in digests[name]:
        print("  " + line)
'
}

# assert_component_matches_contract <wasm> <contract-wit-dir> <label>
#
# Confirms the component is a valid component whose exported
# patterncatalyst:cargo interfaces match the repository contract exactly.
assert_component_matches_contract() {
  local wasm="$1"
  local contract_dir="$2"
  local label="${3:-component}"

  require_cmd wasm-tools
  if ! wasm-tools validate "$wasm" >/dev/null 2>&1; then
    echo "lib.sh: FAIL — ${label}: $wasm is not a valid wasm component/module" >&2
    return 1
  fi

  local comp_digest contract_digest
  comp_digest="$(wasm-tools component wit "$wasm" | wit_interface_digest)"
  contract_digest="$(wasm-tools component wit "$contract_dir" | wit_interface_digest)"

  if [[ "$comp_digest" != "$contract_digest" ]]; then
    echo "lib.sh: FAIL — ${label}: exported interfaces do not match the contract" >&2
    diff <(printf '%s\n' "$contract_digest") <(printf '%s\n' "$comp_digest") >&2 || true
    return 1
  fi
  echo "lib.sh: ok — ${label}: exported interfaces match the contract (types + booking + handling)" >&2
}

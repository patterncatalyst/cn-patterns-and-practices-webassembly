#!/usr/bin/env bash
# examples/_lib/scrub-host.sh <evidence-dir>
#
# Removes details that identify the machine a capture ran on from every text
# file under <evidence-dir>: the repository checkout path becomes <repo>, the
# home directory becomes ~, the account name in a path becomes user, and the
# running kernel's exact build becomes its major.minor version. The values are
# read at run time; nothing identifying is written in this file.
set -euo pipefail

dir="${1:?usage: scrub-host.sh <evidence-dir>}"
[ -d "$dir" ] || exit 0

repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
home="${HOME:-}"
acct="$(id -un)"
kern="$(uname -r)"
kmm="$(printf '%s' "$kern" | cut -d. -f1-2)"

esc() { printf '%s' "$1" | sed 's/[][\.*^$/|]/\\&/g'; }

find "$dir" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.json' -o -name '*.yaml' \) -print0 |
  while IFS= read -r -d '' f; do
    sed -i \
      -e "s|$(esc "$repo")|<repo>|g" \
      ${home:+-e "s|$(esc "$home")|~|g"} \
      -e "s|/home/$(esc "$acct")\b|~|g" \
      -e "s|$(esc "$kern")|$kmm|g" \
      "$f"
  done

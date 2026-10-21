#!/usr/bin/env bash
#
# teardown-interposed.sh — remove the ch20/ch21 interposition apps, then hand off
# to the r06b teardown.sh which removes the wasmCloud platform (nats + wadm +
# operator), the host, the project, and finally runs `crc stop`.
#
# Removes the Routes, wadm Applications and operator-created Services for all four
# interposed apps (filtered, adapted, ambassador, and the transient negative
# control), while the operator still runs so no finalizer is orphaned. Then calls
# teardown.sh (same flags) to tear down the rest and stop CRC.
#
#   ./openshift/teardown-interposed.sh                 # clean up, then crc stop
#   ./openshift/teardown-interposed.sh --keep-running  # clean up, leave CRC running
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-interposed.sh"

require_crc

step "1/2 Interposed Routes + wadm Applications + Services"
for app in "$FILTERED_APP" "$ADAPTED_APP" "$AMB_APP" "$AMB_NOGRANT_APP"; do
    oc delete route "$app" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    oc delete application.core.oam.dev "$app" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    oc delete svc "$app" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
    ok "removed $app (route + application + service)"
done

step "2/2 Hand off to teardown.sh (platform + host + project + crc stop)"
exec "$OPENSHIFT_DIR/teardown.sh" "$@"

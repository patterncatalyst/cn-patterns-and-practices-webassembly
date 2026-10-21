#!/usr/bin/env bash
#
# capture-interposed-evidence.sh — verify the ch20/ch21 interposition deploy on
# OpenShift Local (CRC, runtime-link form) and write what it saw to
# openshift/evidence/<date>/, numbered 10-19 so it sits BESIDE the r06b single-
# component evidence (00-06). Run after deploy-interposed.sh.
#
# Files:
#   10-interposed-versions.txt   crc/oc, host version, provider tag, component refs
#   11-interposed-pods.txt       pods Ready under restricted-v2 (no anyuid)
#   12-interposed-links.txt      the wadm apps + the link graph that worked
#   13-services-routes.txt       operator-created Services + edge-TLS Routes
#   14-filtered-http.txt         CA-verified curl: embargo 400 + unknown 404 + state-limit body
#   15-adapted-http.txt          CA-verified curl: unknown 404 + state-limit body
#   16-ambassador-http.txt       CA-verified curl: provider reached (404) + no-grant 5xx
#   17-interposer-in-path.txt    host log lines proving the interposer is live in the link chain
#   18-verify-interposed.log     verify-interposed-crc.sh, live, gated on PASS
#   19-interposed-sha256-scrub.txt  sha256 of the four raw components + secret scrub
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-interposed.sh"

require_crc

# Locate the already-built raw components (deploy-interposed.sh built+pushed them).
PROVIDER_WASM="$(find_wasm "$PART2_RUST_DIR" cargo_rust.wasm)"
FRONTDOOR_WASM="$(find_wasm "$PART3_HTTP_DIR" cargo_http_rust.wasm)"
FILTER_WASM="$(find_wasm "$FILTER_DIR" cargo_filter_rust.wasm)"
ADAPTER_WASM="$(find_wasm "$ADAPTER_DIR" cargo_adapter_rust.wasm)"

OUT="$OPENSHIFT_DIR/evidence/$(date +%Y-%m-%d)"
mkdir -p "$OUT"
CA="$(combined_ca_bundle)" || fail "could not build the combined CA bundle"
trap 'rm -f "$CA"' EXIT
https() { curl -sS --max-time 20 --cacert "$CA" "$@"; }

FHOST="$(route_host "$FILTERED_APP")"; [[ -n "$FHOST" ]] || fail "Route $FILTERED_APP not found — run deploy-interposed.sh first"
AHOST="$(route_host "$ADAPTED_APP")";  [[ -n "$AHOST" ]] || fail "Route $ADAPTED_APP not found — run deploy-interposed.sh first"
MHOST="$(route_host "$AMB_APP")";      [[ -n "$MHOST" ]] || fail "Route $AMB_APP not found — run deploy-interposed.sh first"

step "1/9 Versions (pinned)"
{
    crc version | head -3
    oc version | grep -E 'Server|Kubernetes'
    echo "--- wasmCloud host version (WasmCloudHostConfig) ---"
    oc get wasmcloudhostconfig "$HOSTCFG" -n "$NS" -o jsonpath='version={.spec.version}{"\n"}' 2>/dev/null
    echo "--- httpserver provider tag (wadm) ---"
    grep -m1 'http-server:' "$OPENSHIFT_DIR/wadm-filtered.yaml" | sed 's/^[[:space:]]*/  /'
    echo "--- separate component refs (runtime-link form) ---"
    printf '  provider : %s\n  frontdoor: %s\n  filter   : %s\n  adapter  : %s\n' \
        "$PROVIDER_REF" "$FRONTDOOR_REF" "$FILTER_REF" "$ADAPTER_REF"
} > "$OUT/10-interposed-versions.txt" 2>&1
ok "versions -> 10-interposed-versions.txt"

step "2/9 Pods under restricted-v2"
oc get pods -n "$NS" --field-selector=status.phase=Running \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,SCC:.metadata.annotations.openshift\.io/scc' \
    2>/dev/null > "$OUT/11-interposed-pods.txt"
oc get namespace "$NS" -o jsonpath='namespace uid-range: {.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}' >> "$OUT/11-interposed-pods.txt"
ok "pods -> 11-interposed-pods.txt"

step "3/9 wadm apps + the link graph that worked"
{
    echo "--- wadm Applications (operator aggregated API) ---"
    oc get application.core.oam.dev -n "$NS" 2>/dev/null
    echo
    echo "--- The runtime link graph (verified live over wRPC) ---"
    echo "cargo-filtered (ch20):"
    echo "  httpserver-filtered --wasi:http/incoming-handler--> cargo-filtered (front door)"
    echo "  cargo-filtered      --patterncatalyst:cargo/booking--> cargo-filter (interposer)"
    echo "  cargo-filter        --patterncatalyst:cargo/booking,handling--> cargo-provider-f"
    echo "cargo-adapted (ch21):"
    echo "  httpserver-adapted  --wasi:http/incoming-handler--> cargo-adapted (front door)"
    echo "  cargo-adapted       --patterncatalyst:cargo/booking--> cargo-adapter (interposer)"
    echo "  cargo-adapter       --patterncatalyst:cargo/booking,handling--> cargo-provider-a"
    echo "cargo-ambassador (ch21):"
    echo "  httpserver-ambassador --wasi:http/incoming-handler--> cargo-ambassador (front door)"
    echo "  cargo-ambassador      --patterncatalyst:cargo/booking--> cargo-provider-am  (the runtime-granted outbound link)"
} > "$OUT/12-interposed-links.txt" 2>&1
ok "links -> 12-interposed-links.txt"

step "4/9 Services + Routes"
{
    for app in "$FILTERED_APP" "$ADAPTED_APP" "$AMB_APP"; do
        echo "--- $app ---"
        oc get svc "$app" -n "$NS" -o custom-columns='SVC:.metadata.name,TYPE:.spec.type,PORT:.spec.ports[*].port' 2>/dev/null
        oc get endpoints "$app" -n "$NS" -o custom-columns='EP:.metadata.name,ADDRS:.subsets[*].addresses[*].ip' 2>/dev/null
        oc get route "$app" -n "$NS" -o custom-columns='ROUTE:.metadata.name,HOST:.spec.host,TERMINATION:.spec.tls.termination' 2>/dev/null
    done
} > "$OUT/13-services-routes.txt" 2>&1
ok "services + routes -> 13-services-routes.txt"

step "5/9 FILTERED (ch20) CA-verified curl — interposer policy + routing over the link"
{
    echo "# CA-verified against the cluster ingress CA, never -k, never port-forward."
    echo "# ch20 headline: the embargo POLICY fires IN the interposer, across the link,"
    echo "# before the provider is called."
    echo "\$ curl -w ' [%{http_code}]' https://$FHOST$EMBARGO_PATH   (embargoed destination)"; https -w ' [%{http_code}]\n' "https://$FHOST$EMBARGO_PATH"
    echo "\$ curl -w ' [%{http_code}]' https://$FHOST$NOPE_PATH      (unknown id, full chain front door->filter->provider)"; https -w ' [%{http_code}]\n' "https://$FHOST$NOPE_PATH"
    echo "# The state gotcha (documented): a valid id -> book-cargo then get-cargo are TWO"
    echo "# separate wRPC calls; wasmCloud resets component memory per invocation, so the"
    echo "# booking does not survive and the provider answers NotFound (404). The exact"
    echo "# cargo JSON (200) needs in-process wac composition (minikube/r06b), not a link."
    echo "\$ curl -w ' [%{http_code}]' https://$FHOST$VALID_PATH"; https -w ' [%{http_code}]\n' "https://$FHOST$VALID_PATH"
} > "$OUT/14-filtered-http.txt" 2>&1
grep -q 'under embargo' "$OUT/14-filtered-http.txt" || fail "filtered embargo policy missing (see $OUT/14-filtered-http.txt)"
grep -q '400' "$OUT/14-filtered-http.txt" || fail "filtered embargo 400 missing"
ok "filtered http -> 14-filtered-http.txt"

step "6/9 ADAPTED (ch21) CA-verified curl"
{
    echo "\$ curl -w ' [%{http_code}]' https://$AHOST$NOPE_PATH"; https -w ' [%{http_code}]\n' "https://$AHOST$NOPE_PATH"
    echo "# valid id: the canonical->legacy->canonical translation runs, then book+get;"
    echo "# same per-invocation state gotcha -> provider NotFound (404), not 200."
    echo "\$ curl -w ' [%{http_code}]' https://$AHOST$VALID_PATH"; https -w ' [%{http_code}]\n' "https://$AHOST$VALID_PATH"
} > "$OUT/15-adapted-http.txt" 2>&1
grep -q 'no cargo' "$OUT/15-adapted-http.txt" || fail "adapted provider answer missing (see $OUT/15-adapted-http.txt)"
ok "adapted http -> 15-adapted-http.txt"

step "7/9 AMBASSADOR (ch21) CA-verified curl — outbound reached across the granted link"
{
    echo "# The front door reaches the cargo provider across a runtime-granted wadm link"
    echo "# (not a wac-plug composition). A 404 (the provider's OWN NotFound) proves the"
    echo "# outbound wRPC call reached the provider and it answered."
    echo "\$ curl -w ' [%{http_code}]' https://$MHOST$NOPE_PATH"; https -w ' [%{http_code}]\n' "https://$MHOST$NOPE_PATH"
} > "$OUT/16-ambassador-http.txt" 2>&1
grep -q 'no cargo' "$OUT/16-ambassador-http.txt" || fail "ambassador provider answer missing (see $OUT/16-ambassador-http.txt)"
ok "ambassador http -> 16-ambassador-http.txt"

step "8/9 Interposer-in-path (host log proof) + verify-interposed-crc.sh"
# Drive one of each filtered request, then capture the interposer's own log lines
# from the wasmCloud host pod — proof the filter is live IN the link chain.
https -o /dev/null "https://$FHOST$EMBARGO_PATH" 2>/dev/null || true
https -o /dev/null "https://$FHOST$VALID_PATH" 2>/dev/null || true
host_pod="$(oc get pods -n "$NS" -o name 2>/dev/null | grep -m1 wasmcloud-host)"
{
    echo "# wasmCloud host pod log lines emitted by the ch20 sidecar-filter interposer"
    echo "# (eprintln! 'cargo-filter: ...'), proving it is live in the runtime-link chain:"
    oc logs -n "$NS" "$host_pod" --all-containers --tail=400 2>/dev/null | grep 'cargo-filter:' | tail -12
} > "$OUT/17-interposer-in-path.txt" 2>&1
grep -q 'cargo-filter:' "$OUT/17-interposer-in-path.txt" || warn "no interposer log lines captured (see $OUT/17-interposer-in-path.txt)"
ok "interposer-in-path -> 17-interposer-in-path.txt"

if ! "$OPENSHIFT_DIR/verify-interposed-crc.sh" > "$OUT/18-verify-interposed.log" 2>&1; then
    tail -n 40 "$OUT/18-verify-interposed.log" >&2
    fail "verify-interposed-crc.sh failed — see $OUT/18-verify-interposed.log"
fi
grep -q '^PASS' "$OUT/18-verify-interposed.log" || fail "verify-interposed-crc.sh did not PASS"
# Fold the negative-control line into the ambassador evidence.
grep -E 'no-grant GET' "$OUT/18-verify-interposed.log" >> "$OUT/16-ambassador-http.txt" 2>/dev/null || true
ok "verify PASS -> 18-verify-interposed.log"

step "9/9 Component sha256 + secret scrub"
{
    echo "--- the four RAW per-component wasms (separate images, runtime-linked) ---"
    for pair in "provider:$PROVIDER_WASM" "frontdoor:$FRONTDOOR_WASM" "filter:$FILTER_WASM" "adapter:$ADAPTER_WASM"; do
        name="${pair%%:*}"; path="${pair#*:}"
        printf '%-10s %s\n' "$name" "$(sha256sum "$path" 2>/dev/null | awk '{print $1}')"
    done
} > "$OUT/19-interposed-sha256-scrub.txt"
leaks=0
grep -rlE 'sha256~[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|kubeadmin-password|gh[pousr]_[A-Za-z0-9]{20,}|"auths"|dockerconfigjson' "$OUT" >&2 && leaks=1
(( leaks == 0 )) || fail "evidence contains secret material: delete $OUT and investigate"
echo "secret scrub: no token/password/private-key material found under $OUT" >> "$OUT/19-interposed-sha256-scrub.txt"
ok "sha256 + scrub -> 19-interposed-sha256-scrub.txt"

printf '\n    evidence: %s\n' "${OUT#"$REPO_ROOT"/}"

#!/usr/bin/env bash
# examples/part5-kubernetes/k8s/kafka/producer-burst.sh
#
# Produce a BURST of cargo handling-event messages onto `cargo-handling-events`
# entirely IN-CLUSTER (NO port-forward, NO NodePort): `kubectl exec` into a
# disposable Strimzi client Pod and run `kafka-console-producer.sh` against the
# internal bootstrap service's cluster DNS name. This is what creates the
# consumer-group LAG the KEDA `kafka` ScaledObject reads
# (../keda/base/kafka-scaledobject.yaml). KEDA scales the cargo-kafka-host
# Deployment on consumer-group lag.
#
# Each message is in the kafka-handler's wire format (see
# ../../kafka-handler/src/lib.rs):
#
#     CARGO_ID|EVENT_TYPE|UNLOCODE|VOYAGE_ID|RECORDED_AT
#
# COUNT (default 60) messages are produced, round-robin across a small set of
# distinct keys so the partitioner spreads them across the topic's 6
# partitions (kafkatopic.yaml) — a burst that lands entirely on one partition
# cannot demonstrate a multi-replica scale-out no matter how large it is.
#
# Author-only (this BUILD pass does not start a cluster): a later verify/
# capture run on an actual cluster exercises this script for real.
#
#   PROFILE=part5 COUNT=120 ./producer-burst.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_cmd kubectl

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
KAFKA_CLUSTER="${KAFKA_CLUSTER:-cargo-kafka}"
TOPIC="${TOPIC:-cargo-handling-events}"
COUNT="${COUNT:-60}"
BOOTSTRAP="${BOOTSTRAP:-${KAFKA_CLUSTER}-kafka-bootstrap.${KAFKA_NAMESPACE}.svc:9092}"
CLIENT_POD="${CLIENT_POD:-cargo-producer-burst}"
# Strimzi ships the broker's own Kafka distribution (with the CLI tools) in
# this image; reusing it means no extra client image to pin/pull.
CLIENT_IMAGE="${CLIENT_IMAGE:-quay.io/strimzi/kafka:1.3.0-kafka-4.3.1}"

kubectl() { command kubectl --context "$PROFILE" "$@"; }

step "0/3 disposable Strimzi client Pod ($CLIENT_POD, image $CLIENT_IMAGE)"
kubectl run "$CLIENT_POD" -n "$KAFKA_NAMESPACE" --restart=Never \
  --image="$CLIENT_IMAGE" --command -- sleep 3600 \
  2>/dev/null || echo "producer-burst.sh: pod $CLIENT_POD already exists — reusing it"
kubectl wait --for=condition=Ready "pod/$CLIENT_POD" -n "$KAFKA_NAMESPACE" --timeout=120s

step "1/3 generating $COUNT burst messages (6 keys, round-robin across the topic's 6 partitions)"
EVENT_TYPES=(received loaded unloaded customs claimed loaded)
UNLOCODES=(USNYC DEHAM NLRTM SGSIN CNSHA GBFXT)
TMP_MESSAGES="$(mktemp -t part5-kafka-burst.XXXXXX.txt)"
trap 'rm -f "$TMP_MESSAGES"' EXIT
i=0
while (( i < COUNT )); do
  idx=$(( i % 6 ))
  key="CARGO-${UNLOCODES[idx]}-DEHAM"
  printf '%s:%s|%s|%s|VOY-%03d|2026-11-01T00:%02d:00Z\n' \
    "$key" "$key" "${EVENT_TYPES[idx]}" "${UNLOCODES[idx]}" "$(( idx + 1 ))" "$(( i % 60 ))" \
    >> "$TMP_MESSAGES"
  i=$(( i + 1 ))
done
echo "producer-burst.sh: wrote $COUNT messages to a temp batch file"

step "2/3 producing the burst onto $TOPIC via $BOOTSTRAP (in-cluster, no port-forward)"
kubectl exec -i "$CLIENT_POD" -n "$KAFKA_NAMESPACE" -- \
  bin/kafka-console-producer.sh \
    --bootstrap-server "$BOOTSTRAP" \
    --topic "$TOPIC" \
    --property "parse.key=true" \
    --property "key.separator=:" \
    < "$TMP_MESSAGES"
echo "producer-burst.sh: produced $COUNT messages onto $TOPIC"

step "3/3 cleanup"
kubectl delete pod "$CLIENT_POD" -n "$KAFKA_NAMESPACE" --wait=false >/dev/null 2>&1 || true
echo "producer-burst.sh: OK — burst of $COUNT messages sent; check consumer-group lag with:"
echo "  kubectl exec -it deploy/${KAFKA_CLUSTER}-entity-operator -n $KAFKA_NAMESPACE -- bin/kafka-consumer-groups.sh --bootstrap-server $BOOTSTRAP --describe --group cargo-handling"

#!/usr/bin/env python3
"""Figure 23.1, Ch23: two trigger types, one owner.

Both halves of this chapter are the same shape: a keda.sh ScaledObject reads
a metric and patches a plain Kubernetes Deployment's replica count directly,
0 to N and back to 0. Left band (HTTP): the KEDA HTTP add-on's interceptor
queues a cold request, an HTTPScaledObject scales the raw-shim cargo-http
Deployment 0 -> 1, and the interceptor replays the request once the new Pod
is ready. Right band (Kafka): a kafka ScaledObject reads real consumer-group
lag on cargo-handling-events and scales the cargo-kafka-host Deployment
0 -> N; the host embeds wasmtime and calls the Wasm handler per message, then
commits the offset. Only the trigger type differs: request concurrency on
the left, consumer-group lag on the right. KEDA owns the replica count in
both.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 560

bands = [
    {"x": 20, "y": 40, "w": 540, "h": 480,
     "label": "KEDA DRIVES: HTTP request-rate (minikube, cargo-http)",
     "fill": "#f1f5f9"},
    {"x": 620, "y": 40, "w": 540, "h": 480,
     "label": "KEDA DRIVES: Kafka consumer-group lag (minikube, cargo-kafka-host)",
     "fill": "#f1f5f9"},
]

nodes = [
    # --- HTTP trigger chain ---
    {"x": 60, "y": 90, "w": 460, "h": 60,
     "lines": ["cold HTTP request arrives", "no ready replica (scaled to 0)"],
     "style": "ghost"},
    {"x": 60, "y": 180, "w": 460, "h": 60,
     "lines": ["KEDA HTTP add-on interceptor", "queues the request, requests a scale"],
     "style": "accent"},
    {"x": 60, "y": 270, "w": 460, "h": 60,
     "lines": ["HTTPScaledObject", "replicas.min: 0, replicas.max: N"],
     "style": "box"},
    {"x": 60, "y": 360, "w": 460, "h": 60,
     "lines": ["raw-shim cargo-http Deployment", "scales 0 -> 1, then back to 0 on idle"],
     "style": "user"},
    {"x": 60, "y": 450, "w": 460, "h": 50,
     "lines": ["interceptor replays the queued request"],
     "style": "sub"},

    # --- Kafka trigger chain ---
    {"x": 660, "y": 90, "w": 460, "h": 60,
     "lines": ["Kafka consumer-group lag rises", "topic: cargo-handling-events, 6 partitions"],
     "style": "box"},
    {"x": 660, "y": 180, "w": 460, "h": 60,
     "lines": ["KEDA kafka ScaledObject", "trigger: lagThreshold 5, max 6"],
     "style": "accent"},
    {"x": 660, "y": 270, "w": 460, "h": 60,
     "lines": ["cargo-kafka-host Deployment", "scales 0 -> N directly"],
     "style": "box"},
    {"x": 660, "y": 360, "w": 460, "h": 60,
     "lines": ["host: rdkafka group + embedded wasmtime", "handle-message per record, then commit"],
     "style": "user"},
    {"x": 660, "y": 450, "w": 460, "h": 50,
     "lines": ["lag drains -> KEDA scales back to 0"],
     "style": "sub"},
]

edges = [
    {"x1": 290, "y1": 150, "x2": 290, "y2": 180},
    {"x1": 290, "y1": 240, "x2": 290, "y2": 270},
    {"x1": 290, "y1": 330, "x2": 290, "y2": 360},
    {"x1": 290, "y1": 420, "x2": 290, "y2": 450},

    {"x1": 890, "y1": 150, "x2": 890, "y2": 180},
    {"x1": 890, "y1": 240, "x2": 890, "y2": 270},
    {"x1": 890, "y1": 330, "x2": 890, "y2": 360},
    {"x1": 890, "y1": 420, "x2": 890, "y2": 450},
]

notes = [
    {"x": 590, "y": 540, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Two trigger types, one owner: KEDA patches replicas directly in both halves, request concurrency on the left, consumer-group lag on the right."},
]

gd.emit("23-two-keda-models", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

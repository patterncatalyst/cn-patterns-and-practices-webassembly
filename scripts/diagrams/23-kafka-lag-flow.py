#!/usr/bin/env python3
"""Figure 23.2, Ch23: the Kafka lag flow, end to end, on minikube.

One loop, one owner. A producer burst lands on a six-partition topic and
raises real consumer-group lag. KEDA's kafka ScaledObject reads that lag and
scales the cargo-kafka-host Deployment directly, 0 to N. The host is a native
process: it embeds an rdkafka consumer group and a wasmtime runtime, and
calls the Wasm handler's handle-message export once per delivered message on
kafka-app.wasm (kafka-handler plugged into the Part 2 cargo-provider). The
host commits the offset after a successful call. As the extra instances
drain the backlog, lag falls, and KEDA scales cargo-kafka-host back to zero.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1220, 480

bands = [
    {"x": 20, "y": 40, "w": 1180, "h": 400,
     "label": "minikube: consumer-group lag drives KEDA, KEDA drives the Deployment directly",
     "fill": "#f1f5f9"},
]

nodes = [
    # top row, left to right: burst -> topic -> lag -> KEDA decides
    {"x": 50, "y": 90, "w": 230, "h": 70,
     "lines": ["producer burst"],
     "style": "box"},
    {"x": 330, "y": 90, "w": 230, "h": 70,
     "lines": ["topic cargo-handling-events", "(6 partitions)"],
     "style": "box"},
    {"x": 610, "y": 90, "w": 230, "h": 70,
     "lines": ["consumer-group lag rises", "group: cargo-handling"],
     "style": "ink"},
    {"x": 890, "y": 90, "w": 230, "h": 70,
     "lines": ["KEDA kafka ScaledObject", "lagThreshold: 5, max: 6"],
     "style": "accent"},

    # bottom row, right to left: Deployment scales -> rdkafka group -> wasmtime handler -> commit/drain
    {"x": 890, "y": 320, "w": 230, "h": 80,
     "lines": ["cargo-kafka-host Deployment", "KEDA scales 0 -> N"],
     "style": "user"},
    {"x": 610, "y": 320, "w": 230, "h": 80,
     "lines": ["host: rdkafka consumer group", "manual offset commit"],
     "style": "user"},
    {"x": 330, "y": 320, "w": 230, "h": 80,
     "lines": ["embedded wasmtime", "handle-message on kafka-app.wasm"],
     "style": "user"},
    {"x": 50, "y": 320, "w": 230, "h": 80,
     "lines": ["offset committed,", "lag drains -> KEDA scales to 0"],
     "style": "box"},
]

edges = [
    {"x1": 280, "y1": 125, "x2": 330, "y2": 125},
    {"x1": 560, "y1": 125, "x2": 610, "y2": 125, "label": "lag metric exported"},
    {"x1": 840, "y1": 125, "x2": 890, "y2": 125},
    {"x1": 1005, "y1": 160, "x2": 1005, "y2": 320, "label": "scales 0 -> N"},

    {"x1": 890, "y1": 360, "x2": 840, "y2": 360},
    {"x1": 610, "y1": 360, "x2": 560, "y2": 360, "amber": True, "bidir": True, "label": "handle-message per record"},
    {"x1": 330, "y1": 360, "x2": 280, "y2": 360, "label": "commit"},
]

notes = [
    {"x": 610, "y": 460, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "One Deployment, one owner: KEDA reads real consumer-group lag and scales cargo-kafka-host 0 -> N -> 0; the host embeds wasmtime itself."},
]

gd.emit("23-kafka-lag-flow", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

#!/usr/bin/env python3
"""Figure 23.2 — Ch23: the Kafka lag flow, end to end, on CRC.

A producer burst lands on a multi-partition topic. Two things read that
topic independently: the consumer-group lag metric (which KEDA's kafka
ScaledObject watches, advisory only — see Figure 23.1) and the wasmCloud
messaging-kafka provider, which actually delivers messages to the
kafka-handler component over wRPC. As wadm's spreadscaler raises
kafka-handler's instance count, throughput rises, lag drains, and wadm scales
back down. KEDA's reading and wadm's scaling decision are two separate loops
over the same lag signal.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1220, 480

bands = [
    {"x": 20, "y": 40, "w": 1180, "h": 400,
     "label": "CRC — producer burst to drained lag, two independent readers of the same topic",
     "fill": "#f1f5f9"},
]

nodes = [
    {"x": 50, "y": 190, "w": 160, "h": 70,
     "lines": ["producer burst"],
     "style": "box"},
    {"x": 250, "y": 190, "w": 190, "h": 70,
     "lines": ["topic", "(multi-partition)"],
     "style": "box"},

    # observability branch (top)
    {"x": 490, "y": 90, "w": 220, "h": 60,
     "lines": ["consumer-group lag rises"],
     "style": "ink"},
    {"x": 760, "y": 90, "w": 220, "h": 60,
     "lines": ["KEDA kafka ScaledObject", "reads lag"],
     "style": "accent"},
    {"x": 1030, "y": 90, "w": 150, "h": 60,
     "lines": ["advisory only", "(no HPA created)"],
     "style": "ghost"},

    # delivery branch (bottom)
    {"x": 490, "y": 320, "w": 220, "h": 70,
     "lines": ["messaging-kafka provider", "consumes from the topic"],
     "style": "user"},
    {"x": 760, "y": 320, "w": 220, "h": 70,
     "lines": ["kafka-handler component", "wadm scales instances up"],
     "style": "user"},
    {"x": 1030, "y": 320, "w": 150, "h": 70,
     "lines": ["lag drains,", "wadm scales down"],
     "style": "box"},
]

edges = [
    {"x1": 210, "y1": 225, "x2": 250, "y2": 225},
    {"x1": 345, "y1": 190, "x2": 490, "y2": 120, "label": "lag metric exported"},
    {"x1": 710, "y1": 120, "x2": 760, "y2": 120},
    {"x1": 980, "y1": 120, "x2": 1030, "y2": 120, "dashed": True},

    {"x1": 345, "y1": 260, "x2": 490, "y2": 355, "label": "consume"},
    {"x1": 710, "y1": 355, "x2": 760, "y2": 355, "amber": True, "bidir": True, "label": "wRPC invoke"},
    {"x1": 980, "y1": 355, "x2": 1030, "y2": 355, "label": "throughput rises"},
]

notes = [
    {"x": 610, "y": 460, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Two readers, one topic: KEDA's lag reading is advisory; wadm's spreadscaler is the loop that actually changes kafka-handler's instance count."},
]

gd.emit("23-kafka-lag-flow", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

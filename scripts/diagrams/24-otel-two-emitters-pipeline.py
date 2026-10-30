#!/usr/bin/env python3
"""Figure 24.1: two emitters, two in-cluster backends.

minikube (top band): the generic containerd-shim-wasmtime v0.6.1 is the
telemetry source. It emits shim-level OTel traces (one span per invocation,
attributed to the shim boundary, not the guest component) straight into an
in-cluster otel-lgtm stack (Grafana/Tempo/Loki/Prometheus).

CRC (bottom band): the wasmCloud host 1.9.1 is the telemetry source instead.
It emits a fuller native signal set (traces, metrics, and logs) into a
rootless, restricted-v2 OTel Collector whose debug + file exporters are the
evidence sink, read via `oc logs` / `oc exec`. No otel-lgtm on CRC (Decision
B holds restricted-v2 with no SCC exception; the dev image cannot run there).
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 460

bands = [
    {"x": 20, "y": 40, "w": 1140, "h": 180,
     "label": "minikube: shim-level traces only (wasmtime does not natively instrument metrics/logs)",
     "fill": "#f1f5f9"},
    {"x": 20, "y": 260, "w": 1140, "h": 180,
     "label": "CRC: wasmCloud host native traces + metrics + logs, via a rootless Collector",
     "fill": "#f1f5f9"},
]

nodes = [
    # minikube path
    {"x": 60, "y": 90, "w": 280, "h": 60,
     "lines": ["containerd-shim-wasmtime v0.6.1", "per-pod Wasm runtime shim"],
     "style": "box"},
    {"x": 400, "y": 90, "w": 280, "h": 60,
     "lines": ["shim-level OTel traces", "span per invocation, shim-origin only"],
     "style": "accent"},
    {"x": 740, "y": 90, "w": 380, "h": 60,
     "lines": ["otel-lgtm", "Grafana / Tempo / Loki / Prometheus"],
     "style": "user"},

    # CRC path
    {"x": 60, "y": 310, "w": 260, "h": 60,
     "lines": ["wasmCloud host 1.9.1", "lattice host process"],
     "style": "box"},
    {"x": 380, "y": 310, "w": 260, "h": 60,
     "lines": ["native traces + metrics + logs", "host- and provider-level telemetry"],
     "style": "accent"},
    {"x": 700, "y": 310, "w": 230, "h": 60,
     "lines": ["rootless OTel Collector", "restricted-v2 SCC compatible"],
     "style": "user"},
    {"x": 980, "y": 310, "w": 150, "h": 60,
     "lines": ["debug + file exporters", "evidence via oc logs / exec"],
     "style": "ink"},
]

edges = [
    {"x1": 340, "y1": 120, "x2": 400, "y2": 120},
    {"x1": 680, "y1": 120, "x2": 740, "y2": 120},

    {"x1": 320, "y1": 340, "x2": 380, "y2": 340},
    {"x1": 640, "y1": 340, "x2": 700, "y2": 340},
    {"x1": 930, "y1": 340, "x2": 980, "y2": 340},
]

notes = [
    {"x": 590, "y": 440, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Two separate clusters, two separate backends: don't assume one chapter's OTel pipeline describes the other substrate."},
]

gd.emit("24-otel-two-emitters-pipeline", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

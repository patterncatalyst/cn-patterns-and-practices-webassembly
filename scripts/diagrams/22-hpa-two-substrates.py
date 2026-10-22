#!/usr/bin/env python3
"""Figure 22.1 — Ch22: per-substrate autoscaler asymmetry.

minikube (left band): the raw containerd-shim-wasmtime Pod exposes ordinary
cgroup CPU usage. metrics-server aggregates it into the Kubernetes Metrics
API, and a stock autoscaling/v2 HPA drives the Deployment's replica count
directly off that signal, the same as any container workload.

CRC (right band): the app is operator-managed. Replica count is NOT a
Kubernetes-native decision here — the wasmCloud operator's wadm spreadscaler
owns it, reconciling actual instances against the declared count in
wadm.yaml. A Kubernetes HPA pointed at the same Deployment would write a
competing replica count and fight the operator's own reconcile loop.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 560

bands = [
    {"x": 20, "y": 40, "w": 540, "h": 480,
     "label": "minikube — HPA drives replica count directly",
     "fill": "#f1f5f9"},
    {"x": 620, "y": 40, "w": 540, "h": 480,
     "label": "CRC — wadm spreadscaler owns replica count",
     "fill": "#f1f5f9"},
]

nodes = [
    # --- minikube chain ---
    {"x": 60, "y": 90, "w": 460, "h": 60,
     "lines": ["raw-shim Wasm Pod", "containerd-shim-wasmtime v0.6.1"],
     "style": "box"},
    {"x": 60, "y": 180, "w": 460, "h": 60,
     "lines": ["cgroup CPU usage", "kernel-reported, per-pod"],
     "style": "sub"},
    {"x": 60, "y": 270, "w": 460, "h": 60,
     "lines": ["metrics-server", "aggregates cgroup CPU into the Metrics API"],
     "style": "box"},
    {"x": 60, "y": 360, "w": 460, "h": 60,
     "lines": ["HPA (autoscaling/v2)", "targetCPUUtilizationPercentage"],
     "style": "accent"},
    {"x": 60, "y": 450, "w": 460, "h": 50,
     "lines": ["replicas: 1..N, HPA-written"],
     "style": "user"},

    # --- CRC chain ---
    {"x": 660, "y": 90, "w": 460, "h": 60,
     "lines": ["wasmCloud-operator-managed app", "OCIReference, CRD-declared"],
     "style": "box"},
    {"x": 660, "y": 180, "w": 460, "h": 60,
     "lines": ["wadm spreadscaler", "declared instance count in wadm.yaml"],
     "style": "accent"},
    {"x": 660, "y": 270, "w": 460, "h": 60,
     "lines": ["replicas: operator-owned", "wadm reconciles desired vs. actual"],
     "style": "user"},
    {"x": 940, "y": 360, "w": 180, "h": 90,
     "lines": ["HPA (if added)", "writes a competing", "replica count"],
     "style": "ghost"},
    {"x": 660, "y": 360, "w": 250, "h": 140,
     "lines": ["A Kubernetes HPA targeting", "this Deployment would FIGHT",
               "the operator: two controllers", "writing replica count means",
               "flapping — scale through the", "spreadscaler, not a second HPA"],
     "style": "ink"},
]

edges = [
    {"x1": 290, "y1": 150, "x2": 290, "y2": 180},
    {"x1": 290, "y1": 240, "x2": 290, "y2": 270},
    {"x1": 290, "y1": 330, "x2": 290, "y2": 360},
    {"x1": 290, "y1": 420, "x2": 290, "y2": 450},

    {"x1": 890, "y1": 150, "x2": 890, "y2": 180},
    {"x1": 890, "y1": 240, "x2": 890, "y2": 270},
    {"x1": 1030, "y1": 300, "x2": 1030, "y2": 360, "dashed": True, "label": "would conflict"},
]

notes = [
    {"x": 590, "y": 540, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Per-substrate autoscaler asymmetry: minikube's generic shim takes a stock HPA; CRC's operator already owns replica placement through wadm."},
]

gd.emit("22-hpa-two-substrates", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

#!/usr/bin/env python3
"""Figure 23.1 — Ch23: two KEDA models, not one.

KEDA DRIVES (left band, minikube): the HTTP add-on's interceptor sits in
front of a plain raw-shim Wasm Deployment. A cold request is queued, the
add-on's ScaledObject scales the Deployment 0 -> 1, and the interceptor
replays the request once a replica is ready. KEDA owns the replica count
end to end.

KEDA OBSERVES / wadm OWNS (right band, CRC): a kafka ScaledObject reads
consumer-group lag as a trigger metric, but no Kubernetes HPA is created for
the kafka-handler component. The wasmCloud wadm spreadscaler is the thing
that actually owns kafka-handler's instance count — KEDA's reading informs,
it does not drive.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 560

bands = [
    {"x": 20, "y": 40, "w": 540, "h": 480,
     "label": "KEDA DRIVES — minikube, plain raw-shim Deployment",
     "fill": "#f1f5f9"},
    {"x": 620, "y": 40, "w": 540, "h": 480,
     "label": "KEDA OBSERVES / wadm OWNS — CRC, kafka-handler component",
     "fill": "#f1f5f9"},
]

nodes = [
    # --- KEDA drives chain ---
    {"x": 60, "y": 90, "w": 460, "h": 60,
     "lines": ["cold HTTP request arrives", "no ready replica (scaled to 0)"],
     "style": "ghost"},
    {"x": 60, "y": 180, "w": 460, "h": 60,
     "lines": ["KEDA HTTP add-on interceptor", "queues the request, requests a scale"],
     "style": "accent"},
    {"x": 60, "y": 270, "w": 460, "h": 60,
     "lines": ["ScaledObject (http)", "minReplicaCount: 0, maxReplicaCount: N"],
     "style": "box"},
    {"x": 60, "y": 360, "w": 460, "h": 60,
     "lines": ["raw-shim Wasm Deployment", "scales 0 -> 1, then back to 0 on idle"],
     "style": "user"},
    {"x": 60, "y": 450, "w": 460, "h": 50,
     "lines": ["interceptor replays the queued request"],
     "style": "sub"},

    # --- KEDA observes / wadm owns chain ---
    {"x": 660, "y": 90, "w": 460, "h": 60,
     "lines": ["Kafka consumer-group lag", "exported by the broker/exporter"],
     "style": "box"},
    {"x": 660, "y": 180, "w": 460, "h": 60,
     "lines": ["KEDA kafka ScaledObject", "trigger: lag threshold"],
     "style": "accent"},
    {"x": 660, "y": 270, "w": 460, "h": 120,
     "lines": ["no HPA is created for this component —", "the wasmCloud wadm spreadscaler owns",
               "kafka-handler's instance count"],
     "style": "ink"},
    {"x": 660, "y": 410, "w": 460, "h": 60,
     "lines": ["kafka-handler component replicas", "wadm reconciles desired vs. actual"],
     "style": "user"},
]

edges = [
    {"x1": 290, "y1": 150, "x2": 290, "y2": 180},
    {"x1": 290, "y1": 240, "x2": 290, "y2": 270},
    {"x1": 290, "y1": 330, "x2": 290, "y2": 360},
    {"x1": 290, "y1": 420, "x2": 290, "y2": 450},

    {"x1": 890, "y1": 150, "x2": 890, "y2": 180},
    {"x1": 890, "y1": 240, "x2": 890, "y2": 270, "dashed": True, "label": "informs, no HPA"},
    {"x1": 890, "y1": 390, "x2": 890, "y2": 410},
]

notes = [
    {"x": 590, "y": 540, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Same project, two KEDA roles: HTTP add-on drives replica count directly; kafka ScaledObject only observes while wadm owns the count."},
]

gd.emit("23-two-keda-models", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

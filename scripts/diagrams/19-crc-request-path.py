#!/usr/bin/env python3
"""Figure 19.1 — Ch19: the live CRC request path for the cargo-http app under
the wasmCloud operator on OpenShift Local.

A CA-verified `curl` (combined system trust store + the cluster's own ingress
CA; never -k, never port-forward, never NodePort) hits the edge-TLS Route
cargo-http-wasmcloud.apps-crc.testing. The router forwards to the Service
cargo-http:8000, which the operator built with SELECTOR <none> and routes by
hand-writing an EndpointSlice pointing at the wasmCloud host pod's IP — the
thing that needed the endpoints(slices)/restricted RBAC grant. Inside the host
pod the httpserver provider (0.27.0) listens on 0.0.0.0:8000 and calls the
cargo-http component over wrpc on wasi:http/incoming-handler. Every pod in this
path, including the host, runs under restricted-v2 at the namespace-assigned
UID 1000670000, with no anyuid exception anywhere.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 560

bands = [
    {"x": 20, "y": 90, "w": 1140, "h": 440, "label": "project wasmcloud — a normal OpenShift project, governed by restricted-v2", "fill": "#f1f5f9"},
]

nodes = [
    {"x": 20, "y": 10, "w": 320, "h": 60,
     "lines": ["curl --cacert <combined-ca>", "https://cargo-http-wasmcloud.apps-crc.testing/cargo/{id}"],
     "style": "box"},

    {"x": 420, "y": 10, "w": 300, "h": 50,
     "lines": ["never -k, never oc port-forward,", "never NodePort"],
     "style": "ghost"},

    {"x": 60, "y": 130, "w": 260, "h": 70,
     "lines": ["OpenShift router", "edge-TLS Route cargo-http", "TLS terminates here"],
     "style": "box"},

    {"x": 60, "y": 240, "w": 260, "h": 90,
     "lines": ["Service cargo-http:8000", "ClusterIP, SELECTOR <none>",
               "operator-written EndpointSlice", "points at the host pod IP"],
     "style": "accent"},

    {"x": 420, "y": 240, "w": 300, "h": 70,
     "lines": ["endpoints(slices)/restricted", "ClusterRole grant", "(not an SCC/anyuid exception)"],
     "style": "ink"},

    {"x": 60, "y": 380, "w": 480, "h": 120,
     "lines": ["wasmcloud-host pod  (restricted-v2, UID 1000670000)",
               "httpserver provider 0.27.0 listens 0.0.0.0:8000",
               "link -> wrpc call -> wasi:http/incoming-handler",
               "cargo-http component (app.wasm, sha256 eff7f5ee…)"],
     "style": "user"},

    {"x": 620, "y": 380, "w": 320, "h": 70,
     "lines": ["same app.wasm Chapters 14/15/18 run", "byte-identical, no rebuild"],
     "style": "ghost"},

    {"x": 800, "y": 130, "w": 340, "h": 100,
     "lines": ["every pod in this project", "runs restricted-v2:", "no anyuid, namespace-range UID,", "drop ALL, seccomp RuntimeDefault"],
     "style": "box"},
]

edges = [
    {"x1": 190, "y1": 70, "x2": 190, "y2": 130, "label": "HTTPS"},
    {"x1": 190, "y1": 200, "x2": 190, "y2": 240},
    {"x1": 320, "y1": 275, "x2": 420, "y2": 275, "amber": True, "label": "needs"},
    {"x1": 190, "y1": 330, "x2": 190, "y2": 380, "label": "endpoint"},
    {"x1": 540, "y1": 440, "x2": 620, "y2": 415, "dashed": True},
    {"x1": 320, "y1": 165, "x2": 800, "y2": 180, "dashed": True, "label": "SCC admission"},
]

notes = [
    {"x": 590, "y": 530, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Readiness here means a real HTTP 200 through the Route, not the host Deployment reporting Ready — the router rewires its backend a beat later."},
    {"x": 590, "y": 548, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Verified live 2026-10-21 (CRC 2.64.0 / OCP 4.22.14 / wasmcloud host 1.9.1)."},
]

gd.emit("19-crc-request-path", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

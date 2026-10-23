#!/usr/bin/env python3
"""Figure 26.2, Ch26: SpinKube vs. CRC deploy paths for the same Spin app.

One Spin app, cargo-spin.wasm (exports wasi:http/handler@0.3.0), deployed
two ways: on minikube under full SpinKube (spin-operator, SpinApp CRD,
containerd-shim-spin on RuntimeClass wasmtime-spin-v2), and on CRC as an
ordinary restricted-v2 container running the Spin CLI directly: no shim,
no operator, no CRD, because the shim needs a privileged node install
that restricted-v2 does not allow. Both paths reach the app only through
an Ingress or Route; neither uses port-forward.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 900

bands = [
    {"x": 20, "y": 120, "w": 560, "h": 580,
     "label": "minikube: full SpinKube",
     "fill": "#f1f5f9"},
    {"x": 600, "y": 120, "w": 560, "h": 580,
     "label": "CRC: restricted-v2 container (no shim/operator/CRD)",
     "fill": "#f1f5f9"},
]

nodes = [
    {"x": 390, "y": 20, "w": 400, "h": 70,
     "lines": ["Spin app: cargo-spin.wasm", "exports wasi:http/handler@0.3.0"],
     "style": "sub"},

    # minikube path
    {"x": 80, "y": 170, "w": 440, "h": 60, "lines": ["client"], "style": "sub"},
    {"x": 80, "y": 270, "w": 440, "h": 70, "lines": ["nip.io Ingress"], "style": "box"},
    {"x": 80, "y": 380, "w": 440, "h": 70, "lines": ["Service: cargo-spin"], "style": "box"},
    {"x": 80, "y": 490, "w": 440, "h": 170,
     "lines": ["SpinApp pod", "RuntimeClass: wasmtime-spin-v2",
               "containerd-shim-spin v0.26.0 · Spin 4.1", "under spin-operator"],
     "style": "accent"},

    # CRC path
    {"x": 660, "y": 170, "w": 440, "h": 60, "lines": ["client"], "style": "sub"},
    {"x": 660, "y": 270, "w": 440, "h": 70, "lines": ["edge-TLS Route"], "style": "box"},
    {"x": 660, "y": 380, "w": 440, "h": 70, "lines": ["Service: cargo-spin"], "style": "box"},
    {"x": 660, "y": 490, "w": 440, "h": 170,
     "lines": ["Deployment pod", "ordinary container, no shim/operator/CRD",
               "spin up: Spin CLI 4.2.4"],
     "style": "user"},

    {"x": 20, "y": 720, "w": 1140, "h": 140,
     "lines": [
         "Same Spin app, same wasi:http/handler@0.3.0 export; the host differs, not the app.",
         "containerd-shim-spin needs a privileged node install; restricted-v2 does not allow it, so CRC runs the Spin CLI in an ordinary container instead.",
     ],
     "style": "ink"},
]

edges = [
    {"x1": 490, "y1": 90, "x2": 300, "y2": 170, "dashed": True},
    {"x1": 690, "y1": 90, "x2": 880, "y2": 170, "dashed": True},

    {"x1": 300, "y1": 230, "x2": 300, "y2": 270},
    {"x1": 300, "y1": 340, "x2": 300, "y2": 380},
    {"x1": 300, "y1": 450, "x2": 300, "y2": 490},

    {"x1": 880, "y1": 230, "x2": 880, "y2": 270},
    {"x1": 880, "y1": 340, "x2": 880, "y2": 380},
    {"x1": 880, "y1": 450, "x2": 880, "y2": 490},
]

notes = [
    {"x": 590, "y": 890, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "No port-forward on either path: Ingress on minikube, Route on CRC."},
]

gd.emit("26-spinkube-vs-crc-paths", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

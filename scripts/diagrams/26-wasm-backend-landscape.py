#!/usr/bin/env python3
"""Figure 26.1: server-side Wasm backend landscape.

A decision aid, not a ranking, comparing the four backend options this
book covers for running server-side Wasm on Kubernetes: the raw
containerd-shim-wasmtime path (ch17/18), wasmCloud (ch15/19), SpinKube /
Spin (ch26), and WasmEdge / other runwasi shims (mentioned for
completeness, not exercised as a runnable example). Three rows compare
them by operations model, app model, and which cluster paths this book
runs them on.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 830

LABEL_W = 170
COL_W = 228
COL_XS = [204, 446, 688, 930]

HEADER_Y, HEADER_H = 60, 70
ROW1_Y, ROW1_H = 150, 140   # Operations model
ROW2_Y, ROW2_H = 310, 150   # App model
ROW3_Y, ROW3_H = 480, 140   # Runs on

COL_STYLE = ["box", "user", "accent", "kernel"]

bands = [
    {"x": 20, "y": 40, "w": 1140, "h": 580,
     "label": "Server-side Wasm backends: compare by operations model, app model, and cluster support",
     "fill": "#f1f5f9"},
]

headers = [
    ["raw containerd shim", "(ch17–ch18)"],
    ["wasmCloud", "(ch15, ch19)"],
    ["SpinKube / Spin", "(ch26)"],
    ["WasmEdge / other runwasi shims"],
]

ops_row = [
    ["none", "RuntimeClass + shim, no control plane"],
    ["operator + lattice", "wadm links, capability providers"],
    ["operator + shim", "spin-operator + containerd-shim-spin"],
    ["operator + shim", "same RuntimeClass model, different shim"],
]

app_row = [
    ["any wasi:http component", "pod-native Wasm"],
    ["capability-provider components", "lattice-addressed, not pod-native"],
    ["Spin SDK app", "SpinApp CRD + triggers"],
    ["any wasi:http component", "runwasi shim, same ABI model"],
]

runs_row = [
    ["minikube", "CRC"],
    ["minikube", "CRC"],
    ["minikube (full SpinKube)", "CRC (spin up in container)"],
    ["runwasi shim model", "reference only, not run here"],
]

nodes = [
    {"x": 20, "y": HEADER_Y, "w": LABEL_W, "h": HEADER_H, "lines": ["compare by:"], "style": "sub"},
    {"x": 20, "y": ROW1_Y, "w": LABEL_W, "h": ROW1_H, "lines": ["Operations model"], "style": "sub"},
    {"x": 20, "y": ROW2_Y, "w": LABEL_W, "h": ROW2_H, "lines": ["App model"], "style": "sub"},
    {"x": 20, "y": ROW3_Y, "w": LABEL_W, "h": ROW3_H, "lines": ["Runs on"], "style": "sub"},
]

for i, x in enumerate(COL_XS):
    style = COL_STYLE[i]
    nodes.append({"x": x, "y": HEADER_Y, "w": COL_W, "h": HEADER_H, "lines": headers[i], "style": style})
    nodes.append({"x": x, "y": ROW1_Y, "w": COL_W, "h": ROW1_H, "lines": ops_row[i], "style": style})
    nodes.append({"x": x, "y": ROW2_Y, "w": COL_W, "h": ROW2_H, "lines": app_row[i], "style": style})
    nodes.append({"x": x, "y": ROW3_Y, "w": COL_W, "h": ROW3_H, "lines": runs_row[i], "style": style})

nodes.append({
    "x": 20, "y": 650, "w": 1140, "h": 140,
    "lines": [
        "Four backend options for server-side Wasm: a decision aid, not a ranking.",
        "Pick by operations model and app model: SpinKube trades portability for built-in HTTP/Redis/key-value triggers.",
    ],
    "style": "ink",
})

edges = []

notes = [
    {"x": 590, "y": 812, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "WasmEdge / other runwasi shims shown for completeness; not exercised as a runnable example in this book."},
]

gd.emit("26-wasm-backend-landscape", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

#!/usr/bin/env python3
"""Figure 16.2, Ch16: the decision matrix between wasmtime (single process)
and wasmCloud (distributed lattice) across four axes a reader actually has to
weigh: control, operational surface, resilience, and scale, plus a closing
row naming Part 5's Kubernetes as a third, orthogonal axis (scheduling either
runtime as a pod is a separate decision from which runtime to pick)."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1040, 640

nodes = [
    {"x": 20, "y": 20, "w": 260, "h": 60, "lines": ["axis"], "style": "sub"},
    {"x": 300, "y": 20, "w": 330, "h": 60, "lines": ["wasmtime", "single process, you own the host"], "style": "accent"},
    {"x": 650, "y": 20, "w": 330, "h": 60, "lines": ["wasmCloud", "distributed lattice, wadm owns placement"], "style": "user"},

    {"x": 20, "y": 100, "w": 260, "h": 80, "lines": ["Control"], "style": "sub"},
    {"x": 300, "y": 100, "w": 330, "h": 80, "lines": ["embed it or wasmtime serve it;", "you write the host code"], "style": "box"},
    {"x": 650, "y": 100, "w": 330, "h": 80, "lines": ["declare it in wadm.yaml;", "the lattice places and links it"], "style": "box"},

    {"x": 20, "y": 200, "w": 260, "h": 80, "lines": ["Operational surface"], "style": "sub"},
    {"x": 300, "y": 200, "w": 330, "h": 80, "lines": ["one binary, one process;", "lowest surface to operate"], "style": "box"},
    {"x": 650, "y": 200, "w": 330, "h": 80, "lines": ["NATS + wadm + host(s) + providers;", "more moving parts to run"], "style": "box"},

    {"x": 20, "y": 300, "w": 260, "h": 80, "lines": ["Resilience"], "style": "sub"},
    {"x": 300, "y": 300, "w": 330, "h": 80, "lines": ["no built-in restart;", "whatever supervises the process"], "style": "box"},
    {"x": 650, "y": 300, "w": 330, "h": 80, "lines": ["SpreadScaler self-heals;", "scale-to-0 recovered in ~2s (ch15)"], "style": "box"},

    {"x": 20, "y": 400, "w": 260, "h": 80, "lines": ["Scale"], "style": "sub"},
    {"x": 300, "y": 400, "w": 330, "h": 80, "lines": ["more processes, your orchestration"], "style": "box"},
    {"x": 650, "y": 400, "w": 330, "h": 80, "lines": ["multi-host lattice scale-out,", "built into the platform"], "style": "box"},

    {"x": 300, "y": 510, "w": 680, "h": 90,
     "lines": ["Part 5 adds a THIRD, orthogonal axis: Kubernetes schedules",
               "either runtime as a pod: same choice, one layer up"],
     "style": "ink"},
]

notes = [
    {"x": 520, "y": 625, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Neither column is the default: pick the row that matches what this deployment needs to own."},
]

gd.emit("16-single-process-vs-lattice-matrix", W, H, nodes=nodes, notes=notes)

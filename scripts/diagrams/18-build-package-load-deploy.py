#!/usr/bin/env python3
"""Figure 18.2, Ch18: the build/package/load/deploy pipeline build.sh and
verify-minikube.sh run end to end. The SAME wac-plug recompose Part 3 used
(Part 2 Rust cargo provider plugged under the Part 3 http-rust front door)
produces app.wasm; docker build with --provenance=false wraps it in a single-
manifest, FROM-scratch OCI image (no registry anywhere); minikube image load
copies that image straight into the node's containerd store; install-shim.sh
registers the runwasi shim and applies the RuntimeClass BEFORE the ingress
addon is enabled, because the shim install restarts containerd and bounces
every Pod on the node; then `kubectl apply -k overlays/minikube` schedules the
Pod onto that shim via runtimeClassName: wasmtime."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 520

nodes = [
    {"x": 20, "y": 20, "w": 250, "h": 70,
     "lines": ["part2 rust cargo provider", "exports patterncatalyst:cargo/*"],
     "style": "box"},

    {"x": 20, "y": 110, "w": 250, "h": 70,
     "lines": ["part3 http-rust front door", "imports cargo/*, exports wasi:http"],
     "style": "box"},

    {"x": 330, "y": 65, "w": 190, "h": 70,
     "lines": ["wac plug", "provider -> front door"],
     "style": "accent"},

    {"x": 580, "y": 65, "w": 200, "h": 70,
     "lines": ["app.wasm", "sha256 eff7f5ee…", "(gitignored, rebuilt)"],
     "style": "ink"},

    {"x": 840, "y": 20, "w": 300, "h": 70,
     "lines": ["docker build --provenance=false", "FROM scratch, COPY app.wasm", "single plain OCI manifest"],
     "style": "box"},

    {"x": 840, "y": 110, "w": 300, "h": 60,
     "lines": ["minikube image load", "no registry, straight into node's", "containerd image store"],
     "style": "box"},

    {"x": 840, "y": 210, "w": 300, "h": 90,
     "lines": ["install-shim.sh", "download+verify shim, register runtime,", "restart containerd, apply RuntimeClass",
               "(BEFORE the ingress addon)"],
     "style": "accent"},

    {"x": 440, "y": 210, "w": 300, "h": 70,
     "lines": ["minikube addons enable ingress", "(after the shim install, so it starts clean)"],
     "style": "box"},

    {"x": 440, "y": 330, "w": 300, "h": 70,
     "lines": ["kubectl apply -k overlays/minikube", "retag :minikube, imagePullPolicy: Never"],
     "style": "box"},

    {"x": 840, "y": 330, "w": 300, "h": 90,
     "lines": ["Pod cargo-http", "runtimeClassName: wasmtime", "scheduled onto containerd-shim-wasmtime"],
     "style": "user"},

    {"x": 440, "y": 430, "w": 300, "h": 60,
     "lines": ["readiness = a real HTTP 200", "(not rollout Ready: ingress default", "backend 404s during async reload)"],
     "style": "ghost"},
]

edges = [
    {"x1": 270, "y1": 55, "x2": 330, "y2": 90, "label": "plug"},
    {"x1": 270, "y1": 145, "x2": 330, "y2": 110, "label": "plug"},
    {"x1": 520, "y1": 100, "x2": 580, "y2": 100},
    {"x1": 780, "y1": 90, "x2": 840, "y2": 60, "label": "COPY"},
    {"x1": 990, "y1": 90, "x2": 990, "y2": 110},
    {"x1": 990, "y1": 170, "x2": 990, "y2": 210, "dashed": True, "label": "restarts containerd, bounces Pods"},
    {"x1": 840, "y1": 245, "x2": 740, "y2": 245, "amber": True, "label": "do this first"},
    {"x1": 590, "y1": 280, "x2": 590, "y2": 330},
    {"x1": 740, "y1": 365, "x2": 840, "y2": 365, "label": "schedules"},
    {"x1": 590, "y1": 400, "x2": 590, "y2": 430},
]

notes = [
    {"x": 590, "y": 500, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "The same app.wasm Ch14 runs under wasmtime serve and Ch15 deploys to wasmCloud; only the packaging and scheduling around it change."},
]

gd.emit("18-build-package-load-deploy", W, H, nodes=nodes, edges=edges, notes=notes)

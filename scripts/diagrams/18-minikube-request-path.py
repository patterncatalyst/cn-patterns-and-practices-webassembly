#!/usr/bin/env python3
"""Figure 18.1, Ch18: the live request path through minikube, host to
component, with no port-forward anywhere in the chain. curl's own authority
(cargo.<minikube-ip>.nip.io) is a real, publicly resolvable DNS name that
happens to also be the Ingress host rule's exact match. ingress-nginx proxies
to the ClusterIP Service, the kubelet's CNI routes to the one Pod backing it,
and that Pod's runtimeClassName (wasmtime) is what tells containerd to hand
the request to the containerd-shim-wasmtime process instead of runc; the shim
runs a built-in hyper server on 0.0.0.0:8080 and calls straight into
app.wasm's wasi:http/incoming-handler export. Captured live 2026-10-21."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 560

bands = [
    {"x": 20, "y": 170, "w": 1140, "h": 350, "label": "minikube profile 'part5': docker driver, containerd runtime, Kubernetes v1.37.1", "fill": "#f1f5f9"},
]

nodes = [
    {"x": 40, "y": 20, "w": 320, "h": 90,
     "lines": ["curl", "http://cargo.192.168.49.2.nip.io", "/cargo/CARGO-USNYC-DEHAM"],
     "style": "user"},

    {"x": 430, "y": 20, "w": 300, "h": 90,
     "lines": ["nip.io (public wildcard DNS)", "cargo.<minikube-ip>.nip.io -> <minikube-ip>", "no /etc/hosts edit, no tunnel"],
     "style": "ink"},

    {"x": 60, "y": 210, "w": 260, "h": 90,
     "lines": ["ingress-nginx controller v1.15.1", "Ingress cargo-http, host =", "cargo.192.168.49.2.nip.io"],
     "style": "accent"},

    {"x": 380, "y": 210, "w": 220, "h": 70,
     "lines": ["Service cargo-http", "ClusterIP :8080"],
     "style": "box"},

    {"x": 660, "y": 190, "w": 460, "h": 300,
     "lines": ["Pod cargo-http-6f4fc58fbb-ns28x", "", ""],
     "style": "box"},

    {"x": 690, "y": 240, "w": 400, "h": 70,
     "lines": ["runtimeClassName: wasmtime", "routes this Pod to the shim, not runc"],
     "style": "ink"},

    {"x": 690, "y": 330, "w": 400, "h": 80,
     "lines": ["containerd-shim-wasmtime v0.6.1", "hyper server on 0.0.0.0:8080", "(same behavior as wasmtime serve)"],
     "style": "accent"},

    {"x": 690, "y": 430, "w": 400, "h": 50,
     "lines": ["app.wasm: exports wasi:http/incoming-handler", "sha256 eff7f5ee… (same bytes as Ch14/Ch15)"],
     "style": "user"},
]

edges = [
    {"x1": 360, "y1": 65, "x2": 430, "y2": 65, "label": "resolves"},
    {"x1": 200, "y1": 110, "x2": 190, "y2": 210, "label": "GET /cargo/{id}"},
    {"x1": 320, "y1": 245, "x2": 380, "y2": 245, "label": "proxy_pass"},
    {"x1": 600, "y1": 245, "x2": 690, "y2": 265, "label": "kube-proxy / CNI"},
    {"x1": 890, "y1": 310, "x2": 890, "y2": 330, "amber": True},
    {"x1": 890, "y1": 410, "x2": 890, "y2": 430, "amber": True, "label": "incoming-handler.handle"},
]

notes = [
    {"x": 590, "y": 540, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "No port-forward, no NodePort, no `minikube service` anywhere in this path: only the real ingress-nginx edge."},
]

gd.emit("18-minikube-request-path", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

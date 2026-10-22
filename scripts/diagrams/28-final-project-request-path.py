#!/usr/bin/env python3
"""Figure 28.1 — Ch28: the assembled final-project request path on minikube.

A client resolves cargo.<minikube-ip>.nip.io through the nip.io Ingress and
reaches the Istio ingress gateway's Envoy, where the Ch25 proxy-wasm filter
runs first: it rejects any request missing x-cargo-tenant with a 403, and
injects x-cargo-filtered-by on the way back out. Two Pods sit behind the
gateway on RuntimeClass: wasmtime (containerd-shim-wasmtime) — cargo-rust
(http-rust plugged with the Rust cargo provider) and cargo-go (http-go/TinyGo
plugged with the Go cargo provider) — both exporting
wasi:http/incoming-handler and both returning the same cargo JSON. The shim
hosting each Pod emits an OTel span per invocation into otel-lgtm (Tempo):
shim-OTel traces under the workload, same pipeline as Ch24.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1400, 1100

bands = [
    {"x": 20, "y": 110, "w": 1360, "h": 580,
     "label": "minikube — Istio ingress gateway + two app substrates, RuntimeClass: wasmtime",
     "fill": "#f1f5f9"},
    {"x": 20, "y": 720, "w": 1360, "h": 260,
     "label": "OTel pipeline — shim lifecycle spans into otel-lgtm (Tempo)",
     "fill": "#f1f5f9"},
]

nodes = [
    {"x": 40, "y": 20, "w": 160, "h": 60, "lines": ["client"], "style": "sub"},
    {"x": 280, "y": 20, "w": 220, "h": 60, "lines": ["nip.io Ingress"], "style": "box"},

    {"x": 560, "y": 150, "w": 280, "h": 170,
     "lines": ["Istio ingress gateway (Envoy)"],
     "style": "box"},
    {"x": 585, "y": 190, "w": 230, "h": 110,
     "lines": ["proxy-wasm filter", "x-cargo-tenant present? else 403",
               "inject x-cargo-filtered-by on egress"],
     "style": "accent"},

    {"x": 100, "y": 380, "w": 460, "h": 170,
     "lines": ["cargo-rust", "RuntimeClass: wasmtime (containerd-shim-wasmtime)",
               "http-rust ⊕ Rust cargo provider", "exports wasi:http/incoming-handler"],
     "style": "accent"},
    {"x": 840, "y": 380, "w": 460, "h": 170,
     "lines": ["cargo-go", "RuntimeClass: wasmtime (containerd-shim-wasmtime)",
               "http-go/TinyGo ⊕ Go cargo provider", "exports wasi:http/incoming-handler"],
     "style": "accent"},

    {"x": 460, "y": 590, "w": 480, "h": 70,
     "lines": ["same cargo JSON response", "identical payload, either language"],
     "style": "box"},

    {"x": 100, "y": 760, "w": 380, "h": 80,
     "lines": ["containerd-shim-wasmtime (cargo-rust)", "emits OTel span — shim lifecycle"],
     "style": "box"},
    {"x": 920, "y": 760, "w": 380, "h": 80,
     "lines": ["containerd-shim-wasmtime (cargo-go)", "emits OTel span — shim lifecycle"],
     "style": "box"},
    {"x": 560, "y": 880, "w": 280, "h": 80,
     "lines": ["otel-lgtm", "Tempo — shim traces under load"],
     "style": "user"},

    {"x": 20, "y": 1000, "w": 1360, "h": 60,
     "lines": ["Same contract, two languages, one substrate — the gateway filter and the trace span each cover both halves."],
     "style": "ink"},
]

edges = [
    {"x1": 200, "y1": 50, "x2": 280, "y2": 50},
    {"x1": 390, "y1": 80, "x2": 700, "y2": 150},

    {"x1": 620, "y1": 320, "x2": 330, "y2": 380},
    {"x1": 780, "y1": 320, "x2": 1070, "y2": 380},

    {"x1": 330, "y1": 550, "x2": 560, "y2": 590},
    {"x1": 1070, "y1": 550, "x2": 800, "y2": 590},

    {"x1": 290, "y1": 550, "x2": 290, "y2": 760},
    {"x1": 1110, "y1": 550, "x2": 1110, "y2": 760},

    {"x1": 480, "y1": 800, "x2": 560, "y2": 900, "amber": True, "label": "OTel span"},
    {"x1": 920, "y1": 800, "x2": 840, "y2": 900, "amber": True, "label": "OTel span"},
]

notes = [
    {"x": 700, "y": 1090, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "No port-forward: nip.io Ingress and the Istio gateway are the only entry points."},
]

gd.emit("28-final-project-request-path", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

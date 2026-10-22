#!/usr/bin/env python3
"""Figure 25.2 — Ch25: WasmPlugin distribution and the request path.

Control plane (top band): the WasmPlugin CR (extensions.istio.io/v1alpha1)
names an OCI reference — oci://ghcr.io/patterncatalyst/cargo-wasmfilter:istio
— and istiod pulls that reference and pushes the compiled filter module's
config out to every matching Envoy sidecar.

Data plane (bottom band): a client request crosses the Istio ingress
gateway, reaches the Envoy sidecar, and the proxy-wasm filter runs before the
cargo-http component ever sees it. The filter checks for the x-cargo-tenant
header: missing it short-circuits the request with a 403; present, the
request proceeds to the component and the filter injects
x-cargo-filtered-by on the way back out.

TrafficExtension is noted as the newer unified API that supersedes
WasmPlugin for new filter wiring — WasmPlugin itself stays supported.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 800

bands = [
    {"x": 20, "y": 40, "w": 1140, "h": 200,
     "label": "Control plane — the WasmPlugin CR distributes the filter module",
     "fill": "#f1f5f9"},
    {"x": 20, "y": 270, "w": 1140, "h": 340,
     "label": "Data plane — request path through ingress, sidecar filter, and the component",
     "fill": "#f1f5f9"},
]

nodes = [
    # control plane
    {"x": 60, "y": 90, "w": 280, "h": 100,
     "lines": ["oci://ghcr.io/patterncatalyst/", "cargo-wasmfilter:istio"],
     "style": "box"},
    {"x": 400, "y": 90, "w": 300, "h": 100,
     "lines": ["WasmPlugin CR", "extensions.istio.io/v1alpha1"],
     "style": "accent"},
    {"x": 760, "y": 90, "w": 220, "h": 100,
     "lines": ["istiod", "pushes config to sidecars"],
     "style": "user"},

    # data plane
    {"x": 60, "y": 320, "w": 160, "h": 60,
     "lines": ["client"], "style": "sub"},
    {"x": 260, "y": 320, "w": 220, "h": 60,
     "lines": ["Istio ingress gateway"], "style": "box"},
    {"x": 540, "y": 290, "w": 300, "h": 200,
     "lines": ["Envoy sidecar"], "style": "box"},
    {"x": 570, "y": 330, "w": 240, "h": 90,
     "lines": ["proxy-wasm filter", "x-cargo-tenant present? else 403",
               "inject x-cargo-filtered-by on egress"],
     "style": "accent"},
    {"x": 630, "y": 440, "w": 120, "h": 40,
     "lines": ["missing -> 403"], "style": "ghost"},
    {"x": 920, "y": 320, "w": 220, "h": 60,
     "lines": ["cargo-http component", "wasi:http"], "style": "user"},

    {"x": 80, "y": 640, "w": 1020, "h": 100,
     "lines": ["TrafficExtension is the newer unified API and supersedes WasmPlugin for new filter config",
               "WasmPlugin remains supported — existing filters keep working"],
     "style": "ink"},
]

edges = [
    {"x1": 340, "y1": 140, "x2": 400, "y2": 140, "label": "pulls module"},
    {"x1": 700, "y1": 140, "x2": 760, "y2": 140, "label": "registers"},
    {"x1": 870, "y1": 190, "x2": 690, "y2": 290, "dashed": True, "label": "distributes config"},

    {"x1": 220, "y1": 350, "x2": 260, "y2": 350},
    {"x1": 480, "y1": 350, "x2": 540, "y2": 350, "label": "filter runs first"},
    {"x1": 690, "y1": 420, "x2": 690, "y2": 440, "dashed": True, "label": "missing header"},
    {"x1": 810, "y1": 375, "x2": 920, "y2": 350, "label": "tenant header present"},
]

notes = [
    {"x": 590, "y": 785, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Response flows back through the sidecar with x-cargo-filtered-by injected before it reaches the client."},
]

gd.emit("25-wasmplugin-request-path", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

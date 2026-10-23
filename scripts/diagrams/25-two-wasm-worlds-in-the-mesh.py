#!/usr/bin/env python3
"""Figure 25.1, Ch25: two Wasm worlds, across the mesh.

A runtimeClassName: wasmtime pod runs one container runtime for every
container, so an Istio sidecar cannot live beside the Wasm app; the mesh
filter runs in the ingress gateway's Envoy instead. The gateway Pod is a
normal Envoy running the proxy-wasm filter (cargo-wasmfilter), a core-module
artifact built with the proxy-wasm crate, loaded by the gateway's WasmPlugin
CR, which checks the x-cargo-tenant header (403 if missing) and injects
x-cargo-filtered-by. The request then reaches the separate cargo-http Pod,
a pure Wasm pod (runtimeClassName: wasmtime, no sidecar) running the Part 5
Component-Model app under containerd-shim-wasmtime. Two pods, two hosts, two
ABIs, two toolchains.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 760

bands = [
    {"x": 20, "y": 90, "w": 560, "h": 380,
     "label": "Pod: istio-ingress-gateway, normal Envoy, no runtimeClassName",
     "fill": "#f1f5f9"},
    {"x": 600, "y": 90, "w": 560, "h": 380,
     "label": "Pod: cargo-http, runtimeClassName: wasmtime, NO sidecar",
     "fill": "#f1f5f9"},
]

nodes = [
    {"x": 480, "y": 20, "w": 220, "h": 50,
     "lines": ["client request", "GET /cargo/{id}"],
     "style": "sub"},

    {"x": 60, "y": 150, "w": 480, "h": 300,
     "lines": ["Envoy: istio-ingress-gateway", "Istio-managed, ordinary pod"],
     "style": "box"},
    {"x": 640, "y": 150, "w": 480, "h": 300,
     "lines": ["cargo-http Pod", "Part 5 Wasm substrate, unchanged"],
     "style": "box"},

    {"x": 100, "y": 270, "w": 400, "h": 150,
     "lines": ["proxy-wasm filter: cargo-wasmfilter", "core-module ABI (proxy-wasm crate, plain cargo)",
               "loaded by the gateway's WasmPlugin CR",
               "x-cargo-tenant present? else 403 · injects x-cargo-filtered-by"],
     "style": "accent"},
    {"x": 680, "y": 270, "w": 400, "h": 150,
     "lines": ["cargo-http component (wasi:http)", "Component Model ABI (cargo-component)",
               "hosted by containerd-shim-wasmtime"],
     "style": "user"},

    {"x": 80, "y": 510, "w": 1020, "h": 140,
     "lines": ["A runtimeClassName: wasmtime pod runs one container runtime, so the mesh filter runs in the gateway's Envoy, not a sidecar.",
               "Two Wasm ABIs across the mesh: proxy-wasm core module (gateway Envoy) and Component Model (app pod)."],
     "style": "ink"},
]

edges = [
    {"x1": 590, "y1": 70, "x2": 300, "y2": 150, "label": "enters via ingress gateway"},
    {"x1": 500, "y1": 345, "x2": 680, "y2": 345, "label": "mesh hop to cargo-http Pod"},
]

notes = [
    {"x": 590, "y": 745, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "x-cargo-tenant missing stops at the gateway with a 403; present, the request reaches the Component-Model app with x-cargo-filtered-by already injected."},
]

gd.emit("25-two-wasm-worlds-in-the-mesh", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

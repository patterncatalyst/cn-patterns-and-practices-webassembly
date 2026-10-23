#!/usr/bin/env python3
"""Figure 20.1, Ch20: the same embargo+logging interposer, two substrate
expressions.

minikube (top band): compile-time `wac plug` composition. The Part 2 provider,
the sidecar-filter interposer, and the Part 3 http-rust front door are spliced
into ONE app-filtered.wasm, run as a single Pod behind the containerd wasmtime
shim. All three calls for one HTTP request share ONE in-process component
instance.

CRC (bottom band): runtime-link composition. The same three logical pieces run
as THREE SEPARATE wasmCloud components in one lattice, wired by wadm `link`
traits over wRPC at deploy time, not compile time. Each component gets its own
lifecycle and its own fresh instance per invocation.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 620

bands = [
    {"x": 20, "y": 40, "w": 1140, "h": 230,
     "label": "minikube: compile-time composition (wac plug): ONE Pod, ONE component instance",
     "fill": "#f1f5f9"},
    {"x": 20, "y": 320, "w": 1140, "h": 280,
     "label": "CRC: runtime-link composition (wadm links): THREE components, THREE independent lifecycles",
     "fill": "#f1f5f9"},
]

nodes = [
    # --- minikube band ---
    {"x": 60, "y": 90, "w": 230, "h": 70,
     "lines": ["Part 2 provider", "exports patterncatalyst:cargo/*"],
     "style": "box"},
    {"x": 330, "y": 90, "w": 230, "h": 70,
     "lines": ["sidecar-filter", "imports+exports cargo", "embargo + log"],
     "style": "accent"},
    {"x": 600, "y": 90, "w": 230, "h": 70,
     "lines": ["Part 3 http-rust", "imports cargo, exports wasi:http"],
     "style": "box"},
    {"x": 870, "y": 90, "w": 260, "h": 70,
     "lines": ["app-filtered.wasm", "wac plug x2, ONE Pod", "containerd wasmtime shim"],
     "style": "user"},
    {"x": 330, "y": 190, "w": 500, "h": 60,
     "lines": ["one in-process instance serves book-cargo AND get-cargo",
               "for a single HTTP request: HashMap state is shared"],
     "style": "ink"},

    # --- CRC band ---
    {"x": 60, "y": 370, "w": 220, "h": 70,
     "lines": ["cargo-provider-f", "component (fresh instance", "per invocation)"],
     "style": "box"},
    {"x": 330, "y": 370, "w": 220, "h": 70,
     "lines": ["cargo-filter", "interposer component", "(fresh instance per call)"],
     "style": "accent"},
    {"x": 600, "y": 370, "w": 220, "h": 70,
     "lines": ["cargo-filtered", "front door component", "(fresh instance per call)"],
     "style": "box"},
    {"x": 870, "y": 370, "w": 260, "h": 70,
     "lines": ["httpserver provider 0.27.0", "wadm link traits over wRPC", "edge-TLS Route, CA-verified"],
     "style": "user"},
    {"x": 60, "y": 470, "w": 500, "h": 90,
     "lines": ["book-cargo and get-cargo are TWO separate wRPC calls",
               "each gets a fresh instance + reset linear memory;",
               "the provider's in-memory HashMap does not survive the link"],
     "style": "ink"},
]

edges = [
    # minikube chain
    {"x1": 290, "y1": 125, "x2": 330, "y2": 125, "label": "wac plug"},
    {"x1": 560, "y1": 125, "x2": 600, "y2": 125, "label": "wac plug"},
    {"x1": 830, "y1": 125, "x2": 870, "y2": 125},
    {"x1": 480, "y1": 160, "x2": 480, "y2": 190, "dashed": True},

    # CRC chain (links, amber to emphasize runtime wiring)
    {"x1": 280, "y1": 405, "x2": 330, "y2": 405, "amber": True, "label": "link: booking,handling"},
    {"x1": 550, "y1": 405, "x2": 600, "y2": 405, "amber": True, "label": "link: booking"},
    {"x1": 820, "y1": 405, "x2": 870, "y2": 405, "amber": True, "label": "link: incoming-handler"},
    {"x1": 300, "y1": 440, "x2": 300, "y2": 470, "dashed": True},
]

notes = [
    {"x": 590, "y": 605, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Verified live 2026-10-21 on minikube (shim v0.6.1) and CRC (wasmcloud host 1.9.1)."},
]

gd.emit("20-interposition-chain", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

#!/usr/bin/env python3
"""Figure 17.1: how a Pod spec reaches either runc or the Wasm shim.
kubelet hands every Pod to containerd, which looks up the runtime by name.
With no runtimeClassName (or the default runc class), containerd shells out
to runc and a normal Linux container starts. With runtimeClassName: wasmtime
on the Pod spec, containerd instead resolves runtime_type
io.containerd.wasmtime.v1 to the containerd-shim-wasmtime-v1 binary on its
PATH; that shim detects app.wasm exports wasi:http/incoming-handler and runs
it behind its own built-in hyper server on 0.0.0.0:8080; no Linux userland,
no language runtime, just the component. Same kubelet, same containerd, same
Pod API; the handler name is what forks the path."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 700

bands = [
    {"x": 20, "y": 140, "w": 540, "h": 500, "label": "no runtimeClassName (default)", "fill": "#f1f5f9"},
    {"x": 620, "y": 140, "w": 540, "h": 500, "label": "runtimeClassName: wasmtime", "fill": "#fff3e0"},
]

nodes = [
    {"x": 340, "y": 16, "w": 500, "h": 60,
     "lines": ["kubelet schedules the Pod", "same API, one field differs"],
     "style": "accent"},

    {"x": 60, "y": 180, "w": 460, "h": 56,
     "lines": ["containerd (node runtime)"],
     "style": "box"},
    {"x": 60, "y": 252, "w": 460, "h": 56,
     "lines": ["resolves handler: runc (default)"],
     "style": "box"},
    {"x": 60, "y": 324, "w": 460, "h": 56,
     "lines": ["runc creates a Linux container"],
     "style": "box"},
    {"x": 60, "y": 396, "w": 460, "h": 80,
     "lines": ["normal container image:", "OS userland + language runtime + app"],
     "style": "ink"},

    {"x": 660, "y": 180, "w": 460, "h": 56,
     "lines": ["containerd (node runtime)"],
     "style": "box"},
    {"x": 660, "y": 252, "w": 460, "h": 68,
     "lines": ["resolves handler: wasmtime ->", "runtime_type io.containerd.wasmtime.v1"],
     "style": "box"},
    {"x": 660, "y": 336, "w": 460, "h": 56,
     "lines": ["containerd-shim-wasmtime-v1 starts"],
     "style": "box"},
    {"x": 660, "y": 408, "w": 460, "h": 68,
     "lines": ["detects wasi:http/incoming-handler,", "runs wasmtime serve on 0.0.0.0:8080"],
     "style": "box"},
    {"x": 660, "y": 492, "w": 460, "h": 80,
     "lines": ["scratch OCI image: ~290 KiB app.wasm,", "no OS userland, no language runtime"],
     "style": "ink"},

    {"x": 240, "y": 620, "w": 700, "h": 60,
     "lines": ["RuntimeClass (handler: wasmtime) is the object that makes",
               "runtimeClassName a valid, resolvable field value on the Pod"],
     "style": "sub"},
]

edges = [
    {"x1": 500, "y1": 76, "x2": 290, "y2": 140},
    {"x1": 680, "y1": 76, "x2": 890, "y2": 140},

    {"x1": 290, "y1": 236, "x2": 290, "y2": 252},
    {"x1": 290, "y1": 308, "x2": 290, "y2": 324},
    {"x1": 290, "y1": 380, "x2": 290, "y2": 396},

    {"x1": 890, "y1": 236, "x2": 890, "y2": 252},
    {"x1": 890, "y1": 320, "x2": 890, "y2": 336},
    {"x1": 890, "y1": 392, "x2": 890, "y2": 408},
    {"x1": 890, "y1": 476, "x2": 890, "y2": 492},

    {"x1": 290, "y1": 476, "x2": 400, "y2": 620, "amber": True},
    {"x1": 890, "y1": 572, "x2": 780, "y2": 620, "amber": True},
]

notes = [
    {"x": 590, "y": 110, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Installing the shim restarts containerd on the node: bounces every running Pod, do it before other addons."},
]

gd.emit("17-shim-and-runtimeclass-layering", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

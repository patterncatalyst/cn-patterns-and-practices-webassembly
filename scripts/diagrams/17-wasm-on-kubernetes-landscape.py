#!/usr/bin/env python3
"""Figure 17.2: the Wasm-on-Kubernetes landscape as of this book's
2026-10-21 verified run. Four rows, each naming what gets scheduled and what
it will and won't run: runwasi/containerd-shim-wasmtime (this book's
mechanism: any wasi:http/proxy or wasi:cli component, via a generic
containerd shim + RuntimeClass); SpinKube/containerd-shim-spin (a sibling
containerd-shim project scoped to Spin applications specifically, not
arbitrary components, via a SpinApp CRD); the wasmCloud operator (schedules
a wasmCloud host itself as a Pod, then a wadm application deploys onto that
in-cluster lattice: the fallback path if the raw shim had hit a feature
gap, and what the CRC appendix uses); Krustlet (the original kubelet-
replacement approach, archived by its maintainers, history only)."""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 620

nodes = [
    {"x": 20, "y": 20, "w": 260, "h": 56, "lines": ["project"], "style": "sub"},
    {"x": 300, "y": 20, "w": 440, "h": 56, "lines": ["mechanism"], "style": "sub"},
    {"x": 760, "y": 20, "w": 400, "h": 56, "lines": ["scope / status"], "style": "sub"},

    {"x": 20, "y": 96, "w": 260, "h": 80,
     "lines": ["runwasi", "containerd-shim-wasmtime"], "style": "accent"},
    {"x": 300, "y": 96, "w": 440, "h": 80,
     "lines": ["generic containerd shim + RuntimeClass;", "node-install or DaemonSet installer"], "style": "box"},
    {"x": 760, "y": 96, "w": 400, "h": 80,
     "lines": ["any wasi:http/proxy or wasi:cli component;", "THIS BOOK's mechanism (v0.6.1 verified)"], "style": "ink"},

    {"x": 20, "y": 196, "w": 260, "h": 80,
     "lines": ["SpinKube", "containerd-shim-spin"], "style": "box"},
    {"x": 300, "y": 196, "w": 440, "h": 80,
     "lines": ["containerd shim + SpinApp CRD +", "spin-operator"], "style": "box"},
    {"x": 760, "y": 196, "w": 400, "h": 80,
     "lines": ["Spin applications specifically,", "not arbitrary components: Part 6"], "style": "box"},

    {"x": 20, "y": 296, "w": 260, "h": 80,
     "lines": ["wasmCloud operator"], "style": "box"},
    {"x": 300, "y": 296, "w": 440, "h": 80,
     "lines": ["schedules a wasmCloud host as a Pod;", "wadm deploys onto that in-cluster lattice"], "style": "box"},
    {"x": 760, "y": 296, "w": 400, "h": 80,
     "lines": ["fallback if the raw shim hits a gap;", "the path ch19's CRC appendix uses"], "style": "box"},

    {"x": 20, "y": 396, "w": 260, "h": 80,
     "lines": ["Krustlet"], "style": "ghost"},
    {"x": 300, "y": 396, "w": 440, "h": 80,
     "lines": ["kubelet-replacement (virtual kubelet)", "running wasmtime/WAGI providers"], "style": "ghost"},
    {"x": 760, "y": 396, "w": 400, "h": 80,
     "lines": ["ARCHIVED: superseded by the", "containerd-shim approach above"], "style": "ghost"},

    {"x": 20, "y": 510, "w": 1140, "h": 80,
     "lines": ["None of these four compete head-on: pick by what you're deploying",
               "(a generic component, a Spin app, or a wasmCloud lattice) and what you control (the node image)"],
     "style": "sub"},
]

gd.emit("17-wasm-on-kubernetes-landscape", W, H, nodes=nodes)

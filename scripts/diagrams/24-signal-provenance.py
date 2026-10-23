#!/usr/bin/env python3
"""Figure 24.2, Ch24: signal provenance: which layer emits what.

Guest-side instrumentation (wasi-otel) is RC-only at the time of writing and
is NOT used anywhere in this book. Every signal described in Chapter 24 is
substrate-provided: shim-level on minikube, host-level on CRC, never
component-authored. The matrix below makes explicit, signal by signal, which
substrate actually emits traces, metrics, and logs, and which cells are
simply absent.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1040, 540

nodes = [
    {"x": 20, "y": 20, "w": 1000, "h": 70,
     "lines": ["guest wasi-otel is RC-only: NOT used in this book",
               "telemetry here is substrate-provided, not component-authored"],
     "style": "ink"},

    # header row
    {"x": 20, "y": 110, "w": 300, "h": 50, "lines": ["signal"], "style": "sub"},
    {"x": 340, "y": 110, "w": 330, "h": 50,
     "lines": ["minikube: shim-level (containerd-shim-wasmtime)"], "style": "accent"},
    {"x": 690, "y": 110, "w": 330, "h": 50,
     "lines": ["CRC: host-level (wasmCloud host 1.9.1)"], "style": "user"},

    # traces row
    {"x": 20, "y": 180, "w": 300, "h": 80, "lines": ["traces"], "style": "sub"},
    {"x": 340, "y": 180, "w": 330, "h": 80,
     "lines": ["span per invocation,", "emitted by the shim, not the guest"], "style": "box"},
    {"x": 690, "y": 180, "w": 330, "h": 80,
     "lines": ["host + provider spans,", "wRPC call boundaries captured natively"], "style": "box"},

    # metrics row
    {"x": 20, "y": 280, "w": 300, "h": 80, "lines": ["metrics"], "style": "sub"},
    {"x": 340, "y": 280, "w": 330, "h": 80,
     "lines": ["not emitted by the shim:", "cgroup CPU only, via metrics-server"], "style": "ghost"},
    {"x": 690, "y": 280, "w": 330, "h": 80,
     "lines": ["host-native metrics,", "instance counts, invocation rates"], "style": "box"},

    # logs row
    {"x": 20, "y": 380, "w": 300, "h": 80, "lines": ["logs"], "style": "sub"},
    {"x": 340, "y": 380, "w": 330, "h": 80,
     "lines": ["container stdout/stderr only,", "kubelet-captured, not OTel"], "style": "ghost"},
    {"x": 690, "y": 380, "w": 330, "h": 80,
     "lines": ["host-native structured logs,", "via the OTel log pipeline"], "style": "box"},
]

notes = [
    {"x": 520, "y": 500, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Check whether a signal is shim-emitted, host-emitted, or absent before trusting a chapter's \"OTel on Wasm\" claim."},
]

gd.emit("24-signal-provenance", W, H, nodes=nodes, notes=notes)

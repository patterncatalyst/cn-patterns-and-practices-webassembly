#!/usr/bin/env python3
"""Figure for Chapter 9 — Debugging WebAssembly.

09-component-debug-layers : where debug info actually lives once wasm-tools
                             has adapted a core module into a component —
                             the component wrapper itself carries none, the
                             adapter shim carries none, and the one core
                             module with your compiled language's functions
                             carries DWARF only if the toolchain embedded it
                             (TinyGo does by default; a cargo-component
                             --release build does not).
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

gd.emit(
    "09-component-debug-layers", 1180, 600,
    bands=[
        {"x": 20, "y": 16, "w": 1140, "h": 110, "label": "Component boundary — canon lift / canon lower glue, no debug info of its own", "fill": "#f1f5f9"},
        {"x": 20, "y": 142, "w": 1140, "h": 220, "label": "Inside: the core module(s) wasm-tools objdump actually reports", "fill": "#fafafa"},
        {"x": 20, "y": 378, "w": 1140, "h": 180, "label": "What a wasmtime trap backtrace can resolve today, same sentinel panic on both sides", "fill": "#fff3e0"},
    ],
    nodes=[
        {"x": 300, "y": 56, "w": 580, "h": 56,
         "lines": ["patterncatalyst:cargo (component)", "canon lift / canon lower — type-erased core calls become typed WIT calls"],
         "style": "ink"},

        {"x": 60, "y": 184, "w": 420, "h": 80,
         "lines": ["Core module 0 — Rust, cargo-component --release",
                   "custom \"name\" section only",
                   "no .debug_info / .debug_line (no profile.release.debug=true)"],
         "style": "box"},
        {"x": 700, "y": 184, "w": 420, "h": 80,
         "lines": ["Core module 0 — Go, TinyGo -target=wasip1",
                   "custom \"name\" + full DWARF",
                   ".debug_info/.debug_line/.debug_str embedded by default"],
         "style": "box"},
        {"x": 380, "y": 288, "w": 420, "h": 56,
         "lines": ["wasi_snapshot_preview1 adapter (vendored .wasm)",
                   "named functions only — no DWARF either side"],
         "style": "ghost"},

        {"x": 60, "y": 418, "w": 420, "h": 110,
         "lines": ["Rust __TRAP__ backtrace",
                   "demangled crate/fn names, 12 frames",
                   "ends at ...booking@0.1.0#get-cargo",
                   "file:line — NOT shown (no DWARF to read)"],
         "style": "accent"},
        {"x": 700, "y": 418, "w": 420, "h": 110,
         "lines": ["Go __TRAP__ backtrace",
                   "demangled fn names AND file:line",
                   "e.g. go/main.go:166:9",
                   "plus adapter fd_write assert noise on the way out"],
         "style": "accent"},
    ],
    edges=[
        {"x1": 500, "y1": 112, "x2": 270, "y2": 184, "dashed": True, "label": "wraps"},
        {"x1": 680, "y1": 112, "x2": 910, "y2": 184, "dashed": True, "label": "wraps"},
        {"x1": 270, "y1": 264, "x2": 270, "y2": 418, "label": "symbolizer reads"},
        {"x1": 910, "y1": 264, "x2": 910, "y2": 418, "label": "symbolizer reads"},
    ],
    notes=[
        {"x": 590, "y": 580, "text": "Interactive breakpoint stepping across this same boundary (wasmtime run -g/--gdbstub <PORT>, an LLDB gdbstub) attaches at the native/core level — there is no WIT-aware, per-interface source view yet.", "size": 12, "color": "#555555", "anchor": "middle"},
    ],
)

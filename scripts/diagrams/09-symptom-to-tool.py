#!/usr/bin/env python3
"""Figure for Chapter 9: Debugging WebAssembly.

09-symptom-to-tool : six debugging symptoms against the Part 2 cargo
                      components, the cheapest tool that taps each one, and
                      the caveat worth knowing before reaching for it.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

ROW_H = 84
ROWS_Y = 58
SYM_X, SYM_W = 20, 360
TOOL_X, TOOL_W = 410, 390
CAV_X, CAV_W = 830, 350

rows = [
    (["Need the shape before", "running it at all"],
     ["wasm-tools component wit", "<file>.wasm"],
     ["prints the world + interfaces", "embedded in the binary"]),
    (["Need to see the ABI glue", "(canon lift / canon lower)"],
     ["wasm-tools print", "<file>.wasm   (WAT)"],
     ["tens of thousands of lines;", "grep for the export name"]),
    (["Is DWARF even present", "in this artifact?"],
     ["wasm-tools objdump", "<file>.wasm"],
     ["per-section sizes; look for", ".debug_info under each module"]),
    (["Component trapped", "at runtime"],
     ["wasmtime run / host +", "WASMTIME_BACKTRACE_DETAILS=1"],
     ["one frame per call; file:line", "only if that module has DWARF"]),
    (["Need what the component", "wrote on its way down"],
     ["WasiCtxBuilder", "::inherit_stderr()"],
     ["panic/log lines land on", "the host process's own stderr"]),
    (["Need to pause and", "step through source"],
     ["wasmtime run", "-g/--gdbstub <PORT>   (LLDB)"],
     ["native/core level only;", "no WIT-aware source view yet"]),
]

nodes = []
edges = []
for i, (sym, tool, cav) in enumerate(rows):
    y = ROWS_Y + i * ROW_H
    h = ROW_H - 14
    nodes.append({"x": SYM_X, "y": y, "w": SYM_W, "h": h, "lines": sym, "style": "box"})
    nodes.append({"x": TOOL_X, "y": y, "w": TOOL_W, "h": h, "lines": tool, "style": "accent"})
    nodes.append({"x": CAV_X, "y": y, "w": CAV_W, "h": h, "lines": cav, "style": "ink"})
    cy = y + h / 2
    edges.append({"x1": SYM_X + SYM_W, "y1": cy, "x2": TOOL_X, "y2": cy})
    edges.append({"x1": TOOL_X + TOOL_W, "y1": cy, "x2": CAV_X, "y2": cy})

height = ROWS_Y + len(rows) * ROW_H + 50

gd.emit(
    "09-symptom-to-tool", 1200, height,
    bands=[
        {"x": 10, "y": 10, "w": 1180, "h": height - 56, "label": "Symptom  ->  cheapest tool  ->  caveat before you trust it", "fill": "#fafafa"},
    ],
    nodes=nodes,
    edges=edges,
    notes=[
        {"x": 600, "y": height - 18, "text": "All six run against the SAME Part 2 artifacts (rust/target/.../cargo_rust.wasm, go/cargo-go.wasm); none of them require rebuilding or instrumenting the component first.", "size": 12, "color": "#555555", "anchor": "middle"},
    ],
)

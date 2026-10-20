#!/usr/bin/env python3
"""Fig 2.1-2.4 — Ch2: the Wasm execution model. Module vs. instance,
linear-memory bounds-checking, the sandbox boundary against a container's
ambient OS access, and capability passing through the import table."""
import sys
sys.path.insert(0, "scripts")
import generate_diagram
generate_diagram.OUT = "assets/diagrams"

# ---------------------------------------------------------------------------
# Figure 2.1 — module (compile-time) vs. instance (runtime)
# ---------------------------------------------------------------------------
W1, H1 = 860, 440

nodes_1 = [
    {"x": 30, "y": 40, "w": 340, "h": 300,
     "lines": ["Module (.wasm)", "static binary artifact"], "style": "box"},
    {"x": 55, "y": 95, "w": 290, "h": 36, "lines": ["Types"], "style": "sub"},
    {"x": 55, "y": 136, "w": 290, "h": 36, "lines": ["Imports"], "style": "sub"},
    {"x": 55, "y": 177, "w": 290, "h": 36, "lines": ["Functions + Code"], "style": "sub"},
    {"x": 55, "y": 218, "w": 290, "h": 36, "lines": ["Memory + Table"], "style": "sub"},
    {"x": 55, "y": 259, "w": 290, "h": 36, "lines": ["Globals + Exports"], "style": "sub"},
    {"x": 55, "y": 300, "w": 290, "h": 28, "lines": ["Data + Element segments"], "style": "sub"},

    {"x": 490, "y": 40, "w": 340, "h": 300,
     "lines": ["Instance", "runtime object, one per instantiate()"], "style": "accent"},
    {"x": 515, "y": 100, "w": 290, "h": 60,
     "lines": ["own linear memory", "allocated per memory section"], "style": "ink"},
    {"x": 515, "y": 170, "w": 290, "h": 60,
     "lines": ["own table + globals", "initialized from data/element segments"], "style": "ink"},
    {"x": 515, "y": 240, "w": 290, "h": 60,
     "lines": ["resolved imports", "bound to host-supplied functions"], "style": "ink"},
]

edges_1 = [
    {"x1": 370, "y1": 190, "x2": 490, "y2": 190, "label": "instantiate()", "amber": True},
]

notes_1 = [
    {"x": 430, "y": 405, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "A module is compiled and validated once; instantiation is cheap and can happen many times from the same module."},
]

generate_diagram.emit("02-module-structure", W1, H1, nodes=nodes_1, edges=edges_1, notes=notes_1)

# ---------------------------------------------------------------------------
# Figure 2.2 — linear memory layout + bounds checking
# ---------------------------------------------------------------------------
W2, H2 = 860, 340

nodes_2 = [
    {"x": 40, "y": 70, "w": 160, "h": 90, "lines": ["Page 0", "offset 0-65535"], "style": "box"},
    {"x": 210, "y": 70, "w": 160, "h": 90, "lines": ["Page 1", "offset 65536-131071"], "style": "box"},
    {"x": 380, "y": 70, "w": 160, "h": 90, "lines": ["Page 2", "offset 131072-196607"], "style": "box"},
    {"x": 550, "y": 70, "w": 160, "h": 90, "lines": ["memory.grow", "adds another 64 KiB page"], "style": "ghost"},

    {"x": 40, "y": 220, "w": 300, "h": 70,
     "lines": ["in-bounds load at offset 4096", "succeeds: inside current memory size"], "style": "ink"},
    {"x": 420, "y": 220, "w": 300, "h": 70,
     "lines": ["load past offset 196607", "traps: outside current memory size"], "style": "ink"},
]

edges_2 = [
    {"x1": 190, "y1": 150, "x2": 190, "y2": 220, "label": "ok", "amber": True},
    {"x1": 460, "y1": 160, "x2": 460, "y2": 220, "label": "bounds check fails"},
]

notes_2 = [
    {"x": 430, "y": 30, "size": 13, "color": "#1d1d1d", "anchor": "middle", "bold": True,
     "text": "Linear memory: one contiguous byte array, indexed from 0, growing in 64 KiB pages"},
    {"x": 430, "y": 320, "size": 12, "color": "#b8650a", "anchor": "middle", "bold": True,
     "text": "Every load/store is bounds-checked against the instance's current memory size, not just at the edges."},
]

generate_diagram.emit("02-linear-memory", W2, H2, nodes=nodes_2, edges=edges_2, notes=notes_2)

# ---------------------------------------------------------------------------
# Figure 2.3 — sandbox boundary: container ambient access vs. Wasm's none-by-default
# ---------------------------------------------------------------------------
W3, H3 = 860, 420

LEFT = {"x": 40, "w": 350}
RIGHT = {"x": 470, "w": 350}

nodes_3 = [
    {"x": LEFT["x"], "y": 20, "w": LEFT["w"], "h": 50, "lines": ["Host OS"], "style": "box"},
    {"x": LEFT["x"] + 30, "y": 90, "w": LEFT["w"] - 60, "h": 90,
     "lines": ["Container process", "default: ambient syscall access"], "style": "user"},
    {"x": LEFT["x"], "y": 220, "w": LEFT["w"], "h": 160,
     "lines": ["filesystem, network, syscalls", "namespaces / cgroups / seccomp", "narrow this AFTER the fact"], "style": "ghost"},

    {"x": RIGHT["x"], "y": 20, "w": RIGHT["w"], "h": 50, "lines": ["Host OS"], "style": "box"},
    {"x": RIGHT["x"] + 20, "y": 90, "w": RIGHT["w"] - 40, "h": 120,
     "lines": ["Wasm engine"], "style": "accent"},
    {"x": RIGHT["x"] + 45, "y": 130, "w": RIGHT["w"] - 90, "h": 60,
     "lines": ["Guest instance", "own linear memory, own stack"], "style": "ink"},
    {"x": RIGHT["x"], "y": 260, "w": RIGHT["w"], "h": 120,
     "lines": ["filesystem, network, syscalls", "NO default path in; only", "named imports cross the boundary"], "style": "ghost"},
]

edges_3 = [
    {"x1": LEFT["x"] + LEFT["w"]/2, "y1": 180, "x2": LEFT["x"] + LEFT["w"]/2, "y2": 220,
     "label": "ambient by default", "dashed": True},
    {"x1": RIGHT["x"] + RIGHT["w"]/2, "y1": 190, "x2": RIGHT["x"] + RIGHT["w"]/2, "y2": 260,
     "label": "only named imports", "amber": True},
]

notes_3 = [
    {"x": 215, "y": 405, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Container: isolation is subtracted from a starting position of broad access."},
    {"x": 645, "y": 405, "size": 12, "color": "#b8650a", "anchor": "middle", "bold": True,
     "text": "Wasm: access is added, one import at a time, from a starting position of none."},
]

generate_diagram.emit("02-sandbox-boundary", W3, H3, nodes=nodes_3, edges=edges_3, notes=notes_3)

# ---------------------------------------------------------------------------
# Figure 2.4 — capability passing through the import table
# ---------------------------------------------------------------------------
W4, H4 = 860, 380

nodes_4 = [
    {"x": 40, "y": 40, "w": 300, "h": 280, "lines": ["Host process", "functions available internally"], "style": "box"},
    {"x": 65, "y": 95, "w": 250, "h": 40, "lines": ["host_log"], "style": "accent"},
    {"x": 65, "y": 145, "w": 250, "h": 40, "lines": ["host_fetch"], "style": "ghost"},
    {"x": 65, "y": 195, "w": 250, "h": 40, "lines": ["write_file"], "style": "ghost"},
    {"x": 65, "y": 245, "w": 250, "h": 40, "lines": ["open_socket"], "style": "ghost"},

    {"x": 500, "y": 40, "w": 320, "h": 280,
     "lines": ["Guest instance", "import table resolved at instantiate()"], "style": "box"},
    {"x": 525, "y": 150, "w": 270, "h": 50, "lines": ["host_log", "the only reachable import"], "style": "ink"},
]

edges_4 = [
    {"x1": 315, "y1": 115, "x2": 500, "y2": 175, "label": "linked in", "amber": True},
]

notes_4 = [
    {"x": 430, "y": 25, "size": 13, "color": "#1d1d1d", "anchor": "middle", "bold": True,
     "text": "The host chooses, function by function, what crosses into a guest's imports"},
    {"x": 430, "y": 355, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "host_fetch, write_file, and open_socket exist in the host process but have no path into this guest at all."},
]

generate_diagram.emit("02-capability-passing", W4, H4, nodes=nodes_4, edges=edges_4, notes=notes_4)

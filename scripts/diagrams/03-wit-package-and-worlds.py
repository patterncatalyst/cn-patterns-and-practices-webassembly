#!/usr/bin/env python3
"""Fig 3.1/3.2: Ch3: the patterncatalyst:cargo@0.1.0 package as it appears
in contracts/wit/ (types -> booking/handling by `use`), and the same three
interfaces re-read through the two worlds that bind them to a direction
(cargo exports, cargo-consumer imports)."""
import sys
sys.path.insert(0, "scripts")
import generate_diagram
generate_diagram.OUT = "assets/diagrams"
import os
os.makedirs(generate_diagram.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 3.1: the cargo package: one shared interface, two behavior interfaces
# ---------------------------------------------------------------------------
W1, H1 = 820, 400

nodes_1 = [
    {"x": 240, "y": 15, "w": 340, "h": 110,
     "lines": ["interface types", "record location, money, cargo, route-spec,",
               "booking, leg, itinerary, handling-event",
               "enum handling-event-type, routing-status,",
               "transport-status · variant cargo-error"],
     "style": "ink"},

    {"x": 80, "y": 190, "w": 300, "h": 110,
     "lines": ["interface booking",
               "use types.{cargo, booking, route-spec,",
               "itinerary, cargo-error}",
               "book-cargo · request-possible-routes",
               "assign-route · get-cargo"],
     "style": "accent"},

    {"x": 440, "y": 190, "w": 300, "h": 125,
     "lines": ["interface handling",
               "use types.{handling-event, handling-event-type,",
               "location, transport-status, cargo-error}",
               "resource cargo-tracker",
               "register-handling-event",
               "list-handling-events"],
     "style": "accent"},
]

edges_1 = [
    {"x1": 340, "y1": 125, "x2": 260, "y2": 190,
     "label": "use types.{...}"},
    {"x1": 480, "y1": 125, "x2": 570, "y2": 190,
     "label": "use types.{...}"},
]

notes_1 = [
    {"x": 410, "y": 370, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "One package, patterncatalyst:cargo@0.1.0: types carries no functions, booking and handling add behavior over it."},
]

generate_diagram.emit("03-wit-package-structure", W1, H1, nodes=nodes_1, edges=edges_1, notes=notes_1)

# ---------------------------------------------------------------------------
# Figure 3.2: a world is a direction over the same interfaces
# ---------------------------------------------------------------------------
W2, H2 = 820, 380

nodes_2 = [
    {"x": 260, "y": 15, "w": 300, "h": 95,
     "lines": ["the three interfaces", "types · booking · handling",
               "identical on both sides"],
     "style": "ink"},

    {"x": 60, "y": 180, "w": 320, "h": 130,
     "lines": ["world cargo", "export types;", "export booking;", "export handling;",
               "a provider component targets this"],
     "style": "user"},

    {"x": 440, "y": 180, "w": 320, "h": 130,
     "lines": ["world cargo-consumer", "import types;", "import booking;", "import handling;",
               "a caller component targets this"],
     "style": "accent"},
]

edges_2 = [
    {"x1": 340, "y1": 110, "x2": 230, "y2": 180,
     "label": "export"},
    {"x1": 480, "y1": 110, "x2": 590, "y2": 180,
     "label": "import"},
    {"x1": 380, "y1": 245, "x2": 440, "y2": 245,
     "label": "same shape, opposite direction", "dashed": True, "bidir": True},
]

notes_2 = [
    {"x": 410, "y": 355, "size": 12, "color": "#b8650a", "anchor": "middle", "bold": True,
     "text": "A world names no new types; it only declares which direction each interface faces."},
]

generate_diagram.emit("03-world-imports-vs-exports", W2, H2, nodes=nodes_2, edges=edges_2, notes=notes_2)

#!/usr/bin/env python3
"""Figures for Chapter 5: The Shared Cargo Domain as Components.

05-domain-to-wit : the domain-to-WIT mapping: which domain concept lands
                    in which interface of package patterncatalyst:cargo,
                    and which world (cargo vs cargo-consumer) a Rust or Go
                    component targets depending on whether it implements
                    the domain or only calls into it.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 5.2: domain concepts mapped onto the three WIT interfaces, and the
# two worlds built over them
# ---------------------------------------------------------------------------
gd.emit(
    "05-domain-to-wit", 1040, 640,
    bands=[
        {"x":20,"y":16,"w":1000,"h":104,"label":"interface types: records + enums + cargo-error, no functions","fill":"#f1f5f9"},
        {"x":20,"y":132,"w":1000,"h":92,"label":"interface booking: book-cargo, request-possible-routes, assign-route, get-cargo","fill":"#fafafa"},
        {"x":20,"y":236,"w":1000,"h":92,"label":"interface handling: register-handling-event, list-handling-events, resource cargo-tracker","fill":"#fafafa"},
        {"x":20,"y":344,"w":1000,"h":110,"label":"world cargo (export types, booking, handling) / world cargo-consumer (import types, booking, handling)","fill":"#fff3e0"},
    ],
    nodes=[
        {"x":50,"y":52,"w":200,"h":56,"lines":["location, money"],"style":"ink"},
        {"x":270,"y":52,"w":220,"h":56,"lines":["cargo, route-spec, booking"],"style":"ink"},
        {"x":510,"y":52,"w":220,"h":56,"lines":["leg, itinerary, handling-event"],"style":"ink"},
        {"x":750,"y":52,"w":250,"h":56,"lines":["handling-event-type, routing-status,","transport-status, cargo-error"],"style":"ink"},

        {"x":50,"y":164,"w":460,"h":48,"lines":["book-cargo(route-spec, f64) -> result<booking, cargo-error>"],"style":"box"},
        {"x":530,"y":164,"w":460,"h":48,"lines":["request-possible-routes / assign-route / get-cargo"],"style":"box"},

        {"x":50,"y":268,"w":440,"h":48,"lines":["register-handling-event / list-handling-events"],"style":"box"},
        {"x":510,"y":268,"w":480,"h":48,"lines":["resource cargo-tracker: constructor + tracking-id/current-status/history"],"style":"box"},

        {"x":50,"y":376,"w":440,"h":60,"lines":["world cargo","exports types, booking, handling"],"style":"accent"},
        {"x":550,"y":376,"w":440,"h":60,"lines":["world cargo-consumer","imports types, booking, handling"],"style":"accent"},

        {"x":50,"y":480,"w":200,"h":60,"lines":["Rust component","cargo-component"],"style":"box"},
        {"x":270,"y":480,"w":200,"h":60,"lines":["Go component","wasm-tools"],"style":"box"},
        {"x":720,"y":480,"w":260,"h":60,"lines":["Consumer component","HTTP/gRPC adapter, Ch11/12"],"style":"box"},
    ],
    edges=[
        {"x1":150,"y1":480,"x2":220,"y2":436,"label":"implements, exports"},
        {"x1":370,"y1":480,"x2":280,"y2":436,"label":"implements, exports"},
        {"x1":850,"y1":480,"x2":770,"y2":436,"label":"imports, calls"},
        {"x1":490,"y1":406,"x2":550,"y2":406,"label":"composed together, Ch8","dashed":True},
    ],
    notes=[
        {"x":520,"y":620,"text":"types carries no behavior; booking and handling add functions over it. Both worlds import or export all three interfaces together.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

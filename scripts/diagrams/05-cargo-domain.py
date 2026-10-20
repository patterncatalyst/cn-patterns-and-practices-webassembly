#!/usr/bin/env python3
"""Figures for Chapter 5 — The Shared Cargo Domain as Components.

05-cargo-domain : the domain's entities and how they relate — a route-spec
                  and a cargo feed a booking, a booking produces an
                  itinerary made of legs, a handling-event is recorded
                  against a cargo, and a cargo-tracker resource follows
                  that history — with location and money as shared value
                  types several entities reference.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 5.1 — cargo domain model: entities and relationships
# ---------------------------------------------------------------------------
gd.emit(
    "05-cargo-domain", 1000, 560,
    bands=[
        {"x":20,"y":16,"w":580,"h":500,"label":"The booking → itinerary → handling flow","fill":"#fafafa"},
        {"x":620,"y":16,"w":360,"h":500,"label":"Shared value types","fill":"#f1f5f9"},
    ],
    nodes=[
        {"x":50,"y":56,"w":240,"h":70,"lines":["route-spec","origin, destination, arrival-deadline"],"style":"box"},
        {"x":330,"y":56,"w":240,"h":70,"lines":["cargo","tracking-id, weight-kg"],"style":"box"},

        {"x":170,"y":166,"w":280,"h":78,"lines":["booking","booking-id, cargo-id, route-spec,","price, status"],"style":"accent"},

        {"x":50,"y":284,"w":240,"h":70,"lines":["itinerary","booking-id, legs"],"style":"box"},
        {"x":330,"y":284,"w":240,"h":70,"lines":["leg","voyage-id, load/unload, status"],"style":"box"},

        {"x":50,"y":404,"w":280,"h":80,"lines":["handling-event","cargo-id, event-type, location,","voyage-id, recorded-at"],"style":"box"},
        {"x":360,"y":404,"w":220,"h":80,"lines":["cargo-tracker (resource)","tracking-id, current-status, history"],"style":"accent"},

        {"x":660,"y":56,"w":280,"h":70,"lines":["location","unlocode, name, country"],"style":"ink"},
        {"x":660,"y":176,"w":280,"h":70,"lines":["money","amount (decimal string), currency"],"style":"ink"},
    ],
    edges=[
        {"x1":200,"y1":126,"x2":300,"y2":166,"label":"booking.route-spec"},
        {"x1":420,"y1":126,"x2":380,"y2":166,"label":"booking.cargo-id"},
        {"x1":260,"y1":244,"x2":170,"y2":284,"label":"itinerary.booking-id"},
        {"x1":290,"y1":319,"x2":330,"y2":319,"label":"composed of"},
        {"x1":190,"y1":354,"x2":190,"y2":404,"label":"cargo-id","dashed":True},
        {"x1":330,"y1":444,"x2":360,"y2":444,"label":"history()"},

        {"x1":290,"y1":75,"x2":660,"y2":90,"label":"origin/destination","dashed":True},
        {"x1":570,"y1":319,"x2":660,"y2":200,"label":"load/unload","dashed":True},
        {"x1":330,"y1":430,"x2":660,"y2":230,"label":"location","dashed":True},
        {"x1":450,"y1":195,"x2":660,"y2":211,"label":"price","dashed":True},
    ],
    notes=[
        {"x":500,"y":540,"text":"Solid arrows: a record field referencing another record by id or by composition. Dashed arrows: a field typed as a shared value, not a nested object.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

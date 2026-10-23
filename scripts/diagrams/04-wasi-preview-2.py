#!/usr/bin/env python3
"""Figures for Chapter 4: WASI Preview 2.

04-capability-grant : the capability-grant model: a host holding resource
                       handles and handing specific ones to a guest instance,
                       with no ambient syscall path from guest to kernel.
04-wasi-world-map   : a component's WIT world importing from the base WASI
                       interfaces, with wasi-http/sockets/nn flagged as
                       later-chapter topics.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 4.1: capability-grant model: host grants handles, nothing ambient
# ---------------------------------------------------------------------------
gd.emit(
    "04-capability-grant", 940, 420,
    bands=[
        {"x":20,"y":16,"w":420,"h":384,"label":"Host: holds resource handles","fill":"#fafafa"},
        {"x":500,"y":16,"w":420,"h":384,"label":"Wasm guest instance: holds only what it's handed","fill":"#f1f5f9"},
    ],
    nodes=[
        {"x":50,"y":66,"w":340,"h":56,"lines":["Clock handle","wasi:clocks/monotonic-clock"],"style":"box"},
        {"x":50,"y":142,"w":340,"h":56,"lines":["Filesystem handle","preopened dir: /data/cargo"],"style":"box"},
        {"x":50,"y":218,"w":340,"h":56,"lines":["Socket handle","outbound TCP, port 443"],"style":"ghost"},
        {"x":50,"y":312,"w":340,"h":64,"lines":["Host kernel","syscalls live here only"],"style":"ink"},

        {"x":530,"y":80,"w":360,"h":56,"lines":["Granted: clock capability","usable inside the instance"],"style":"accent"},
        {"x":530,"y":156,"w":360,"h":56,"lines":["Granted: filesystem capability","scoped to /data/cargo only"],"style":"accent"},
        {"x":530,"y":280,"w":360,"h":70,"lines":["No socket capability granted","guest cannot open a connection"],"style":"ink"},
    ],
    edges=[
        {"x1":390,"y1":94,"x2":530,"y2":108,"label":"grant","amber":True},
        {"x1":390,"y1":170,"x2":530,"y2":184,"label":"grant (scoped)","amber":True},
        {"x1":390,"y1":246,"x2":530,"y2":300,"label":"not granted","dashed":True},
        {"x1":680,"y1":350,"x2":280,"y2":344,"label":"no ambient syscalls, no direct path","dashed":True},
    ],
    notes=[
        {"x":470,"y":410,"text":"The guest cannot ask for what the host did not already hand it.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

# ---------------------------------------------------------------------------
# Figure 4.2: WASI Preview 2 world map: one component's imports
# ---------------------------------------------------------------------------
gd.emit(
    "04-wasi-world-map", 960, 460,
    bands=[
        {"x":20,"y":16,"w":920,"h":180,"label":"WASI 0.2.x base interfaces: Foundations, covered this chapter","fill":"#f1f5f9"},
        {"x":20,"y":212,"w":920,"h":150,"label":"WASI 0.2.x interfaces: covered in later chapters","fill":"#fff3e0"},
    ],
    nodes=[
        {"x":48,"y":58,"w":160,"h":62,"lines":["wasi:io","streams, pollable"],"style":"box"},
        {"x":228,"y":58,"w":160,"h":62,"lines":["wasi:cli","stdio, env, args"],"style":"box"},
        {"x":408,"y":58,"w":160,"h":62,"lines":["wasi:clocks","wall + monotonic"],"style":"box"},
        {"x":588,"y":58,"w":160,"h":62,"lines":["wasi:filesystem","scoped dir handles"],"style":"box"},
        {"x":768,"y":58,"w":148,"h":62,"lines":["wasi:random","secure + insecure"],"style":"box"},

        {"x":80,"y":252,"w":220,"h":70,"lines":["wasi:http","Ch 11"],"style":"accent"},
        {"x":360,"y":252,"w":220,"h":70,"lines":["wasi:sockets","Ch 13"],"style":"accent"},
        {"x":640,"y":252,"w":220,"h":70,"lines":["wasi:nn","Ch 27"],"style":"accent"},

        {"x":280,"y":388,"w":400,"h":56,"lines":["This component's WIT world","imports a subset of the above, by name"],"style":"ink"},
    ],
    edges=[
        {"x1":480,"y1":120,"x2":480,"y2":388,"label":"imported by the world","dashed":True},
        {"x1":190,"y1":322,"x2":420,"y2":388,"label":"imported when needed","dashed":True},
    ],
    notes=[
        {"x":480,"y":450,"text":"A world names exactly which interfaces it imports; the host decides at instantiation whether to satisfy them.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

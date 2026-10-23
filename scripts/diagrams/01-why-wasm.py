#!/usr/bin/env python3
"""Figures for Chapter 1: Why Server-Side WebAssembly.

01-isolation-spectrum : VM vs container vs Wasm component, compared on
                         isolation mechanism, image size, and cold-start time.
01-request-path        : a request entering a cluster and landing on a Wasm
                          component instance under wasmtime, loaded from an
                          OCI-pushed .wasm artifact, next to a container pod.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 1.1: isolation / startup spectrum: VM vs container vs Wasm component
# ---------------------------------------------------------------------------
gd.emit(
    "01-isolation-spectrum", 940, 460,
    bands=[
        {"x":20,"y":16,"w":900,"h":130,"label":"Virtual machine: hardware-virtualized, own kernel","fill":"#fafafa"},
        {"x":20,"y":164,"w":900,"h":130,"label":"Container: shared host kernel, namespace + cgroup isolation","fill":"#fff3e0"},
        {"x":20,"y":312,"w":900,"h":132,"label":"Wasm component: sandboxed by the runtime, no syscalls by default","fill":"#f1f5f9"},
    ],
    nodes=[
        {"x":50,"y":50,"w":220,"h":80,"lines":["Guest kernel + OS","full hardware emulation"],"style":"box"},
        {"x":330,"y":50,"w":200,"h":80,"lines":["Image: GBs","Cold start: seconds"],"style":"ghost"},
        {"x":590,"y":50,"w":300,"h":80,"lines":["Isolation: hardware (hypervisor)","Strongest, heaviest"],"style":"ink"},

        {"x":50,"y":198,"w":220,"h":80,"lines":["Shared host kernel","namespaces + cgroups"],"style":"box"},
        {"x":330,"y":198,"w":200,"h":80,"lines":["Image: tens of MBs","Cold start: ~100s of ms"],"style":"ghost"},
        {"x":590,"y":198,"w":300,"h":80,"lines":["Isolation: kernel boundary","Shared attack surface with host"],"style":"ink"},

        {"x":50,"y":346,"w":220,"h":84,"lines":["wasmtime / wasmCloud","capability-based sandbox"],"style":"box"},
        {"x":330,"y":346,"w":200,"h":84,"lines":["Image: single-digit MBs","Cold start: single-digit ms"],"style":"accent"},
        {"x":590,"y":346,"w":300,"h":84,"lines":["Isolation: no ambient syscalls","deny-by-default, host grants capabilities"],"style":"ink"},
    ],
    edges=[],
    notes=[
        {"x":470,"y":440,"text":"Lower = lighter weight, faster to start, narrower default capability surface.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

# ---------------------------------------------------------------------------
# Figure 1.2: request path to a Wasm component on a cluster, next to a
# container pod serving the same interface
# ---------------------------------------------------------------------------
gd.emit(
    "01-request-path", 940, 420,
    bands=[
        {"x":20,"y":16,"w":900,"h":180,"label":"Node A: container pod","fill":"#fafafa"},
        {"x":20,"y":216,"w":900,"h":184,"label":"Node B: wasmtime host running Wasm components","fill":"#f1f5f9"},
    ],
    nodes=[
        {"x":40,"y":180,"w":180,"h":44,"lines":["Ingress / Service"],"style":"user"},

        {"x":260,"y":56,"w":220,"h":70,"lines":["Container pod","booking-service:1.4 image"],"style":"box"},
        {"x":540,"y":56,"w":220,"h":70,"lines":["Container runtime (runc)","cgroup + namespace per pod"],"style":"ghost"},
        {"x":780,"y":56,"w":120,"h":70,"lines":["Host kernel"],"style":"box"},

        {"x":260,"y":256,"w":220,"h":70,"lines":["booking.wasm component","pulled from OCI registry"],"style":"accent"},
        {"x":540,"y":256,"w":220,"h":70,"lines":["wasmtime instance","one per request or pooled"],"style":"ink"},
        {"x":780,"y":256,"w":120,"h":70,"lines":["WASI Preview 2","capabilities granted"],"style":"ink"},

        {"x":40,"y":330,"w":180,"h":44,"lines":["Same WIT interface","booking, handling"],"style":"user"},
    ],
    edges=[
        {"x1":220,"y1":202,"x2":260,"y2":91,"label":"route to pod"},
        {"x1":480,"y1":91,"x2":540,"y2":91,"label":"syscalls, scheduled"},
        {"x1":760,"y1":91,"x2":780,"y2":91,"label":"direct"},

        {"x1":220,"y1":280,"x2":260,"y2":291,"label":"route to instance","amber":True},
        {"x1":480,"y1":291,"x2":540,"y2":291,"label":"host calls only","amber":True},
        {"x1":760,"y1":291,"x2":780,"y2":291,"label":"explicit grant","amber":True},
        {"x1":220,"y1":352,"x2":260,"y2":306,"label":"instantiate, run, exit","dashed":True},
    ],
    notes=[
        {"x":470,"y":404,"text":"Same WIT contract, two execution shapes: a scheduled OS process versus an instantiated sandbox.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

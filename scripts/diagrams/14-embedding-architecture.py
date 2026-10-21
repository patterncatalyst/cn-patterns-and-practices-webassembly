#!/usr/bin/env python3
"""Figure for Chapter 14 — wasmtime: embedding architecture.

14-embedding-architecture : the native host (host/src/main.rs) building an
                             Engine/Store/Linker, wiring WASI and the
                             host-caps import, instantiating the guest
                             component, and the guest calling back across
                             the boundary into the host-provided functions.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 14.1 — host Engine/Store/Linker wiring a host-provided import, then
# instantiating and calling the guest component.
# ---------------------------------------------------------------------------
gd.emit(
    "14-embedding-architecture", 1080, 620,
    bands=[
        {"x":20,"y":16,"w":500,"h":560,"label":"host-demo-host (native Rust, wasmtime crate)","fill":"#f1f5f9"},
        {"x":560,"y":16,"w":500,"h":560,"label":"host_demo_guest.wasm — imports host-caps, exports run","fill":"#fff3e0"},
    ],
    nodes=[
        {"x":50,"y":56,"w":440,"h":56,"lines":["Engine::new(&Config::new())"],"style":"box"},
        {"x":50,"y":128,"w":440,"h":70,"lines":["Linker::new(&engine)","wasmtime_wasi::p2::add_to_linker_sync(&mut linker)"],"style":"box"},
        {"x":50,"y":214,"w":440,"h":70,"lines":["host_caps::add_to_linker::<HostState, HasSelf<HostState>>","(&mut linker, |s| s)"],"style":"ink"},
        {"x":50,"y":300,"w":440,"h":56,"lines":["Store::new(&engine, HostState { .. })","store.limiter(|s| &mut s.limits)"],"style":"box"},
        {"x":50,"y":372,"w":440,"h":56,"lines":["HostDemo::instantiate(&mut store, &component, &linker)"],"style":"box"},
        {"x":50,"y":444,"w":440,"h":56,"lines":["bindings.call_run(&mut store, \"clean\", 10_000)"],"style":"box"},
        {"x":50,"y":516,"w":440,"h":48,"lines":["impl host_caps::Host for HostState {","  fn host_quote(&mut self, id) -> String { .. }","  fn host_now(&mut self) -> u64 { .. } }"],"style":"ink"},

        {"x":600,"y":128,"w":420,"h":56,"lines":["Component — wit world host-demo"],"style":"box"},
        {"x":600,"y":372,"w":420,"h":56,"lines":["export run(mode, iterations) -> string"],"style":"box"},
        {"x":600,"y":444,"w":420,"h":70,"lines":["import host-caps::host-quote(id)","import host-caps::host-now()"],"style":"accent"},
    ],
    edges=[
        {"x1":490,"y1":164,"x2":600,"y2":156,"label":"links"},
        {"x1":490,"y1":400,"x2":600,"y2":400,"label":"call across component boundary"},
        {"x1":600,"y1":479,"x2":490,"y2":540,"label":"guest calls host import"},
    ],
    notes=[
        {"x":540,"y":600,"text":"The Linker closure is the whole of the guest's ambient authority: host-caps is the only thing the guest can reach that the host did not export itself.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

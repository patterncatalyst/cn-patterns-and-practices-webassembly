#!/usr/bin/env python3
"""Figure for Chapter 7 — First Component in Go.

07-go-build-pipeline : the full build pipeline from the shared WIT contract
                        to the finished cargo-go.wasm component — bindings
                        generation, standard Go source, the TinyGo compile
                        step (not `go build`), and the two wasm-tools steps
                        that turn a wasip1 core module into a component.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# Figure 7.1 — the Go build pipeline: contract to component
# ---------------------------------------------------------------------------
gd.emit(
    "07-go-build-pipeline", 1180, 520,
    bands=[
        {"x":20,"y":16,"w":1140,"h":180,"label":"Generation — standard Go, nothing TinyGo-specific yet","fill":"#f1f5f9"},
        {"x":20,"y":216,"w":1140,"h":120,"label":"Compilation — the one step that must be TinyGo","fill":"#fff3e0"},
        {"x":20,"y":356,"w":1140,"h":148,"label":"Componentization — wasm-tools, same for any language","fill":"#fafafa"},
    ],
    nodes=[
        {"x":50,"y":62,"w":210,"h":90,"lines":["contracts/wit/","patterncatalyst:cargo@0.1.0"],"style":"box"},
        {"x":320,"y":62,"w":260,"h":90,"lines":["wit-bindgen-go generate","-o internal/cargo --world cargo"],"style":"box"},
        {"x":640,"y":56,"w":240,"h":100,"lines":["internal/cargo/**","Exports struct vars, cm types","(generated, DO NOT EDIT)"],"style":"box"},
        {"x":930,"y":56,"w":200,"h":100,"lines":["main.go + cabi_realloc.go","hand-written, ordinary Go"],"style":"accent"},

        {"x":350,"y":252,"w":280,"h":62,"lines":["tinygo build -target=wasip1","-buildmode=c-shared -o core.wasm ."],"style":"accent"},
        {"x":720,"y":252,"w":220,"h":62,"lines":["core.wasm","wasip1 reactor core module"],"style":"box"},

        {"x":50,"y":400,"w":320,"h":76,"lines":["wasm-tools component embed","contracts/wit --world cargo core.wasm"],"style":"box"},
        {"x":430,"y":400,"w":340,"h":76,"lines":["wasm-tools component new","--adapt wasi_snapshot_preview1=","adapters/...reactor.wasm"],"style":"box"},
        {"x":850,"y":400,"w":270,"h":76,"lines":["cargo-go.wasm","exports world cargo"],"style":"accent"},
    ],
    edges=[
        {"x1":260,"y1":107,"x2":320,"y2":107,"label":""},
        {"x1":580,"y1":107,"x2":640,"y2":107,"label":"generates"},
        {"x1":880,"y1":107,"x2":930,"y2":107,"label":"imports"},

        {"x1":1030,"y1":156,"x2":490,"y2":252,"label":"compiled by","dashed":True},
        {"x1":630,"y1":283,"x2":720,"y2":283,"label":""},

        {"x1":830,"y1":314,"x2":210,"y2":400,"label":"input to embed","dashed":True},
        {"x1":370,"y1":438,"x2":430,"y2":438,"label":"embedded.wasm"},
        {"x1":770,"y1":438,"x2":850,"y2":438,"label":"adapt + wrap"},
    ],
    notes=[
        {"x":590,"y":500,"text":"The source and the generated bindings are standard, idiomatic Go throughout; only the compiler in the middle band differs from `go build`.","size":12,"color":"#555555","anchor":"middle"},
    ],
)

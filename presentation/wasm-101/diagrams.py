"""
diagrams.py — NEW companion-deck diagrams for "Server-Side WebAssembly" (101).

Red Hat-aligned Scene diagrams for figures that do not already exist in the
book's assets/diagrams/ library. Author here, then run build_diagrams.py
(it renders the full book figure library first, then builds + renders these).

Color by kind: rest=red (edge/API surface), svc=blue (services/clients),
data=purple (stores/state), platform=teal (infra/platform), govern=amber
(policy/coordination), danger=deep-red (anti-pattern/failure), neutral=grey,
muted=caption grey.
"""
from dgen import Scene, PALETTE


# ---------------------------------------------------------------------------
# wasm-deviation-stack — the three Part 6 deviations over the core stack
# ---------------------------------------------------------------------------
def wasm_deviation_stack():
    s = Scene(
        "wasm-deviation-stack", 1280, 680,
        title="Three deviations, one core stack",
        subtitle="Istio + Wasm, Spin + SpinKube, and wasi-nn each layer onto the same core: Rust/TinyGo, wasmtime/wasmCloud, WIT, minikube/CRC",
    )

    col_w, gap = 370, 35
    xs = [50, 50 + col_w + gap, 50 + 2 * (col_w + gap)]

    # ---- column headers ----
    headers = [
        ("CH 25 · ISTIO + WASM", "rest"),
        ("CH 26 · SPIN + SPINKUBE", "platform"),
        ("CH 27 · WASI-NN", "svc"),
    ]
    for (text, kind), x in zip(headers, xs):
        s.label(x + col_w / 2, 108, text, size=12, weight="bold",
                color=PALETTE[kind], anchor="middle")

    # ---- column 1: Istio + Wasm (ch25) ----
    s.box(xs[0], 128, col_w, 90, "proxy-wasm filter",
          ["WasmPlugin", "ingress-gateway Envoy"], kind="rest")
    s.box(xs[0], 238, col_w, 90, "Istio",
          ["istioctl (minikube)", "OSSM 3 / Sail (CRC)"], kind="rest")

    # ---- column 2: Spin + SpinKube (ch26) ----
    s.box(xs[1], 128, col_w, 90, "Spin",
          ["spin.toml", "SpinKube"], kind="platform")
    s.box(xs[1], 238, col_w, 90, "containerd shim",
          ["spin-shim", "RuntimeClass"], kind="platform")

    # ---- column 3: wasi-nn (ch27) ----
    s.box(xs[2], 128, col_w, 90, "wasi-nn",
          ["ML inference import"], kind="svc")
    s.box(xs[2], 238, col_w, 90, "OpenVINO",
          ["wasmtime-from-source"], kind="svc")

    # ---- arrows down to the core stack ----
    for x in xs:
        s.arrow(x + col_w / 2, 328, x + col_w / 2, 420, kind="muted", dashed=True)

    # ---- core deviation stack band ----
    s.panel(50, 420, 1180, 180)
    s.label(70, 446, "core deviation stack", size=13, weight="bold", color=PALETTE["neutral"])

    core_w, core_gap = 270, 20
    core_xs = [70 + i * (core_w + core_gap) for i in range(4)]
    core = [
        ("Rust + TinyGo", ["language + build"]),
        ("wasmtime + wasmCloud", ["runtime + orchestration"]),
        ("WIT", ["contract spine"]),
        ("minikube + CRC", ["cluster paths"]),
    ]
    for (title, lines), x in zip(core, core_xs):
        s.box(x, 465, core_w, 100, title, lines, kind="neutral")

    s.write()


SCENES = [
    wasm_deviation_stack,
]


if __name__ == "__main__":
    for fn in SCENES:
        fn()
        print(f"built {fn.__name__}")

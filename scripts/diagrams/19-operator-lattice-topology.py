#!/usr/bin/env python3
"""Figure 19.2, Ch19: the operator/lattice topology on OpenShift Local.

install-operator.sh installs the pinned wasmcloud-platform chart (0.1.2),
which brings up NATS (standalone, cluster.enabled: false), wadm, and the
wasmCloud operator: all under restricted-v2, with one values-crc.yaml edit
(nulling wadm's hard-coded runAsUser/runAsGroup 1000, out of the namespace's
UID range). deploy.sh then applies a WasmCloudHostConfig (host version pinned
1.9.1, pointed at ghcr.io for the component image via the ghcr-pull secret);
the operator reconciles that CR into a host Deployment. Applying wadm.yaml (the
OAM app, with BOTH the component and the httpserver provider traited with a
daemonscaler, not a spreadscaler) is what makes the operator auto-create the
Service this chapter's other figure fronts with a Route.
"""
import sys, os
sys.path.insert(0, "scripts")
import generate_diagram as gd

gd.OUT = "assets/diagrams"
os.makedirs(gd.OUT, exist_ok=True)

W, H = 1180, 600

bands = [
    {"x": 20, "y": 20, "w": 1140, "h": 560, "label": "wasmcloud-platform chart 0.1.2: project wasmcloud, restricted-v2", "fill": "#f1f5f9"},
]

nodes = [
    {"x": 60, "y": 70, "w": 300, "h": 70,
     "lines": ["install-operator.sh", "helm upgrade --install (--dependency-update)",
               "+ endpoints(slices)/restricted RBAC"],
     "style": "box"},

    {"x": 420, "y": 60, "w": 240, "h": 60,
     "lines": ["NATS", "standalone (cluster.enabled: false)", "nats-box disabled"],
     "style": "box"},

    {"x": 420, "y": 140, "w": 240, "h": 60,
     "lines": ["wadm", "runAsUser/runAsGroup nulled", "(values-crc.yaml edit)"],
     "style": "box"},

    {"x": 420, "y": 220, "w": 240, "h": 50,
     "lines": ["wasmCloud operator 0.4.0"],
     "style": "accent"},

    {"x": 60, "y": 310, "w": 300, "h": 90,
     "lines": ["deploy.sh", "wash push app.wasm -> ghcr (private)",
               "oc create secret ghcr-pull"],
     "style": "box"},

    {"x": 420, "y": 310, "w": 300, "h": 90,
     "lines": ["WasmCloudHostConfig", "version: \"1.9.1\" (pinned, not chart default 1.2.1)",
               "registryCredentialsSecret: ghcr-pull"],
     "style": "ink"},

    {"x": 780, "y": 310, "w": 320, "h": 70,
     "lines": ["host Deployment", "(operator-reconciled from the CR)",
               "restricted-v2, UID 1000670000"],
     "style": "user"},

    {"x": 420, "y": 440, "w": 300, "h": 100,
     "lines": ["wadm.yaml (OAM Application)", "cargo-http component: daemonscaler",
               "httpserver provider 0.27.0: daemonscaler", "link: wasi:http/incoming-handler"],
     "style": "accent"},

    {"x": 780, "y": 440, "w": 320, "h": 80,
     "lines": ["operator auto-creates", "Service cargo-http:8000", "(ONLY because of the daemonscaler:",
               "spreadscaler Service-creation is unsupported)"],
     "style": "box"},
]

edges = [
    {"x1": 360, "y1": 95, "x2": 420, "y2": 90, "label": "installs"},
    {"x1": 360, "y1": 110, "x2": 420, "y2": 170},
    {"x1": 360, "y1": 125, "x2": 420, "y2": 245},
    {"x1": 210, "y1": 140, "x2": 210, "y2": 310, "dashed": True, "label": "then"},
    {"x1": 540, "y1": 270, "x2": 540, "y2": 310, "label": "reconciles"},
    {"x1": 360, "y1": 355, "x2": 420, "y2": 355, "label": "pull secret"},
    {"x1": 720, "y1": 345, "x2": 780, "y2": 345, "amber": True, "label": "Deployment"},
    {"x1": 540, "y1": 400, "x2": 540, "y2": 440, "dashed": True, "label": "applied in HostConfig's namespace"},
    {"x1": 720, "y1": 480, "x2": 780, "y2": 480, "amber": True, "label": "daemonscaler -> Service"},
]

notes = [
    {"x": 590, "y": 560, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "deploy.sh then puts an edge-TLS Route in front of the operator-created Service; Figure 19.1 traces that live request."},
    {"x": 590, "y": 578, "size": 12, "color": "#555555", "anchor": "middle",
     "text": "Verified live 2026-10-21 (CRC 2.64.0 / OCP 4.22.14 / wasmcloud host 1.9.1)."},
]

gd.emit("19-operator-lattice-topology", W, H, bands=bands, nodes=nodes, edges=edges, notes=notes)

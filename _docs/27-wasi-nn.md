---
title: "wasi-nn: Portable Inference from Wasm"
order: 27
part: "Deviations"
description: "Run cargo-classification inference from a component with wasi-nn against an OpenVINO reference backend, and decide when it beats a model server."
duration: "15 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what `wasi-nn` is (a WASI proposal for host-accelerated ML inference built on `graph` and `tensor`) and why its package version, `wasi:nn@0.2.0-rc-2024-10-28`, carries a release-candidate tag instead of a stable `0.2.x`.
- Trace the wasmtime 50 call sequence: `graph::load-by-name`, `graph.init-execution-context()` and a single `compute(inputs: list<named-tensor>) -> result<list<named-tensor>, error>`, not the older `set-input`/`compute`/`get-output` triad.
- Explain why image decode, resize and tensor layout run inside the guest, and name the four facts about MobileNetV2's OpenVINO IR that `image_to_nchw_bgr_tensor` depends on: input shape `[1,3,224,224]`, BGR channel order, no manual normalization and a 1001-wide output.
- Run the guest on the `wasmtime` CLI built from source with `--features wasi-nn` against a real OpenVINO install, using `wasmtime run -S nn -S nn-graph=openvino::<dir>`.
- Choose between `wasi-nn` and an external model server reached over HTTP, and name the backends `wasi-nn` is designed to make interchangeable under an unchanged guest.

## Why this matters

`wasi-nn` is a different kind of import from the `patterncatalyst:cargo` contract in `contracts/wit`. It is a **pre-1.0, release-candidate** WASI proposal (`wasi:nn@0.2.0-rc-2024-10-28`) that ships inside the wasmtime repository, so a guest importing it is pinned to the wasmtime build that compiles it. The API also differs from most tutorials. The older WITX-era shape passed a tensor with `set-input(index, tensor)`, ran `compute()` with no arguments and read the result with `get-output(index)`. The WIT shape in wasmtime 50 replaces all three with one call, `compute(inputs: list<named-tensor>) -> result<list<named-tensor>, error>`, binding tensors by name instead of position. `examples/part6-deviations/wasi-nn/` is written against that shape, checked against the WIT that wasmtime v50.0.0 vendors at `crates/wasi-nn/wit/wasi-nn.wit`.

The value is narrow. `wasi-nn` lets a guest ask its host to run inference, with the model, hardware and engine entirely the host's business. The guest here decodes a JPEG, builds a tensor and reads back ranked labels. It never links OpenVINO or a C library and never learns whether the host runs on a CPU, a GPU or something else. The same artifact would run against any backend that implements the interface.

{% include excalidraw.html file="27-wasi-nn-inference-path" alt="A left-to-right pipeline. Leftmost box: fixtures/cargo.jpg, a CC0 container-ship photo. Arrow into a guest-component band labeled cargo-wasi-nn.wasm (in-guest, pure Rust, wasm32-wasip1): decode with the image crate, resize_exact to 224x224, build an NCHW/BGR/f32 tensor via Tensor::new. Arrow crossing a vertical dashed Component Model boundary into wasi:nn imports: tensor, graph, inference, errors at wasi:nn@0.2.0-rc-2024-10-28, labeled a guest import, not a WASI default. That arrow enters a HOST band labeled wasmtime (built --features wasi-nn): graph::load-by-name(\"mobilenet\") resolves a pre-registered graph, graph.init-execution-context() returns a graph-execution-context, then context.compute(vec![(\"input\", tensor)]) hands the tensor across to an OPENVINO BACKEND sub-box holding model.xml/model.bin, which runs the matrix math and returns a 1001-wide output tensor. A return arrow re-crosses the Component Model boundary back into the guest: f32_scores drops index 0 (background), top_k sorts the remaining 1000 scores against labels/imagenet.txt, and the guest prints five label/score lines to stdout. A bottom ink band states: every box left of the dashed boundary is portable Wasm; every box right of it is wasmtime's own OpenVINO-specific backend code the guest never sees." caption="Figure 27.1: The inference path from a JPEG through in-guest preprocessing, across the wasi:nn import boundary into wasmtime's OpenVINO backend, and back to a ranked label list." %}

## The component imports only wasi:nn

`wit/world.wit` declares the whole WIT surface:

{% raw %}
```wit
world classify-cli {
    import wasi:nn/tensor@0.2.0-rc-2024-10-28;
    import wasi:nn/graph@0.2.0-rc-2024-10-28;
    import wasi:nn/inference@0.2.0-rc-2024-10-28;
    import wasi:nn/errors@0.2.0-rc-2024-10-28;
}
```
{% endraw %}

Four imports from one vendored package and nothing from `patterncatalyst:cargo`: the crate classifies a photo, not a booking. `wit/deps/wasi-nn/wasi-nn.wit` is copied verbatim from the wasmtime v50.0.0 source tree rather than written from a spec document. A different wasmtime version could vendor a different WIT shape under the same package version string, and copying from the runtime you will run against is the only way to be sure they match. The world declares no `wasi:cli` imports because the crate is a `[[bin]]` command: `cargo-component`'s command adapter synthesizes the `wasi:cli/run` export and the stdio, preopen and clock imports.

`Cargo.toml` pins the one dependency that does real work in the guest:

{% raw %}
```toml
[dependencies.image]
version = "=0.25.10"
default-features = false
features = ["jpeg", "png"]
```
{% endraw %}

Default features are off because they pull in `rayon`, whose thread pool needs syscalls `wasm32-wasip1` lacks, and codecs (AVIF, WebP, TIFF) the crate never uses. Both remaining codecs are pure Rust. A guest cannot link a C image library the way a native host could.

## load-by-name, init-execution-context, compute

The whole contract fits in one function:

{% raw %}
```rust
    let graph = graph::load_by_name(GRAPH_NAME)
        .map_err(|e| format!("load-by-name('{GRAPH_NAME}') failed: {}", describe(&e)))?;
    let context = graph
        .init_execution_context()
        .map_err(|e| format!("init-execution-context failed: {}", describe(&e)))?;

    let outputs = context
        .compute(vec![(INPUT_TENSOR_NAME.to_string(), tensor)])
        .map_err(|e| format!("compute failed: {}", describe(&e)))?;

    let (_name, output) = outputs
        .first()
        .ok_or_else(|| "compute returned no output tensors".to_string())?;
```
{% endraw %}

Three calls, three WIT resources:

- `graph::load-by-name(name) -> result<graph, error>` resolves a graph the host registered under that name. `"mobilenet"` is the basename of the directory that wasmtime's `-S nn-graph` flag preloads, not a name the crate invents.
- `graph.init-execution-context()` binds the graph to a fresh inference session. The WIT comment flags it as possibly redundant in a future revision, but wasmtime 50 requires it.
- `context.compute(inputs)` runs the inference. One `named-tensor` goes in, pairing `"input"` with the built tensor, and a `list<named-tensor>` comes out.

The `"input"` name must match the port name in the compiled graph (`<layer id="0" name="input" type="Parameter">` in `mobilenet.xml`), because wasmtime's OpenVINO backend binds each named tensor by that exact string. A wrong name fails inside `compute()` at run time as an `error` resource, not at build time and not as a type error. The helper that formats it:

{% raw %}
```rust
fn describe(e: &errors::Error) -> String {
    format!("{:?}: {}", e.code(), e.data())
}
```
{% endraw %}

`errors::Error` is a WIT resource: `code()` returns an `error-code` enum (`invalid-argument`, `invalid-encoding`, `timeout`, `runtime-error`, `unsupported-operation`, `too-large`, `not-found`, `security`, `unknown`) and `data()` a backend-specific string. Every fallible call routes through it, so load, context and compute failures share one code-plus-detail shape.

On the output side, wasmtime's OpenVINO backend names output tensors by index (`("0", tensor)`), not by the IR's output port name (`MobilenetV2/Predictions/Reshape_1`). A single-output classifier returns one entry, so `outputs.first()` takes it positionally.

## Preprocessing in the guest, read from the model's IR

Every decision in `image_to_nchw_bgr_tensor` comes from `mobilenet.xml`, the metadata OpenVINO's Model Optimizer wrote when it converted the TensorFlow checkpoint, not from tuning toward a known answer:

{% raw %}
```rust
fn image_to_nchw_bgr_tensor(image: &image::DynamicImage) -> Tensor {
    let resized = image.resize_exact(SIDE, SIDE, FilterType::Triangle);
    let rgb = resized.to_rgb8();

    let plane_len = (SIDE * SIDE) as usize;
    let mut data = vec![0u8; plane_len * 3 * 4]; // 3 channels, 4 bytes/f32
    for (x, y, pixel) in rgb.enumerate_pixels() {
        let [r, g, b] = pixel.0;
        let offset = (y * SIDE + x) as usize;
        for (channel, value) in [b, g, r].into_iter().enumerate() {
            let start = (channel * plane_len + offset) * 4;
            data[start..start + 4].copy_from_slice(&(value as f32).to_le_bytes());
        }
    }

    Tensor::new(&[1, 3, SIDE, SIDE], TensorType::Fp32, &data)
}
```
{% endraw %}

- **Shape.** `SIDE` is 224, matching `<data shape="1,3,224,224"/>` on the input layer. The layout is NCHW, channel-planar, as `disable_nhwc_to_nchw=False` records. The fixture's published name, `tensor-1x224x224x3-f32.bgr`, describes the original TensorFlow NHWC shape, not what the compiled graph reads. Matching layout to a filename instead of the IR is the usual mistake.
- **Channel order.** The loop writes `[b, g, r]`. `<reverse_input_channels value="True">` is the Model Optimizer flag for an RGB-trained model fed BGR, with the reversal folded into the graph.
- **Values.** Raw `0` to `255` intensities cast to `f32`, with no mean subtraction or rescaling. `mean_values = input[127.5,127.5,127.5]` and `scale_values = input[127.5]` run as `Multiply` and `Add` nodes inside the graph, on the OpenVINO side of the boundary. Normalizing again in the guest would apply it twice.

`f32_scores` checks the output is exactly 1001 values and drops the first:

{% raw %}
```rust
    if floats.len() != 1001 {
        return Err(format!(
            "expected a 1001-way softmax (1000 ImageNet classes + background), got {} values",
            floats.len()
        ));
    }
    Ok(floats[1..].to_vec())
```
{% endraw %}

The graph was exported with the TF-Slim convention of reserving index 0 for "background", confirmed by the output layer's `<dim>1001</dim>`. `labels/imagenet.txt` holds the 1000 class names, 0-indexed, under Apache-2.0 (from Google's `tensorflow/tfjs-models`). Raw index `i >= 1` maps to line `i - 1`. `fixtures/cargo.jpg` is a CC0 container-ship photograph, and ImageNet class 510 is `container ship, containership, container vessel`, the label the model is expected to rank first. Only running the inference confirms it.

## The host: wasmtime built for wasi-nn

There is no host crate and no custom `Engine`/`Store`/`Linker` embedding. The host is the `wasmtime` CLI compiled with a feature most prebuilt releases omit:

```sh
git clone --branch v50.0.0 --depth 1 https://github.com/bytecodealliance/wasmtime
cd wasmtime
cargo build --release --features wasi-nn
install -m 0755 target/release/wasmtime ~/.local/bin/wasmtime
wasmtime --version   # wasmtime-cli 50.0.0
```

The published binaries lack `wasi-nn` because the OpenVINO backend links the `openvino` crate (v0.11.0), a binding over OpenVINO's shared libraries, and shipping it by default would force that dependency on every download. Install OpenVINO 2026.4.1 first and confirm `ldconfig -p | grep openvino` resolves the libraries.

Building the guest needs none of this, because `wasi:nn` imports resolve at `wasmtime run` time on the host, not at `cargo component build` time. The cost of satisfying them falls on whoever runs the component.

`run.sh` fetches the model, builds the component and runs inference with two `-S` flags and one preopened directory:

{% raw %}
```sh
wasmtime run \
  -S nn \
  -S nn-graph="openvino::${MODEL_DIR}" \
  --dir "${FIXTURES_DIR}::/fixtures" \
  "$WASM" \
  /fixtures/cargo.jpg
```
{% endraw %}

- `-S nn` enables the `wasi:nn` imports. Without it `wasmtime run` rejects the component's imports.
- `-S nn-graph=openvino::<dir>` preloads `<dir>` as an OpenVINO graph and registers it under the directory's basename, here `mobilenet` because the directory is `model/mobilenet/`. `fetch-model.sh` renames the download to `model.xml` and `model.bin` because the backend hard-codes those names. A wrong directory or file name fails at run time with a `not-found` error code, not at build time.
- `--dir "${FIXTURES_DIR}::/fixtures"` preopens the fixtures directory at `/fixtures` through the ordinary `wasi:filesystem` mechanism.

The `-S nn-graph` spelling has changed across wasmtime releases. Treat `wasmtime run -S help` on your own build as the source of truth.

### load versus load-by-name

The `graph` interface also exposes `load(builder: list<graph-builder>, encoding: graph-encoding, target: execution-target) -> result<graph, error>`. The guest reads raw model bytes itself, through a preopened directory, and picks the `graph-encoding` (`openvino`, `onnx`, `tensorflow`, `pytorch`, `tensorflowlite`, `ggml`, `autodetect`) and `execution-target` (`cpu`, `gpu`, `tpu`).

| | `load-by-name` | `load` |
|---|---|---|
| Model location | Host-side registry, named by a host convention (here a directory basename and one CLI flag) | Bytes the guest carries or fetches |
| Depends on | One host's naming convention | Only the WIT contract |
| Portable across hosts | Only if they share the naming | Any `wasi-nn` host with that package version |
| Fits | One pinned model on a known host | A guest that must run on hosts with no shared convention |

This component uses `load-by-name` because it matches the wasmtime CLI for a single pinned model.

## Where wasi-nn fits

The familiar alternative is an HTTP call to a model server: a FastAPI wrapper, a dedicated inference server or a managed endpoint. It is a separate process with its own deploy lifecycle. `wasi-nn` answers a different question: how does a component, with no network hop and no extra process, ask the host already running it to do inference on whichever backend that host compiled in? The `graph-encoding` enum is the portability story. Each value is a backend a host could implement behind the same `tensor`, `graph` and `inference` interfaces, so the identical `.wasm` can run on a different engine with no recompilation. This one runs on OpenVINO because that is the backend wasmtime ships and the one this setup can build and verify.

{% include excalidraw.html file="27-wasi-nn-portability-map" alt="A center column labeled wasi:nn API (tensor, graph, inference, errors) with a guest component box feeding into it from the left, labeled unchanged across every backend below. Six backend boxes fan out to the right of the API column, each labeled as a graph-encoding enum value a wasi-nn host could implement: OpenVINO, ONNX Runtime, TensorFlow, TensorFlow Lite, PyTorch, ggml. A dashed line separates this whole wasi:nn column from a second, parallel path below it labeled external model server over HTTP: a client box, an HTTP arrow crossing a network boundary, to a separate serving-process box (for example FastAPI and PyTorch) with its own independent deploy lifecycle, scaling and versioning. A bottom ink band states: wasi:nn trades network-call model serving for in-process, host-mediated inference behind an unchanged guest import; pick wasi:nn when the call has to happen in-process and the backend may vary by host, pick an HTTP model server when the model is large, shared and scaled independently of any one caller." caption="Figure 27.2: wasi:nn's backend-swappable graph-encoding model against calling an external model server over HTTP." %}

> **Decision**
>
> Use `wasi-nn` when inference must run in-process at the component's call boundary, with no network hop and no separate serving process, and the backend is the host's concern. Use an HTTP model server when the model is large enough to need its own scaling and deployment, is shared by callers that should not each need a `wasi-nn` host, or is already a managed endpoint. They combine: a component can use `wasi-nn` for a cheap, latency-sensitive classification and call out for a heavier model. The choice is per inference call.

> **🤖 Explore with your agent**
>
> "In examples/part6-deviations/wasi-nn, the classify-cli world imports the four wasi:nn@0.2.0-rc-2024-10-28 interfaces and src/main.rs calls graph::load-by-name, init-execution-context and compute. Review image_to_nchw_bgr_tensor against model/mobilenet/model.xml: list the shape, channel order, normalization and output width the IR declares, and say which of them would break if the guest also subtracted 127.5 from each pixel."
>
> Check: the reply cites `<data shape="1,3,224,224"/>`, `reverse_input_channels`, `mean_values`/`scale_values` and `<dim>1001</dim>`, and says normalization would be applied twice; `grep -n 'mean_values' model/mobilenet/model.xml` confirms the metadata.

## Build, run, observe

```bash
cd examples/part6-deviations/wasi-nn && ./run.sh
```

`run.sh` fetches the OpenVINO MobileNetV2 fixture, builds the component with `build.sh`, then runs `wasmtime run -S nn -S nn-graph=openvino::model/mobilenet --dir fixtures::/fixtures cargo-wasi-nn.wasm /fixtures/cargo.jpg`. It needs OpenVINO 2026.4.1 and a from-source wasmtime v50.0.0 with `--features wasi-nn`; the header comment in `run.sh` and the `README.md` beside it give the setup. The component decodes the JPEG, builds the NCHW/BGR tensor, runs the three calls and prints the top five ImageNet labels and scores, descending. `build.sh` alone needs neither OpenVINO nor wasmtime-from-source and only checks that the component imports `wasi:*` and exports `wasi:cli/run`.

Experiments:

- Rename the model directory: `load-by-name("mobilenet")` fails at run time with `not-found`.
- Rename `model.xml` or `model.bin`: the backend cannot load the directory.
- Change the tensor name from `"input"`: `compute` returns an error from OpenVINO at run time.
- Run on a stock `wasmtime` binary: `run.sh` stops because `-S nn` is missing from `wasmtime run -S help`.

Kubernetes is out of scope. A cluster run would need the containerd shim and a real OpenVINO install on the node, the same node-level install that `restricted-v2` on OpenShift Local rules out, compounded by OpenVINO's native libraries.

## For deeper coverage

- [WASI `wasi-nn` proposal](https://github.com/WebAssembly/wasi-nn): the `tensor`, `graph`, `inference` and `errors` interfaces and the tracking of the pre-1.0 WIT shape.
- [`wasmtime-wasi-nn`](https://github.com/bytecodealliance/wasmtime/tree/main/crates/wasi-nn): the crate implementing those interfaces against OpenVINO, ONNX Runtime and other backends, including the `load-by-name` registry and index-named output tensors.
- [OpenVINO documentation](https://docs.openvino.ai/): the Model Optimizer metadata (`reverse_input_channels`, `mean_values`, `scale_values`) that the preprocessing reads from `mobilenet.xml`.
- [`second-state/WasmEdge-WASINN-examples`, `openvino-mobilenet-image`](https://github.com/second-state/WasmEdge-WASINN-examples): an independent wasi-nn preprocessing of the same `mobilenet.xml` and `mobilenet.bin`, with the same BGR, NCHW and no-normalization combination.
- Your first component in Rust and in Go: the `cargo-component` command-component shape and the WIT package, world and import mechanics the `classify-cli` world builds on.
- WebAssembly for other backend architectures: the same node-level-install constraint that keeps this inference path off CRC.

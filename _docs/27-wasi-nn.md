---
title: "wasi-nn: Portable Inference from Wasm"
order: 27
part: "Deviations"
description: "Run cargo-classification inference from a component with wasi-nn against an OpenVINO reference backend."
duration: "20 min read"
---

## Learning objectives

By the end of this chapter you can:

- Explain what `wasi-nn` is (a WASI proposal for host-accelerated ML inference built on two abstractions, `graph` and `tensor`) and why its package version, `wasi:[email protected]`, carries an explicit release-candidate tag rather than a stable `0.2.x`.
- Read `examples/part6-deviations/wasi-nn/src/main.rs` and trace the real wasmtime 50 call sequence: `graph::load-by-name`, `graph.init-execution-context()`, and a single `compute(inputs: list<named-tensor>) -> result<list<named-tensor>, error>`, not the older `set-input`/`compute`/`get-output` triad some earlier wasi-nn material still shows.
- Explain why image decode, resize, and tensor layout all run inside the guest component, and name the four facts about MobileNetV2's own OpenVINO IR that `image_to_nchw_bgr_tensor` depends on: input shape `[1,3,224,224]`, channel order BGR, no manual normalization, and a 1001-wide output.
- State why the host here is the `wasmtime` CLI built from source with `--features wasi-nn` against a real OpenVINO install, not a custom native embedding, and give the exact `wasmtime run -S nn -S nn-graph=openvino::<dir>` invocation that loads a named graph.
- Decide, for a given inference workload, whether `wasi-nn`'s model-agnostic graph/tensor API or an external model server reached over HTTP is the better fit, and name the backends `wasi-nn` is designed to make interchangeable underneath an unchanged guest.

## Why this matters

Every component this book has built imports `patterncatalyst:cargo`, a WIT contract this book owns, drawn from `contracts/wit`, version-stable for the life of the project. `wasi-nn` is a different kind of import entirely: a **pre-1.0, release-candidate** WASI proposal (`wasi:[email protected]`, not a stable `0.2.x`) that ships inside the wasmtime repository itself rather than in a separately versioned spec repo. A guest that imports it is importing an interface still finding its final shape, pinned to the exact wasmtime build that compiles it; the API that interface describes today is not the API most wasi-nn tutorials still show. The older WITX-era shape passed a tensor in with `set-input(index, tensor)`, ran `compute()` with no arguments, and pulled a result back out with `get-output(index)`. The WIT shape wasmtime 50 actually ships replaces all three calls with one: `compute(inputs: list<named-tensor>) -> result<list<named-tensor>, error>`, inputs and outputs bound by name instead of position. `examples/part6-deviations/wasi-nn/` is built against that real, current shape, confirmed line-for-line against the WIT wasmtime v50.0.0 vendors at `crates/wasi-nn/wit/wasi-nn.wit`.

The teaching point is not "Wasm can do machine learning." It's narrower and more useful: `wasi-nn` gives a guest component a model-agnostic way to ask a host to run inference, with the model, the hardware, and the inference engine entirely the host's business. The guest in this chapter decodes a JPEG, builds a tensor, and reads back a ranked list of labels; it never touches OpenVINO directly, never links against a C library, and never knows whether the host behind the `wasi:nn` imports is running on a CPU, a GPU, or hardware this component's author has never heard of. That same guest, recompiled for nothing, would run unchanged against an ONNX Runtime backend or ggml backend implementing the identical interface. This chapter builds the one path this book can verify end to end without inventing a backend: a Rust command component, compiled once, run against wasmtime's own OpenVINO backend, with every preprocessing decision traced back to the model's own metadata rather than guessed.

{% include excalidraw.html file="27-wasi-nn-inference-path" alt="A left-to-right pipeline. Leftmost box: fixtures/cargo.jpg, a CC0 container-ship photo. Arrow into a guest-component band labeled cargo-wasi-nn.wasm (in-guest, pure Rust, wasm32-wasip1): decode with the image crate, resize_exact to 224x224, build an NCHW/BGR/f32 tensor via Tensor::new. Arrow crossing a vertical dashed Component Model boundary into wasi:nn imports: tensor, graph, inference, errors at wasi:nn@0.2.0-rc-2024-10-28, labeled a guest import, not a WASI default. That arrow enters a HOST band labeled wasmtime (built --features wasi-nn): graph::load-by-name(\"mobilenet\") resolves a pre-registered graph, graph.init-execution-context() returns a graph-execution-context, then context.compute(vec![(\"input\", tensor)]) hands the tensor across to an OPENVINO BACKEND sub-box holding model.xml/model.bin, which runs the matrix math and returns a 1001-wide output tensor. A return arrow re-crosses the Component Model boundary back into the guest: f32_scores drops index 0 (background), top_k sorts the remaining 1000 scores against labels/imagenet.txt, and the guest prints five label/score lines to stdout. A bottom ink band states: every box left of the dashed boundary is portable Wasm; every box right of it is wasmtime's own OpenVINO-specific backend code the guest never sees." caption="Figure 27.1: the inference path from a JPEG fixture through in-guest preprocessing, across the wasi:nn import boundary, into wasmtime's OpenVINO backend, and back to a ranked label list." %}

## The component: what it imports, and nothing else

`wit/world.wit` declares the entire WIT surface this crate touches:

{% raw %}
```
world classify-cli {
    import wasi:nn/tensor@0.2.0-rc-2024-10-28;
    import wasi:nn/graph@0.2.0-rc-2024-10-28;
    import wasi:nn/inference@0.2.0-rc-2024-10-28;
    import wasi:nn/errors@0.2.0-rc-2024-10-28;
}
```
{% endraw %}

Four imports, all from one vendored package, nothing from `patterncatalyst:cargo` at all: this crate classifies a photo, not a booking. `wit/deps/wasi-nn/wasi-nn.wit` is copied verbatim from wasmtime v50.0.0's own source tree (`crates/wasi-nn/wit/wasi-nn.wit`), not hand-written against a spec document, because `wasi-nn`'s pre-1.0 status means the WIT that matters is whatever the exact wasmtime build on the other end of `wasmtime run` compiles: a different wasmtime version could vendor a different WIT shape for the same package version string, and the only way to be certain the two match is to copy the file from the runtime you intend to run against. `classify-cli` declares no `wasi:cli` imports of its own; because the crate is a `[[bin]]` command, `cargo-component`'s command adapter synthesizes the `wasi:cli/run` export plus the stdio/filesystem-preopen/clocks imports underneath it, the same mechanism every other command component in this book relies on.

`Cargo.toml` pins the one dependency that does real work in the guest, the `image` crate, exactly:

{% raw %}
```toml
[dependencies.image]
version = "=0.25.10"
default-features = false
features = ["jpeg", "png"]
```
{% endraw %}

Default features are off because the default feature set pulls in `rayon`, thread-pool parallelism that needs `clone`/thread-spawn syscalls `wasm32-wasip1` does not have, plus codec support (AVIF, WebP, TIFF) this crate never touches. `jpeg` decodes the fixture; `png` costs nothing extra and keeps a non-JPEG fixture open as a future option. Both codec implementations are pure Rust (no native C codec library in the dependency graph), which is exactly what lets this crate build for `wasm32-wasip1` at all: a guest component cannot link a C image-decoding library the way a native host could.

## The call sequence: load-by-name, init-execution-context, compute

`src/main.rs`'s `run` function is short enough to read as the whole contract in one pass:

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
let scores = f32_scores(&output.data())?;
```
{% endraw %}

Three calls, three WIT resources. `graph::load-by-name(name: string) -> result<graph, error>` resolves a `graph` resource the host has already registered under that name: `GRAPH_NAME` is the literal string `"mobilenet"`, chosen because that is the basename of the directory wasmtime's `-S nn-graph` flag preloads, not a name this crate invents. `graph.init-execution-context() -> result<graph-execution-context, error>` binds that graph to a fresh inference session; the WIT comment on this method flags it as possibly redundant in a future WIT revision, but on wasmtime 50 it is a required step between loading a graph and calling it. `context.compute(inputs: list<named-tensor>) -> result<list<named-tensor>, error>` is the single call that does the actual inference: one `named-tensor` in (a `tuple<string, tensor>` pairing `"input"` with the guest's built tensor), a `list<named-tensor>` out. There is no `set-input` and no `get-output-by-index` anywhere in this flow: the newer WIT folds binding and retrieval into the one `compute` call's argument and return type, which is the shape to write against on any current wasmtime, not the older WITX-era triad.

The `"input"` name passed into `compute` is not a label this crate chose freely. It has to match the port name OpenVINO's compiled graph exposes (`<layer id="0" name="input" type="Parameter">` in the model's own `mobilenet.xml`), because wasmtime's OpenVINO backend binds each named tensor to the model's input port by that exact string. Get the name wrong and OpenVINO rejects the tensor inside `compute()`, not at build time and not with a type error; the failure surfaces as a runtime `error` resource, caught and formatted by this crate's own `describe` helper:

{% raw %}
```rust
fn describe(e: &errors::Error) -> String {
    format!("{:?}: {}", e.code(), e.data())
}
```
{% endraw %}

`errors::Error` is itself a WIT resource with two accessors, `code()` returning an `error-code` enum (`invalid-argument`, `invalid-encoding`, `timeout`, `runtime-error`, `unsupported-operation`, `too-large`, `not-found`, `security`, `unknown`) and `data()` returning a backend-specific string. Every fallible call in this crate's `run` function routes its error through `describe`, so a load failure, an execution-context failure, and a compute failure all surface with the same code-plus-detail shape rather than three different ad hoc messages.

The output side has its own wrinkle, called out directly in `src/main.rs`'s own comment: wasmtime's OpenVINO backend returns output tensors named by index (`("0", tensor)`), not by the IR's own output port name (`MobilenetV2/Predictions/Reshape_1`). That is a documented backend limitation in wasmtime's own source, not a bug in this crate; a single-output classifier has exactly one entry in the returned list, so `outputs.first()` takes it positionally rather than matching a name that will never appear.

## Preprocessing: in the guest, sourced from the model's own IR

Nothing about `image_to_nchw_bgr_tensor` is tuned to make a known answer come out right. Every decision it makes is sourced from `mobilenet.xml`'s own `<layer>` and `<meta_data>` elements, the same metadata OpenVINO's own Model Optimizer wrote when it converted this MobileNetV2 checkpoint from TensorFlow:

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

`SIDE` is `224`, matching `mobilenet.xml`'s own `<data shape="1,3,224,224"/>` on its input layer. The loop writes channels in `[b, g, r]` order, not `[r, g, b]`: the IR's `<cli_parameters><reverse_input_channels value="True">` is a Model Optimizer flag used exactly when an RGB-trained model is fed BGR input and the channel reversal is folded into the graph, so the guest has to hand over BGR to match what the compiled graph expects to see. The `[1, 3, 224, 224]` dimension order is NCHW (channel-planar, not channel-interleaved), which is what `disable_nhwc_to_nchw=False` in the same metadata records about the conversion; the fixture's own published download name, `tensor-1x224x224x3-f32.bgr`, describes the original TensorFlow NHWC shape, not the shape the compiled OpenVINO graph actually reads, which is the detail most likely to trip up a reader who matches tensor layout to a filename instead of to the IR.

The values written are raw `0`–`255` pixel intensities cast to `f32`, with no mean subtraction and no `[-1, 1]` rescaling applied in the guest. That is also sourced from the IR, not an oversight: `mean_values = input[127.5,127.5,127.5]` and `scale_values = input[127.5]` in the same `<meta_data>` block are implemented as `Multiply`/`Add` nodes the graph itself runs immediately after the input layer. The normalization already happens on the OpenVINO side of the `wasi:nn` boundary; doing it again in the guest would normalize the same tensor twice and feed the graph numbers it was never trained to see.

On the output side, `f32_scores` asserts the raw buffer is exactly 1001 `f32` values and drops the first:

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

This fixture's graph was exported with a 1001-way softmax (the TF-Slim/Google Inception-family convention of reserving index 0 for a "background" class and using indices 1 through 1000 for the actual ImageNet-1k classes), confirmed by the output layer's own `<dim>1001</dim>` in `mobilenet.xml`. `labels/imagenet.txt` holds the 1000 class names, 0-indexed, one per line, under an Apache-2.0 license (sourced from Google's `tensorflow/tfjs-models` project); raw index `i` for `i >= 1` maps to line `i - 1` of that file, the skip-then-index pattern `top_k` applies after sorting the trimmed scores descending. `fixtures/cargo.jpg` is a CC0-licensed container-ship photograph; ImageNet-1k class 510 is `container ship, containership, container vessel`, the top-1 label this fixture is expected to classify as, expected by the model's own domain and not guaranteed by anything this chapter can assert without running the inference.

## The host: wasmtime built for wasi-nn, OpenVINO underneath it

There is no host crate in this example tree, unlike the native embeddings earlier chapters build by hand. The host is the `wasmtime` CLI itself, compiled with a Cargo feature most prebuilt releases omit:

{% raw %}
```sh
git clone --branch v50.0.0 --depth 1 https://github.com/bytecodealliance/wasmtime
cd wasmtime
cargo build --release --features wasi-nn
install -m 0755 target/release/wasmtime ~/.local/bin/wasmtime
wasmtime --version   # wasmtime-cli 50.0.0
```
{% endraw %}

The prebuilt binaries wasmtime publishes on GitHub releases do not ship `wasi-nn`, because the feature's OpenVINO backend requires a real OpenVINO runtime already installed on the machine building wasmtime: the `openvino` crate (v0.11.0) the feature links against is a binding over OpenVINO's actual shared libraries, not a pure-Rust reimplementation, and shipping it by default would force every ordinary `wasmtime` download to carry that dependency. OpenVINO 2026.4.1 has to be installed first, from Intel's own distribution channel, with `ldconfig -p | grep openvino` confirming the runtime libraries resolve, before `cargo build --release --features wasi-nn` compiles the backend at all. This is a case where the chapter's teaching point and its own build boundary line up exactly: `build.sh` in this crate's directory needs none of that, because the guest only *imports* `wasi:nn`: those imports resolve at `wasmtime run` time, on the host, not at `cargo component build` time. Reading `wit/deps/wasi-nn/wasi-nn.wit` and compiling against it costs nothing; satisfying it costs an OpenVINO install and a from-source wasmtime build, and that cost falls entirely on whoever runs the component, not on whoever builds it.

`run.sh` documents and runs the exact invocation order once both pieces are in place: fetch the model, build the component, then run inference with two `-S` flags and one preopened directory:

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

`-S nn` turns on the `wasi:nn` imports at all: without it, `wasmtime run` would reject the component's imports outright, the same gate every other `-S` WASI-proposal flag enforces in this book. `-S nn-graph=openvino::<dir>` is the flag that makes `load-by-name` work: it preloads `<dir>` as an OpenVINO graph at startup and registers it in wasmtime's in-memory graph registry under `<dir>`'s own basename (`mobilenet` here, because the directory is `model/mobilenet/`). That registry lookup is also why `fetch-model.sh` renames the downloaded `mobilenet.xml`/`mobilenet.bin` pair to `model.xml`/`model.bin`: wasmtime's OpenVINO backend hard-codes those two file names when it loads a directory, independent of whatever name the upstream fixture publishes them under. Get the directory name or the file names wrong and `load-by-name("mobilenet")` fails at runtime with a `not-found` error code, not at build time. `--dir "${FIXTURES_DIR}::/fixtures"` preopens the fixtures directory read-only at `/fixtures` inside the guest, the same `wasi:filesystem` preopen mechanism every earlier chapter's file-reading component relies on; `wasi-nn` adds a new import package, it does not replace the WASI filesystem story this component also depends on to read its own input image. The exact `-S nn-graph` flag spelling is itself version-sensitive: it has changed across wasmtime releases, and `run.sh`'s own header comment points a reader at `wasmtime run -S help` on their own build as the source of truth rather than this chapter's prose.

`load-by-name` is not the only way to get a graph into a running component; the alternative is a portability tradeoff, not an oversight. The same `graph` interface also exposes `load: func(builder: list<graph-builder>, encoding: graph-encoding, target: execution-target) -> result<graph, error>`: loading a graph from raw bytes the guest itself reads (through a preopened directory, exactly the mechanism this component already uses for its input image), with an explicit `graph-encoding` (`openvino`, `onnx`, `tensorflow`, `pytorch`, `tensorflowlite`, `ggml`, `autodetect`) and `execution-target` (`cpu`, `gpu`, `tpu`) the guest chooses itself. `load-by-name` depends entirely on how a specific host chooses to name and pre-register graphs: here, a directory basename, driven by one `wasmtime` CLI flag, a convention this exact wasmtime build defines and a different `wasi-nn` host is free to define differently. `load` with raw bytes depends on nothing but the WIT contract itself: any `wasi-nn` host implementing this same package version can satisfy it, at the cost of the guest carrying (or fetching) its own copy of the model bytes rather than trusting a host-side name to resolve to the right graph. This chapter uses `load-by-name` because it matches wasmtime's own CLI ergonomics for a single pinned model; a guest meant to run across multiple `wasi-nn` hosts with no shared naming convention would reach for `load` instead.

## Where wasi-nn fits: model-agnostic inference, not a model server

The alternative to `wasi-nn` most teams already know is an HTTP call to an external model-serving process: a FastAPI wrapper around a PyTorch model, a dedicated inference server, a managed cloud endpoint. That alternative works, and nothing in this chapter argues otherwise; it is a separate process, reachable over a network, with its own deploy lifecycle independent of the application calling it. `wasi-nn` answers a narrower, structurally different question: how does a single Wasm component, with no network call and no separate process to deploy, ask the *same host that is already running it* to perform inference, against whichever backend that host happens to have compiled in? The two are not competing for the same slot. An HTTP model server is the right shape when the model is large, shared across many callers, scaled and versioned independently of any one component. `wasi-nn` is the right shape when the inference has to happen in-process, at the component's own call boundary, portable across whatever host eventually runs the component, without the component author needing to know in advance whether that host's backend is OpenVINO, ONNX Runtime, or something else entirely.

That backend portability is the whole point of `wasi-nn`'s `graph-encoding` enum existing at all: `openvino`, `onnx`, `tensorflow`, `tensorflowlite`, `pytorch`, and `ggml` are all named as encodings one `graph::load` call could request, each one a different backend a `wasi-nn` host could implement behind the identical `tensor`/`graph`/`inference` interfaces this chapter's component already imports. This component happens to run against wasmtime's OpenVINO backend because that is the one wasmtime itself ships and this book can build from source and verify; nothing in `src/main.rs` beyond the `-S nn-graph=openvino::<dir>` flag passed at invocation time ties it to OpenVINO specifically, and a different host built with a different backend compiled in could run the identical `.wasm` artifact against an entirely different inference engine, with no recompilation of the guest at all.

{% include excalidraw.html file="27-wasi-nn-portability-map" alt="A center column labeled wasi:nn API (tensor, graph, inference, errors) with a guest component box feeding into it from the left, labeled unchanged across every backend below. Six backend boxes fan out to the right of the API column, each labeled as a graph-encoding enum value a wasi-nn host could implement: OpenVINO (this chapter), ONNX Runtime, TensorFlow, TensorFlow Lite, PyTorch, ggml. A dashed line separates this whole wasi:nn column from a second, parallel path below it labeled external model server over HTTP: a client box, an HTTP arrow crossing a network boundary, to a separate serving-process box (e.g. FastAPI + PyTorch) with its own independent deploy lifecycle, scaling, and versioning. A bottom ink band states: wasi:nn trades network-call model serving for in-process, host-mediated inference behind an unchanged guest import; pick wasi:nn when the call has to happen in-process and the backend may vary by host, pick an HTTP model server when the model is large, shared, and scaled independently of any one caller." caption="Figure 27.2: wasi:nn's backend-swappable graph-encoding model against the alternative of calling an external model server over HTTP." %}

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for <code>wasi-nn</code> when inference has to run in-process, at a component's own call boundary, with no network hop and no separately deployed serving process: a classification, a scoring pass, or any ML step that is naturally part of the same request a component is already handling, where the backend (OpenVINO today, potentially ONNX Runtime or another encoding tomorrow) is the host's concern, not the guest's. The guest in this chapter never changes if the host behind it swaps backends; only the <code>-S nn-graph</code> invocation and the host's own compiled-in support change. Reach for an external model server over HTTP instead when the model is large enough to warrant its own scaling and deployment lifecycle, shared across many callers that should not each need a <code>wasi-nn</code>-capable host, or already deployed as a managed endpoint outside this book's own build. The two are not mutually exclusive inside one system: a component could call <code>wasi-nn</code> for a cheap, latency-sensitive classification and still reach out over HTTP for a heavier model served elsewhere: the choice is per inference call, not a single architectural commitment for the whole system.</p></div>

No Kubernetes deployment is in scope for this chapter. Running `wasi-nn` on a cluster would need the containerd shim and a real OpenVINO install on the node carrying it: the same kind of node-level surgery Chapter 19 and Chapter 26 both already ruled out for CRC's `restricted-v2` posture, here compounded by OpenVINO's own native-library footprint. That combination is a real follow-on, not something this chapter builds: the component, the build, and the WIT/ABI surface are the complete scope here, verified without a cluster of any kind.

This chapter is **verified live 2026-10-22**. `build.sh` compiles the component and asserts its WIT surface (the exact imports, the `wasi:cli/run` export, nothing outside `wasi:*`) with no OpenVINO install required for that pass. The live inference ran against wasmtime v50.0.0 built from source with `--features wasi-nn` and OpenVINO 2026.4.1, over the checksummed MobileNet fixture and the committed `cargo.jpg`: the top class was `container ship, containership, container vessel` at 0.910, ahead of `alp`, `space shuttle`, and `lifeboat`. Evidence is under `examples/part6-deviations/wasi-nn/evidence/2026-10-22/`.

## For deeper coverage

- [WASI `wasi-nn` proposal](https://github.com/WebAssembly/wasi-nn): the `tensor`/`graph`/`inference`/`errors` interfaces this chapter's component imports, and the proposal's own tracking of the pre-1.0 WIT shape vendored into `wit/deps/wasi-nn/`.
- [`wasmtime-wasi-nn`](https://github.com/bytecodealliance/wasmtime/tree/main/crates/wasi-nn): the crate implementing those interfaces against OpenVINO, ONNX Runtime, and other backends, including the `load-by-name` registry behavior and the output-tensor naming limitation this chapter's `src/main.rs` works around.
- [OpenVINO documentation](https://docs.openvino.ai/): the Model Optimizer metadata (`reverse_input_channels`, `mean_values`, `scale_values`) this chapter's preprocessing reads directly out of `mobilenet.xml`.
- [`second-state/WasmEdge-WASINN-examples`, `openvino-mobilenet-image`](https://github.com/second-state/WasmEdge-WASINN-examples): an independent wasi-nn implementation's preprocessing against this identical `mobilenet.xml`/`mobilenet.bin` pair, confirming the BGR/NCHW/no-normalization combination this chapter's component also applies.
- Chapter 14, "wasmtime": the native `Engine`/`Store`/`Linker` embedding pattern this chapter's host does not use: the host here is the `wasmtime` CLI itself, built with `--features wasi-nn`, not a custom Rust binary.
- Chapter 6, "Building Components with cargo-component" and Chapter 7, "The WIT Interface Language": the `cargo-component` command-component shape and the WIT package/world/import mechanics this chapter's `classify-cli` world and vendored `wit/deps/wasi-nn/` package both build on.
- Chapter 26, "WebAssembly for Other Backend Architectures": the same node-level-install constraint that keeps this chapter's inference path off CRC, already established there for `containerd-shim-spin`.

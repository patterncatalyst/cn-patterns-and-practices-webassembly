# cargo-wasi-nn (chapter 27: wasi-nn, portable inference from Wasm)

A `cargo-component` **command** component that classifies a cargo photo
against an OpenVINO MobileNetV2 graph through `wasi:nn`, the WASI proposal
for host-accelerated ML inference. Everything that is Wasm-portable (image
decode, resize, tensor layout, top-k ranking) runs in the guest; only the
model load and the matrix math cross the `wasi:nn` boundary into the host's
OpenVINO runtime.

```
fixtures/cargo.jpg --[image crate, in-guest]--> NCHW/BGR/f32 tensor
                                                        |
                                              wasi:nn/graph, /inference
                                                        v
                                   HOST: wasmtime --features wasi-nn
                                         (OpenVINO backend, load-by-name)
                                                        |
                                                        v
                                        top-5 "label score" lines on stdout
```

There is no host crate in this directory. The host is the `wasmtime` CLI
itself, built from source with the `wasi-nn` Cargo feature against a real
OpenVINO installation; see [Running it live](#running-it-live-the-users-path).
This directory supplies the guest component and the scripts that build it,
fetch its model, and document the run order; it does not install OpenVINO or
build wasmtime.

## The teaching point: a pre-1.0 WASI proposal, version-exact to one host

Every earlier Part 2–5 example in this book imports `patterncatalyst:cargo`,
a WIT contract this book owns and controls. `wasi:nn` is different: it is a
**pre-1.0, release-candidate** WASI proposal
(`wasi:nn@0.2.0-rc-2024-10-28`: note the `-rc-<date>` suffix, not a stable
`0.2.x`), and unlike `wasi:cli`/`wasi:filesystem`/`wasi:clocks` it ships
**inside the wasmtime repository itself**
(`crates/wasi-nn/wit/wasi-nn.wit`), not in a separate `wasi-nn` spec repo
with its own release cadence. The guest's WIT has to match the exact
wasmtime version the user's host is built from, or `wasmtime run` rejects
the component at the canonical-ABI boundary before OpenVINO ever sees a
tensor.

`wit/deps/wasi-nn/wasi-nn.wit` is copied verbatim (`sha256
362c214e8192a7b4754575c6c22813409323690d089742504e661f3e5f5d2fe2`) from
<https://github.com/bytecodealliance/wasmtime/blob/v50.0.0/crates/wasi-nn/wit/wasi-nn.wit>.
No line in it is edited. `wit/world.wit` is the only WIT this crate
authors, and it imports exactly four interfaces from that vendored package:

```
import wasi:nn/tensor@0.2.0-rc-2024-10-28;
import wasi:nn/graph@0.2.0-rc-2024-10-28;
import wasi:nn/inference@0.2.0-rc-2024-10-28;
import wasi:nn/errors@0.2.0-rc-2024-10-28;
```

Like `examples/part2-building-components/consumer-rust`'s `cargo-cli` world,
`classify-cli` declares no `wasi:cli` imports of its own: cargo-component's
command adapter synthesizes `wasi:cli/run` plus the stdio/filesystem-preopen
imports because this crate is a `[[bin]]` with `fn main`, the same mechanism
that makes `consumer-rust` directly `wasmtime run`-able without declaring
WASI imports by hand.

## The WIT API in this wasmtime, not the one from older tutorials

The WIT shipped in wasmtime v50.0.0 uses `graph.init-execution-context()` and
a single `compute(inputs: list<named-tensor>) -> result<list<named-tensor>,
error>` call, **not** the older `set-input(index, tensor)` /
`compute()` / `get-output(index)` triad some older wasi-nn tutorials and the
legacy WITX API still show (`crates/wasi-nn/src/witx.rs` in the same
wasmtime tree keeps that shape alive for backward compatibility, but the WIT
path replaced it). `src/main.rs` follows the newer shape, confirmed against
wasmtime's own guest test program for this identical model and backend:
`crates/test-programs/src/bin/nn_wit_image_classification_openvino_named.rs`.

## Preprocessing, sourced from the model's own IR, not guessed

The MobileNetV2 IR (`mobilenet.xml`) declares everything `image_to_nchw_bgr_tensor`
in `src/main.rs` needs, in its own `<layer>` and `<meta_data>` elements:

| Decision | Value used | Where it comes from |
|---|---|---|
| Input tensor name | `"input"` | `<layer id="0" name="input" type="Parameter">` |
| Shape | `[1, 3, 224, 224]` (NCHW) | same layer: `<data shape="1,3,224,224"/>`; Model Optimizer's own NHWC→NCHW conversion (`disable_nhwc_to_nchw=False` in `<meta_data>`); the fixture's download URL name, `tensor-1x224x224x3-f32.bgr`, describes the *original* TensorFlow NHWC shape, not what the compiled OpenVINO graph reads |
| Channel order | BGR | `<meta_data><cli_parameters><reverse_input_channels value="True">`: a Model Optimizer flag used exactly when an RGB-trained model is fed BGR input and the reversal is folded into the graph |
| Normalization | none (raw 0–255 as `f32`) | `mean_values = input[127.5,127.5,127.5]` and `scale_values = input[127.5]` in the same metadata are implemented as `Multiply`/`Add` nodes immediately after the input layer; the graph normalizes, so the guest must not normalize twice |
| Output width | 1001 (1000 ImageNet classes + background at index 0) | output layer's `<dim>1001</dim>`; the TF-Slim/Google Inception-family convention for this exact model family |

The BGR/NCHW/no-normalization combination is also exactly what
[second-state/WasmEdge-WASINN-examples' `openvino-mobilenet-image`
sample](https://github.com/second-state/WasmEdge-WASINN-examples/blob/master/openvino-mobilenet-image/rust/src/main.rs)
does against this identical `mobilenet.xml`/`mobilenet.bin` pair (mirrored
in `intel/openvino-rs`'s own test fixtures); independent confirmation from
a different wasi-nn implementation targeting the same graph.

`compute()`'s output comes back as index-named tensors (`("0", tensor)`),
not by the IR's own output port name
(`MobilenetV2/Predictions/Reshape_1`). That is how the OpenVINO backend in
wasmtime v50.0.0 behaves, documented in
`crates/wasi-nn/src/backend/openvino.rs`: *"Currently openvino
backend returns output index only, not output tensor name"*. `src/main.rs`
takes the first (only) output tensor positionally rather than matching a
name that cannot appear.

## Labels and the background-class offset

`labels/imagenet.txt` holds the 1000 ImageNet-1k class names, 0-indexed,
one per line, parsed from Google's Apache-2.0-licensed
[`tensorflow/tfjs-models` `imagenet_classes.ts`](https://github.com/tensorflow/tfjs-models/blob/master/mobilenet/src/imagenet_classes.ts)
(`Copyright 2019 Google LLC`, `Apache License, Version 2.0`). The raw
`compute()` output is 1001-wide (see the table above); `f32_scores` in
`src/main.rs` drops index 0 (the background class) and maps raw index `i`
(`i >= 1`) to `labels/imagenet.txt` line `i - 1`, the same
skip-then-index pattern the WasmEdge reference sample above uses against its
own bundled label table.

## Fixture image

`fixtures/cargo.jpg`: *"MSC ASTRID Container Ship."* by Bernard Spragg,
sourced via [Openverse](https://openverse.org) from
<https://www.flickr.com/photos/88123769@N02/34201586040>, licensed
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) (public domain
dedication, no attribution required, credited here anyway). 1024x585,
~195 KB. ImageNet-1k class 510 is `container ship, containership, container
vessel`; this is the top-1 label the fixture is expected to classify as,
not a cropped or staged match for the model.

## Model

`fetch-model.sh` downloads `mobilenet.xml` + `mobilenet.bin` from
<https://download.01.org/openvinotoolkit/fixtures/mobilenet/>, the same
fixture wasmtime's own OpenVINO wasi-nn tests use
(`crates/wasi-nn/tests/check/openvino.rs`,
`are_artifacts_available`), into `model/mobilenet/model.xml` and
`model/mobilenet/model.bin`. Model artifacts are gitignored; the script
verifies both files against pinned sha256 hashes on every run (cached or
fresh) and is idempotent:

| File | sha256 |
|---|---|
| `mobilenet.xml` | `b28eafd9f8cdf3e265dae4be2eacc4849c0d4693fde584ceca3541bcb4d79e6f` |
| `mobilenet.bin` | `8371f708ef167a783ed01fc6635f4f05e76f720db95e954aff3cba3ed4f29924` |

MobileNetV2 (Sandler et al., 2018) is Apache-2.0 licensed in its original
TensorFlow form; this converted OpenVINO IR is the toolkit's own published
fixture for exercising the OpenVINO backend, not a redistribution of a
separately licensed third-party checkpoint.

## Prerequisites

- Rust 1.99.1 with the `wasm32-wasip1` target (`rustup target add
  wasm32-wasip1`).
- `cargo-component` 0.21.1, `wasm-tools` 1.262.0.
- For `./build.sh`: nothing else. The guest only *imports* `wasi:nn`; those
  imports resolve at `wasmtime run` time, not at `cargo component build`
  time, so this crate builds on stable Rust with no OpenVINO installed.
- For `./run.sh` (the live path, see below): OpenVINO **2026.4.1** and a
  `wasmtime` v50.0.0 built from source with `--features wasi-nn` against it.
  Neither is installed by this directory.

## Build (no OpenVINO required)

```sh
./build.sh
```

Runs `cargo component build --release`, validates the component with
`wasm-tools validate`, and asserts its WIT surface: imports
`wasi:nn/graph@0.2.0-rc-2024-10-28` (plus `tensor`/`inference`/`errors` from
the same package and the `wasi:cli`/`wasi:filesystem`/`wasi:clocks`/`wasi:io`
imports cargo-component's command adapter adds), exports
`wasi:cli/run@0.2.3`, and imports nothing outside the `wasi:*` namespace:
no `patterncatalyst:*`, confirming this crate classifies a photo rather than
touching the booking/handling domain. Prints the component's sha256.

`target/` is gitignored; `Cargo.lock` is committed for reproducible builds;
`src/bindings.rs` is committed too, matching this book's convention for
cargo-component-generated bindings (see
`examples/part2-building-components/consumer-rust/src/bindings.rs`);
regenerate it by re-running `./build.sh` after any `wit/` change, never hand-edit it.

## Running it live (the user's path)

This is the part `build.sh` cannot do. wasi-nn needs a host that implements
it (`wasmtime --features wasi-nn`), and that feature's OpenVINO backend
needs a real OpenVINO installation on the machine building wasmtime, because
the `openvino` crate (v0.11.0) it links against is a binding over the actual
OpenVINO shared libraries, not a pure-Rust reimplementation.

1. **Install OpenVINO 2026.4.1** per Intel's distribution instructions for
   your platform (APT/YUM repo or the generic archive), then confirm
   `ldconfig -p | grep openvino` resolves the runtime libraries.

2. **Build wasmtime v50.0.0 from source** with the `wasi-nn` feature: the
   GitHub release binaries do not ship it, because it would otherwise force
   every `wasmtime` download to carry an OpenVINO dependency:

   ```sh
   git clone --branch v50.0.0 --depth 1 https://github.com/bytecodealliance/wasmtime
   cd wasmtime
   cargo build --release --features wasi-nn
   install -m 0755 target/release/wasmtime ~/.local/bin/wasmtime
   wasmtime --version   # wasmtime-cli 50.0.0
   ```

3. **Run it:**

   ```sh
   ./run.sh
   ```

   `run.sh` checks that `wasmtime` is on `PATH` and was built with
   `wasi-nn` (`wasmtime run -S help` must list `nn`), then runs
   `./fetch-model.sh`, `./build.sh`, and finally:

   ```sh
   wasmtime run \
     -S nn \
     -S nn-graph="openvino::$PWD/model/mobilenet" \
     --dir "$PWD/fixtures::/fixtures" \
     target/wasm32-wasip1/release/cargo-wasi-nn.wasm \
     /fixtures/cargo.jpg
   ```

   The `-S nn-graph=<format>::<dir>` spelling (double colon, not a single
   one) is confirmed against wasmtime v50.0.0's own flag parser
   (`crates/cli-flags/src/opt.rs`, `impl WasmtimeOptionValue for
   WasiNnGraph`); it has changed across wasmtime releases before. Before
   trusting this spelling against a different wasmtime build, check
   `wasmtime run -S help` on that build directly.

   Expected output (five lines, `label score`, descending):

   ```
   container ship, containership, container vessel 0.NNNNNN
   ...four more labels...
   ```

   The exact scores depend on the OpenVINO build and hardware; the top-1
   label should not, given the fixture image.

## Verify (no cluster, no OpenVINO)

```sh
./build.sh
wasm-tools validate target/wasm32-wasip1/release/cargo-wasi-nn.wasm
wasm-tools component wit target/wasm32-wasip1/release/cargo-wasi-nn.wasm | grep -E '^\s*(import|export)'
# expect: import wasi:nn/{tensor,graph,inference,errors}@0.2.0-rc-2024-10-28;
#         import wasi:{cli,io,clocks,filesystem}/*@0.2.3; (command-adapter imports)
#         export wasi:cli/run@0.2.3;
```

This confirms the component is well-formed and its ABI surface is exactly
what chapter 27 claims. It does not, and cannot, confirm the classification is
correct; that needs the live OpenVINO run above, which is this book's
reader's step, not this script's.

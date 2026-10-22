// wasi-nn image classification (chapter 27) — a cargo-component COMMAND
// component. It decodes a cargo photo, builds the MobileNetV2 input tensor
// IN THE GUEST (no host-side preprocessing), classifies it against a
// `load-by-name`d OpenVINO graph, and prints the top-5 ImageNet labels.
//
// The preprocessing, tensor layout, and label offset below are each sourced
// from the model's own IR (shape, reverse_input_channels, mean/scale, output
// width) and from wasmtime's WIT-based wasi-nn test program for this backend;
// see the citations inline and in README.md.
#[allow(warnings)]
mod bindings;

use bindings::wasi::nn::errors;
use bindings::wasi::nn::graph;
use bindings::wasi::nn::tensor::{Tensor, TensorType};
use image::imageops::FilterType;
use std::env;
use std::fs;

/// Spatial size MobileNetV2's `input` layer expects (see mobilenet.xml:
/// `<layer id="0" name="input" ...><data shape="1,3,224,224"/>`).
const SIDE: u32 = 224;

/// The graph registered under this name by `wasmtime run -S nn-graph=
/// openvino::<dir>` — the name comes from the preloaded directory's own
/// basename (`model/mobilenet/`), not from anything this program chooses.
/// See crates/wasi-nn/src/registry/in_memory.rs in wasmtime v50.0.0:
/// `InMemoryRegistry::load` names the graph after `path.file_name()`.
const GRAPH_NAME: &str = "mobilenet";

/// The input port name baked into the IR (`mobilenet.xml`, layer id="0",
/// name="input"). The OpenVINO backend's `compute()` binds each named tensor
/// to the model's input port with that exact name
/// (`InferRequest::set_tensor(&input.name, ...)` in
/// crates/wasi-nn/src/backend/openvino.rs) — get this wrong and OpenVINO
/// rejects the tensor at `compute()`, not silently misclassifies.
const INPUT_TENSOR_NAME: &str = "input";

/// The 1000 ImageNet-1k class names, 0-indexed, one per line — see
/// labels/imagenet.txt and its header for provenance (Apache-2.0, Google
/// LLC, tensorflow/tfjs-models). Embedded at compile time so the component
/// needs only the image directory preopened at run time, not a second one
/// for labels.
const LABELS: &str = include_str!("../labels/imagenet.txt");

fn run() -> Result<Vec<(String, f32)>, String> {
    let args: Vec<String> = env::args().collect();
    let image_path = args
        .get(1)
        .ok_or_else(|| "usage: cargo-wasi-nn <image-path>".to_string())?;

    let bytes = fs::read(image_path)
        .map_err(|e| format!("failed to read '{image_path}': {e}"))?;
    let decoded = image::load_from_memory(&bytes)
        .map_err(|e| format!("failed to decode '{image_path}': {e}"))?;

    let tensor = image_to_nchw_bgr_tensor(&decoded);

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
    // The OpenVINO backend's WIT `compute()` path returns output tensors
    // named by index ("0", "1", ...), not by the IR's own output port name —
    // see the comment at crates/wasi-nn/src/backend/openvino.rs:
    // "Currently openvino backend returns output index only, not output
    // tensor name". A single-output classifier has exactly one entry, so we
    // take it positionally rather than matching a name that will not appear.
    let scores = f32_scores(&output.data())?;

    Ok(top_k(&scores, 5))
}

/// Decode an RGB image into the NCHW/BGR/f32 tensor MobileNetV2's `input`
/// layer expects: resize to 224x224, reorder channels to BGR, and leave the
/// 0-255 pixel range untouched.
///
/// No mean subtraction or [-1,1] scaling happens here on purpose: the IR
/// bakes that normalization into the graph itself as `Multiply`/`Add` nodes
/// immediately after the input layer (`mean_values = input[127.5,127.5,
/// 127.5]`, `scale_values = input[127.5]` in mobilenet.xml's
/// `<meta_data><cli_parameters>`). Applying it again here would normalize
/// twice.
///
/// BGR, not RGB, because the same metadata records
/// `reverse_input_channels = True` — a Model Optimizer flag used exactly
/// when the original model (trained on RGB, as this TensorFlow MobileNetV2
/// export was) will be fed BGR-ordered pixels at inference time, with the
/// reversal folded into the graph. This matches the fixture's own published
/// name at the source URL, `tensor-1x224x224x3-f32.bgr`, and the reference
/// Rust preprocessing in second-state/WasmEdge-WASINN-examples'
/// openvino-mobilenet-image sample, which targets this identical
/// mobilenet.xml/mobilenet.bin pair.
///
/// NCHW (channel-planar), not NHWC (channel-interleaved): the IR's `input`
/// layer declares `shape="1,3,224,224"` after Model Optimizer's NHWC-to-NCHW
/// conversion (`disable_nhwc_to_nchw = False` in the same metadata) — the
/// *fixture filename* ("...1x224x224x3...") describes the original
/// TensorFlow shape, not the shape OpenVINO's compiled graph actually reads.
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

/// Convert a little-endian f32 byte buffer, skipping ImageNet's background
/// class at raw index 0.
///
/// This fixture's graph was exported with a 1001-way softmax (TF-Slim/Google
/// Inception-family convention: index 0 = "background", indices 1..=1000 =
/// the 1000 ImageNet-1k classes) — confirmed by `mobilenet.xml`'s output
/// layer carrying `<dim>1001</dim>`, and by the reference
/// openvino-mobilenet-image sample's `sort_results`, which explicitly
/// `.skip(1)`s the same raw buffer before indexing its own 1000-entry label
/// table. `labels/imagenet.txt` is 0-indexed (1000 lines), so raw index `i`
/// (for `i >= 1`) maps to `LABELS` line `i - 1`.
fn f32_scores(raw: &[u8]) -> Result<Vec<f32>, String> {
    if raw.len() % 4 != 0 {
        return Err(format!(
            "output tensor byte length {} is not a multiple of 4",
            raw.len()
        ));
    }
    let floats: Vec<f32> = raw
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    if floats.len() != 1001 {
        return Err(format!(
            "expected a 1001-way softmax (1000 ImageNet classes + background), got {} values",
            floats.len()
        ));
    }
    Ok(floats[1..].to_vec())
}

fn top_k(scores: &[f32], k: usize) -> Vec<(String, f32)> {
    let labels: Vec<&str> = LABELS.lines().collect();
    let mut ranked: Vec<(usize, f32)> = scores.iter().copied().enumerate().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    ranked
        .into_iter()
        .take(k)
        .map(|(idx, score)| {
            let label = labels.get(idx).copied().unwrap_or("<unknown>");
            (label.to_string(), score)
        })
        .collect()
}

fn describe(e: &errors::Error) -> String {
    format!("{:?}: {}", e.code(), e.data())
}

fn main() {
    match run() {
        Ok(results) => {
            for (label, score) in results {
                println!("{label} {score:.6}");
            }
        }
        Err(e) => {
            eprintln!("cargo-wasi-nn: {e}");
            std::process::exit(1);
        }
    }
}

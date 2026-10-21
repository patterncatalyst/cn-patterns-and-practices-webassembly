// Generate the same prost message structs the component uses, from the shared
// proto/cargo.proto, so the host can encode the request and decode the response.
use std::path::PathBuf;

fn main() {
    let proto = "../../proto/cargo.proto";
    println!("cargo:rerun-if-changed={proto}");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    prost_build::Config::new()
        .out_dir(&out)
        .compile_protos(&[proto], &["../../proto"])
        .expect("compile cargo.proto with prost-build (is protoc on PATH?)");
}

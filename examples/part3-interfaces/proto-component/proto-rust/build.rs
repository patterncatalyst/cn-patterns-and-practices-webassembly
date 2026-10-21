// Generate prost message structs from the shared proto/cargo.proto at build
// time (protoc required on PATH). Messages only — prost-build ignores the
// service definition, which the tonic bridge handles separately.
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

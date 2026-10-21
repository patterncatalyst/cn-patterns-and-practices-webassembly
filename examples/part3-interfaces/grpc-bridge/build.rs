// Generate tonic gRPC server + client stubs and prost messages from the shared
// proto/cargo.proto (protoc required on PATH). tonic 0.14 moved the prost
// integration into tonic-prost-build.
fn main() {
    let proto = "../proto/cargo.proto";
    println!("cargo:rerun-if-changed={proto}");
    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&[proto], &["../proto"])
        .expect("compile cargo.proto with tonic-prost-build (is protoc on PATH?)");
}

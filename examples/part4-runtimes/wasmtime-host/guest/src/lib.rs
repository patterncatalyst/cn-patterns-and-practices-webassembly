// Guest component for the ch14 embedding example.
//
// It IMPORTS the host capability (`host-caps`, implemented in native Rust by
// ../host and wired through a wasmtime Linker closure) and EXPORTS `run`. One
// binary drives every Store/Engine control the host asserts, selected by `mode`:
//
//   "clean" -> calls BOTH host imports (proving the host-provided import works),
//              does a little bounded work, returns a summary string.
//   "spin"  -> a tight compute loop with a data dependency so the optimizer
//              cannot delete it. Under a fuel-metered Store this exhausts fuel
//              (OutOfFuel trap); under an epoch-interrupted Store a ticker thread
//              trips the deadline (Interrupt trap).
//   "grow"  -> repeatedly grows linear memory. Under a ResourceLimiter that caps
//              memory, the growth is denied; the Rust allocator turns the failed
//              `memory.grow` into an abort (a trap), and the host also observes
//              the limiter's deny flag.
#[allow(warnings)]
mod bindings;

use bindings::patterncatalyst::host_demo::host_caps;
use bindings::Guest;

struct Component;

impl Guest for Component {
    fn run(mode: String, iterations: u64) -> String {
        match mode.as_str() {
            "clean" => {
                // Cross the boundary into the host-provided capability. The guest
                // has no other way to obtain either value.
                let quote = host_caps::host_quote("CARGO-USNYC-DEHAM");
                let now = host_caps::host_now();
                // A little bounded work so the clean run is non-trivial but cheap.
                let mut acc: u64 = 0;
                let mut i: u64 = 0;
                while i < iterations {
                    acc = acc.wrapping_add(i).wrapping_mul(2654435761);
                    i += 1;
                }
                format!("clean mode=ok quote=[{quote}] now={now} acc={acc}")
            }
            "spin" => {
                // Tight loop with a carried dependency. The host caps iterations
                // far above any fuel budget / epoch tick, so this never returns
                // under a metered Store — it traps.
                let mut acc: u64 = 1;
                let mut i: u64 = 0;
                while i < iterations {
                    acc = acc.wrapping_mul(i | 1).wrapping_add(0x9E3779B97F4A7C15);
                    i += 1;
                }
                format!("spin done acc={acc}")
            }
            "grow" => {
                // Force linear-memory growth in ~1 MiB steps. Keep each chunk
                // alive (push into a Vec) so the allocator must actually grow
                // memory rather than reuse freed pages.
                let chunk = 1usize << 20; // 1 MiB
                let mut held: Vec<Vec<u8>> = Vec::new();
                let mut n: u64 = 0;
                while n < iterations {
                    let mut block = vec![0u8; chunk];
                    // Touch a byte so the allocation is not optimized away.
                    block[chunk - 1] = (n & 0xff) as u8;
                    held.push(block);
                    n += 1;
                }
                let total: usize = held.iter().map(|b| b.len()).sum();
                format!("grow done blocks={} bytes={}", held.len(), total)
            }
            other => format!("unknown mode {other}"),
        }
    }
}

bindings::export!(Component with_types_in bindings);

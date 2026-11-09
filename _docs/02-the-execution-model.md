---
title: "The Execution Model"
order: 2
part: "Foundations"
description: "How Wasm modules and linear memory work, the sandbox they run inside, and the capability-based security model that replaces ambient authority."
duration: "20 min read"
---

## Learning objectives

By the end of this chapter you can:

- Describe what a Wasm module's sections hold at compile time (types, functions, memory, tables, imports, exports) and what instantiation turns that artifact into at run time.
- Explain why linear memory is a single contiguous byte array indexed from zero, why every access is bounds-checked, and what happens on an out-of-bounds access.
- Name the value types the Wasm Core spec defines (`i32`, `i64`, `f32`, `f64`, `v128`, `funcref`, `externref`) and why only numbers, never pointers or structured data, cross a module boundary at this layer.
- Contrast the Wasm sandbox's no-ambient-authority model with a container's default access to the host's syscall interface, filesystem, and network stack.
- Explain capability-based security at the core-spec level: a guest can reach nothing outside its own linear memory except functions the host explicitly linked in at instantiation.

## Why this matters

Running server-side workloads as Wasm components only beats containers on cost, density and startup if the execution model isolates a guest the way that claim assumes. Two primitives carry the whole argument. Linear memory is the only address space a guest can see. The import table is the only channel from a guest to anything else. A module exchanges only numbers across its boundary and touches nothing outside except what the host passes in by name. WASI's scoped file and network access, the typed interfaces of the Component Model and Istio's Wasm filters all follow from those two.

The scope is the WebAssembly Core specification, the W3C Recommendation that defines modules, instances, linear memory and the instruction set. WIT contracts and WASI both build on the numbers-only boundary described here.

{% include excalidraw.html file="02-module-structure" alt="Diagram contrasting a Wasm module as a compile-time artifact made of sections (types, imports, functions, tables, memories, globals, exports, code, data) against a module instance as the runtime object created at instantiation, holding its own linear memory, table, globals, and resolved imports. An arrow labeled instantiate() points from the module to the instance." caption="Figure 2.1: A module is a static binary; instantiation produces a running instance with its own state." %}

## Modules and instances

A Wasm module is a binary artifact, typically produced by compiling Rust, Go or C to the `wasm32` target. It is organized into sections:

| Section | Holds |
|---------|-------|
| type | Function signatures |
| import | What the module expects the host to provide |
| function, code | The module's own function signatures and bodies |
| memory | How much linear memory the module needs |
| table | Targets for indirect calls |
| global | Module-level values, mutable or not |
| export | What the module offers the host |
| data, element | Initial contents for memory and tables |

Custom sections carry debug information or tool metadata without affecting execution.

The binary is inert until a runtime instantiates it. The engine allocates the instance's own linear memory (sized per the memory section, in 64 KiB pages), allocates its table, initializes its globals, resolves every import against functions, memories, tables or globals the host supplies, and applies the data and element segments before the module's code runs. Two instances of one module are independent, each with its own memory, table and globals. Sharing a memory between instances is possible, and is how threads work in the shared-memory proposal, but never happens by default.

A module is a file that a registry or object store can hold and version. An instance is runtime state: an allocation of memory, a set of resolved imports, a stack. Validating and compiling the bytecode to native code happens once per module, and instantiation is mostly memory allocation and import resolution. That is why an already-compiled module instantiates in microseconds, and why Wasm cold starts look nothing like container cold starts.

Validation comes first. The engine type-checks every module against the Core spec before it runs one instruction: every operand stack transition, branch target and call signature. A module that fails validation never gets an instance. What the type system can't rule out statically, such as an out-of-bounds access, an integer division by zero or a stack overflow, becomes a trap: a controlled failure the host handles, not memory corruption the guest could exploit.

## Linear memory

A module's linear memory is one contiguous, mutable byte array indexed from zero, which the module's instructions address directly. "Linear" contrasts with a heap of separately allocated objects: each memory instance is a single flat address space, and every load and store names an offset in it. Memory grows in 64 KiB pages, at instantiation or through `memory.grow`, up to the maximum the module declares or the host enforces.

Linear memory is not the host process's address space, and no instruction reads or writes outside the instance's own memory. A pointer inside a module is an integer offset into that memory. It means nothing to the host and nothing to another instance, even one built from the same module. Every load and store is bounds-checked against the current memory size before it executes, and an access past the end traps and halts the instance. The host typically tears it down and reports the failure to whatever scheduled it. A native buffer overflow keeps running into whatever bytes come next. A linear-memory overrun has nowhere to run, because the check is part of every memory instruction and not a compiler flag.

{% include excalidraw.html file="02-linear-memory" alt="Diagram of a Wasm linear memory as a contiguous byte array starting at offset 0 and growing in 64 KiB pages. One arrow shows an in-bounds load instruction succeeding at an offset inside the current memory size. A second arrow shows an access past the end of the final page hitting the bounds check and trapping instead of reading further memory." caption="Figure 2.2: Every load and store is bounds-checked against the instance's own memory size. Past the edge is a trap, not adjacent memory." %}

This is also why data crossing the boundary looks the way it does. A host and a guest can't pass a string or a struct, because the only shared types are numeric. The guest allocates a region of its own memory, writes bytes into it and returns the offset and length as two integers. The host reads that region through its embedding API's memory accessor. The guest never hands over a pointer the host could dereference, only coordinates into its own memory. A guest in Rust, compiled for `wasm32-unknown-unknown`:

```rust
#[no_mangle]
pub extern "C" fn alloc(len: usize) -> *mut u8 {
    let mut buf = Vec::with_capacity(len);
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf); // guest keeps the allocation alive; host writes into it
    ptr
}

#[no_mangle]
pub extern "C" fn sum(ptr: *const i32, len: usize) -> i32 {
    let values = unsafe { std::slice::from_raw_parts(ptr, len) };
    values.iter().sum()
}
```

The same shape in Go, compiled with TinyGo's `wasm` target:

```go
package main

import "unsafe"

//export alloc
func alloc(size uint32) *byte {
    buf := make([]byte, size)
    return &buf[0]
}

//export sum
func sum(ptr *int32, length uint32) int32 {
    values := unsafe.Slice(ptr, length)
    var total int32
    for _, v := range values {
        total += v
    }
    return total
}

func main() {}
```

To the host, `ptr` is an `i32` offset, a number and not an address. The Component Model and WIT exist largely so that no project hand-rolls this allocate, write and pass-offset routine for every string and record.

## The stack and value types

The instruction set is stack-based: most instructions pop operands from an implicit operand stack and push a result. That stack is invisible to the guest's code and to the host. No instruction reads it as data, which closes off stack-smashing techniques that target native call stacks. Locals and parameters live in a separate per-frame space, and state that persists across calls lives in globals or linear memory.

The Core spec fixes a small set of value types:

| Type | Meaning |
|------|---------|
| `i32`, `i64` | Integers with no built-in signedness. `i32.add` is sign-agnostic, while `i32.lt_s` and `i32.lt_u` state signedness in the instruction |
| `f32`, `f64` | IEEE 754 floating point |
| `v128` | 128-bit vector for SIMD |
| `funcref` | Opaque reference to a function, used for indirect calls through a table |
| `externref` | Opaque reference to a host-defined value that a module can hold and pass back but never inspect or forge |

The reference types came from the reference-types proposal and are part of the 2.0 Recommendation. A module can't manufacture a reference, only pass along one it was handed, which keeps the type system sound in the presence of host objects.

Strings, structs, arrays and native pointers are not on the list. Every import and export signature is built from these types alone, which is why every language's Wasm toolchain converges on the offset-and-length idiom above.

## The sandbox

The engine enforces the sandbox at two layers. Statically, validation rejects unsound modules. Dynamically, nothing a guest does reaches outside its own memory, table and globals except through a function the host resolved into its import section. The Core spec has no instruction to open a file, connect a socket, read an environment variable or issue a syscall. A module instantiated with no imports can compute, branch, loop and use its own memory, and nothing else. It sees no filesystem, network, clock or other instance.

A container is an ordinary OS process. It inherits the kernel's full syscall interface, and namespaces, cgroups and seccomp filters are restrictions applied afterward to something that began with ambient access. A missing seccomp rule, an undropped namespace or an unstripped capability widens what the process can reach, because hardening is all subtraction from "can do anything the kernel allows."

A Wasm instance starts from the opposite position: no access to anything beyond its own memory until the host adds some, one import at a time. There is no syscall surface to audit for gaps, because none exists inside the sandbox. Every capability is something a person or a deploy pipeline wrote down when wiring the instance's imports. That is how an engine such as Wasmtime can run untrusted guest code with no seccomp or firewall layered on top.

{% include excalidraw.html file="02-sandbox-boundary" alt="Side-by-side diagram. Left: a container process inside a host OS, with a dashed line showing ambient, default access to the kernel syscall interface, filesystem, and network, narrowed afterward by namespaces, cgroups, and seccomp. Right: a Wasm guest instance inside an engine, with no line at all to host filesystem, network, or syscalls by default, and a single solid arrow labeled imports showing the only path out, through specific host functions the engine resolved at instantiation." caption="Figure 2.3: A container starts with ambient OS access that isolation narrows. A Wasm guest starts with none and gains only what its imports name." %}

## Capability-based security

The import section is the entire capability surface. At instantiation the embedding application (using the API of Wasmtime, wasmCloud or another host) decides which functions, memories, tables and globals satisfy the module's imports. Anything not linked in doesn't exist for the guest. There is no ambient namespace of host functions to enumerate or probe.

This is capability security in the access-control sense: authority flows only through an unforgeable reference that was explicitly handed over, never through ambient identity or a global namespace. A guest with no file import can't open a file however its code is written. Two instances of one module can hold different capability sets, say logging only for one and logging plus outbound HTTP for the other, and each has exactly the authority it was handed, not what its code happens to contain.

A Rust host wiring one capability, a logging function, with Wasmtime's `Linker`:

```rust
let mut linker = Linker::new(&engine);
linker.func_wrap(
    "env",
    "host_log",
    |mut caller: Caller<'_, ()>, ptr: i32, len: i32| {
        let memory = caller.get_export("memory").unwrap().into_memory().unwrap();
        let bytes = memory.data(&caller)[ptr as usize..(ptr + len) as usize].to_vec();
        println!("{}", String::from_utf8_lossy(&bytes));
    },
)?;
let instance = linker.instantiate(&mut store, &module)?;
```

The same wiring with wasmtime-go:

```go
linker := wasmtime.NewLinker(engine)
err := linker.FuncWrap("env", "host_log", func(caller *wasmtime.Caller, ptr, length int32) {
    mem := caller.GetExport("memory").Memory()
    data := mem.UnsafeData(store)[ptr : ptr+length]
    fmt.Println(string(data))
})
instance, err := linker.Instantiate(store, module)
```

`host_log` is the only door this instance has. No policy engine watches for violations. The function table the guest's calls resolve against holds nothing else. WASI standardizes this mechanism as a set of imports, each scoped, so a guest receives a single preopened directory handle and not open filesystem access.

{% include excalidraw.html file="02-capability-passing" alt="Diagram showing a host process with several functions available internally: host_log, host_fetch, write_file, open_socket. An instantiation step links only host_log into a guest instance's import table, shown as a single arrow crossing the boundary, while the other three functions remain inside the host with no connecting line to the guest at all." caption="Figure 2.4: The host chooses, function by function, what crosses into a guest's import table. Everything else stays unreachable." %}

## A minimal module

A module in the spec's text format, `.wat`, that declares its own memory and exports one function:

```wat
(module
  (memory (export "memory") 1)        ;; 1 page = 64 KiB, exported so a host can read/write it
  (func (export "add_one") (param $x i32) (result i32)
    local.get $x
    i32.const 1
    i32.add))
```

It declares no imports, so an engine instantiates it with nothing from the host. From outside, the instance can do two things: expose its one page of memory for the host to read and write, and compute `add_one` on a number. Every module built in Rust or Go is a larger version of this shape, with more sections, a real memory layout and a real import list.

> **Decision**
>
> Instantiate every component with the narrowest import set it needs. A component that logs gets a logging import, one that calls out over HTTP gets an HTTP import, and none gets blanket host access in case it needs more later. A guest's authority is exactly its resolved imports, so the only way to shrink its reach is to resolve fewer. Container habits point the other way: a `Dockerfile` or a `securityContext` subtracts from an ambient starting position, while here you add, one named function at a time, to a starting position of none.

> **🤖 Explore with your agent**
>
> "Write `imp.wat`, a copy of the `add_one` module that also imports `env.host_log` as `(func (param i32 i32))`, and run `wasmtime run --invoke add_one imp.wat 41`. Then explain, using the rule that a guest's authority is exactly its resolved imports, what I would have to link in before it instantiates, and what the narrowest set is for a component that only logs."
>
> Check: the run fails at instantiation with ``unknown import: `env::host_log` has not been defined``, and the reply names the host function to supply and nothing wider.

## Build, run, observe

Wasmtime runs a `.wat` file directly. Save the module above as `add_one.wat`:

```bash
wasmtime run --invoke add_one add_one.wat 41
```

It prints `42`. Wasmtime warns that `--invoke` with arguments and results is experimental. The module has no imports, so nothing else is needed.

Experiments:

- Add `(import "env" "host_log" (func $log (param i32 i32)))` to the module. Instantiation fails with ``unknown import: `env::host_log` has not been defined``, because the host linked nothing under that name.
- Replace the function with `(func (export "peek") (param $x i32) (result i32) local.get $x i32.load)` and run `wasmtime run --invoke peek add_one.wat 65536`. The one-page memory ends at offset 65536, and the access traps with `memory fault ... out of bounds memory access` instead of reading further.

## For deeper coverage

- Chiarlone, *Server-Side WebAssembly* (Manning): the Wasm fundamentals, module and instance model, and toolchain behind the execution model.
- Jain, *WebAssembly for Cloud* (Apress): the Wasm memory model, module layout, and the capability-oriented sandboxing model.
- [WebAssembly Core Specification (W3C Recommendation)](https://www.w3.org/TR/wasm-core-2/): the primary source for module structure, linear memory semantics, the value types, validation, and the instruction set.

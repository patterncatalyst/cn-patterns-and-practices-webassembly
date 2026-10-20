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

Chapter 1 made the case for running server-side workloads as Wasm components and placed that choice against containers on cost, density, and startup time. None of that claim holds up unless the execution model underneath it actually isolates a guest the way the chapter promised. This chapter supplies that mechanism: what a module is before it runs, what an instance is once it does, where a guest's data lives, and why a guest cannot reach outside its own memory unless the host hands it a function that can.

The core idea worth carrying forward is narrower than it sounds: a Wasm module exchanges only numbers across its boundary, and it can touch nothing in the outside world except what the host passes in by name. Every later claim about Wasm's security story builds on this chapter's two primitives (linear memory as the only address space a guest can see, and the import table as the only channel into anything else): WASI's capability-scoped file and network access in Chapter 4, the typed interfaces the Component Model layers on top in Chapter 3, and Istio's Wasm filters in Chapter 25. Fix those two primitives in mind and every later security claim on this site reads as a consequence of them, not a separate assertion to take on faith.

One scoping note before the diagrams: this chapter describes the WebAssembly Core specification, the W3C Recommendation that defines modules, instances, linear memory, and the instruction set. It does not cover the Component Model's typed interfaces or WIT contracts: that's Chapter 3, which builds directly on the numbers-only boundary described here. It also doesn't cover WASI, the standard set of host capabilities a runtime can expose: that's Chapter 4, one particular, standardized way to use the import mechanism this chapter introduces. Treat this chapter as the floor the other two stand on, not a preview of either.

{% include excalidraw.html file="02-module-structure" alt="Diagram contrasting a Wasm module as a compile-time artifact made of sections (types, imports, functions, tables, memories, globals, exports, code, data) against a module instance as the runtime object created at instantiation, holding its own linear memory, table, globals, and resolved imports. An arrow labeled instantiate() points from the module to the instance." caption="Figure 2.1 — A module is a static binary; instantiation produces a running instance with its own state." %}

## Modules and instances

A Wasm module is a binary artifact, typically produced by compiling Rust, Go, C, or another source language to the `wasm32` (or `wasm64`) target. The binary format is organized into sections, and every compliant toolchain emits roughly the same shape: a **type section** declaring function signatures, an **import section** naming what the module expects the host to provide, a **function section** and matching **code section** holding the module's own function bodies, a **memory section** declaring how much linear memory the module needs, a **table section** for indirect call targets, a **global section** for mutable or immutable module-level values, an **export section** naming what the module offers the host, and optional **data** and **element** sections that initialize memory and tables at instantiation time. Custom sections can carry debug information or tool-specific metadata without affecting execution.

That binary is inert until a runtime instantiates it. Instantiation is the step that turns a module into a live instance: the engine allocates the instance's own linear memory (sized per the memory section, typically starting at one or more 64 KiB pages), allocates its table, initializes its globals, resolves every entry in the import section against functions, memories, tables, or globals the host supplies, and runs any data and element segments that populate memory and tables before the module's own code runs. Two instances created from the same module are independent: each gets its own linear memory, its own table, and its own globals, with no sharing unless the host explicitly links them together (sharing a memory instance across guests is possible and is exactly how threads work in the shared-memory proposal, but it never happens by default).

This split matters because it is the first place "the module" and "the running thing" stop being the same noun. A module is a file on disk, something Buf-style tooling, a container registry, or a plain object store can hold and version. An instance is runtime state: a specific allocation of memory, a specific set of resolved imports, a specific stack. wasmtime (Chapter 14) can instantiate the same module thousands of times, cheaply, because most of the expensive work (validating and compiling the module's bytecode to native code) happens once per module, not once per instance. That property is a large part of why cold-start costs for Wasm workloads look nothing like cold-start costs for a container image: an already-compiled module instantiates in microseconds, because instantiation is mostly memory allocation and import resolution, not another pass over the bytecode.

Validation happens before any of this. Every module is statically type-checked against the Core spec's rules before an engine will execute a single instruction from it: every operand stack transition, every branch target, every function call signature is checked for soundness ahead of time. A module that fails validation is rejected outright; it never gets an instance. This static guarantee is part of why a Wasm trap at run time (an out-of-bounds memory access, an integer division by zero, a stack overflow) is a controlled failure rather than memory corruption: the categories of error the type system can rule out statically, it does, and the categories it can't (mostly about *values*, not *types*) become traps the engine catches and the host decides how to handle, rather than undefined behavior the guest's own code might exploit.

## Linear memory

A module's linear memory is a single, contiguous, mutable array of bytes, indexed from zero, that the module's own instructions address directly. It is called *linear* specifically to contrast it with a general-purpose heap of separately allocated objects: there is exactly one flat address space per memory instance, and every load and store instruction specifies an offset into it. Memory grows in units of pages, each 64 KiB, either at instantiation (the module's initial page count) or at run time via the `memory.grow` instruction, up to whatever maximum the module declares or the host enforces.

The property worth sitting with is what linear memory is *not*. It is not the host process's address space, and a guest has no instruction that lets it read or write an address outside its own memory instance. A pointer inside a Wasm module is just an integer offset into that module's own linear memory: it means nothing to the host, and it means nothing to a different instance, even one created from the identical module. This is the mechanical reason a Wasm module cannot leak or corrupt host memory the way a native shared library loaded into a process can: there is no address space for it to leak into, because every load and store instruction is bounds-checked against the current size of that instance's own memory before it executes. An access past the end of linear memory does not read adjacent host memory or an adjacent instance's memory; the engine traps, execution of that instance halts, and the host decides what to do next, typically tearing the instance down and reporting the failure up to whatever scheduled it. Compare this to a native buffer overflow in a C program's heap, which keeps running past the end of an allocation into whatever bytes happen to be there next; a Wasm linear-memory overrun has nowhere to run past, because the bounds check is part of every single memory instruction, not an optional hardening feature a compiler flag turns on.

{% include excalidraw.html file="02-linear-memory" alt="Diagram of a Wasm linear memory as a contiguous byte array starting at offset 0 and growing in 64 KiB pages. One arrow shows an in-bounds load instruction succeeding at an offset inside the current memory size. A second arrow shows an access past the end of the final page hitting the bounds check and trapping instead of reading further memory." caption="Figure 2.2 — Every load and store is bounds-checked against the instance's own memory size; past the edge is a trap, not adjacent memory." %}

This also explains why data crossing the module boundary looks the way it does in practice. A host function and a guest function can't pass a string or a struct directly, because there's no shared type system for anything beyond the numeric value types the next section covers. What toolchains actually do is have the guest allocate a region of its own linear memory, write bytes into it, and return the offset and length as two plain integers; the host then reads that same region out of the guest's memory using the memory accessor its embedding API provides. The guest never hands the host a pointer the host could dereference directly; it hands the host coordinates into the guest's own memory, and the host's embedding API (not the guest) is responsible for translating those coordinates into an actual read.

A minimal Rust guest, compiled for `wasm32-unknown-unknown`, showing that pattern directly:

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

Both export a `ptr` that is nothing more than an `i32` offset from the host's point of view: a number, not an address the host's own memory-unsafe code could dereference. Chapter 3 picks this exact friction up: the Component Model and WIT exist largely to stop every project from hand-rolling this allocate-write-pass-offset dance for every string and record it needs to move across the boundary.

## The stack and types

Wasm's instruction set is stack-based: most instructions pop operands off an implicit operand stack and push a result back onto it, rather than naming registers the way a native ISA does. That operand stack is engine-internal and invisible to both the guest's own code and the host: a module has no instruction that reads or manipulates it as data, which closes off a whole category of stack-smashing techniques that target native call stacks. Local variables and function parameters live in a separate, per-call-frame local variable space, and module-level state that needs to persist across calls lives in globals or in linear memory, not on the operand stack.

The Core spec defines a small, fixed set of value types: `i32` and `i64` (integers, with no built-in signedness: instructions like `i32.add` are sign-agnostic while comparison instructions like `i32.lt_s` versus `i32.lt_u` make the signedness explicit at the instruction level), `f32` and `f64` (IEEE 754 floating point), `v128` (128-bit vectors for SIMD), and two reference types, `funcref` and `externref`, added by the reference-types proposal and folded into the 2.0 Recommendation. `funcref` is an opaque reference to a function, usable for indirect calls through a table; `externref` is an opaque reference to a host-defined value that a module can hold and pass back to the host without ever being able to inspect or forge it. Neither reference type lets a module manufacture a reference out of thin air or inspect what it points to; a module can only hold a reference it was handed and pass it along, which keeps the type system's soundness guarantees intact even in the presence of host-defined objects.

Notice what's absent from that list: no strings, no structs, no arrays, no pointers in the native sense. Every exported or imported function signature is built from these value types alone. That is a real constraint at the core level, and it's the reason the pattern in the previous section — allocate memory, write bytes, pass an offset and a length as two `i32`s — is the idiom every language's Wasm toolchain converges on before the Component Model gives it names and generated bindings.

## The sandbox

A Wasm instance runs inside a sandbox the engine enforces at two layers: the static layer is validation, described above; the dynamic layer is that nothing a guest's bytecode can do reaches outside its own linear memory, its own table, and its own globals, except through a function the host resolved into its import section. There is no instruction in the Core spec for opening a file, making a network connection, reading an environment variable, or issuing any other syscall. A freshly instantiated module, given no imports at all, can compute, branch, loop, and read and write its own linear memory — and nothing else. It cannot see the filesystem, the network, the clock, or any other instance running in the same engine unless one of those things was handed to it explicitly as an import.

This is the structural difference from a container. A containerized process is still a regular OS process: by default it inherits the full syscall interface the kernel exposes, and a container runtime's isolation (namespaces for what it can see, cgroups for what it can consume, seccomp filters for which syscalls are permitted at all) is bolted on afterward, as restrictions applied to something that starts out with ambient access to the machine it runs on. Getting that isolation right is an ongoing, layered exercise: a missing seccomp rule, a namespace that isn't dropped, a capability that wasn't stripped, and a container process can reach further than intended, because the starting position was "can do anything the kernel allows" and the hardening work is all subtraction from there.

A Wasm instance starts from the opposite position. It has no ambient access to anything outside its own linear memory until the host adds some, one import at a time. There is no subtraction to perform and no syscall surface to audit for gaps, because the syscall surface doesn't exist inside the sandbox at all: every capability a guest has is something a human or a deploy pipeline wrote down explicitly when wiring up that instance's imports. This is why a Wasm engine like wasmtime can run guest code from an untrusted source with real confidence that the guest cannot touch the host filesystem, even with zero firewall rules or seccomp configuration layered on top: the guest was simply never given a function that could reach the filesystem in the first place.

{% include excalidraw.html file="02-sandbox-boundary" alt="Side-by-side diagram. Left: a container process inside a host OS, with a dashed line showing ambient, default access to the kernel syscall interface, filesystem, and network, narrowed afterward by namespaces, cgroups, and seccomp. Right: a Wasm guest instance inside an engine, with no line at all to host filesystem, network, or syscalls by default, and a single solid arrow labeled imports showing the only path out, through specific host functions the engine resolved at instantiation." caption="Figure 2.3 — A container starts with ambient OS access that isolation narrows; a Wasm guest starts with none, and gains only what its imports name." %}

## Capability-based security

The import section is the entire capability surface. At instantiation, the host (the embedding application, using an API like wasmtime's or wasmCloud's) decides exactly which functions, memories, tables, and globals satisfy the module's declared imports. Whatever isn't linked in simply doesn't exist from the guest's point of view: there's no ambient namespace of "the host's functions" a guest can enumerate or probe; a guest can call only the specific, named imports the host chose to resolve for that instance.

This is capability-based security in the strict sense the term has in access-control theory: authority to do something flows only through an unforgeable reference that was explicitly handed over, never through ambient identity or a global namespace a caller can reach into. A Wasm guest holding no file-access import cannot open a file no matter how its own code is written, because "open a file" is not an operation its instruction set can express without a host function that does it on its behalf. Two instances of the identical module can be given entirely different capability sets (one wired to a logging function and nothing else, another wired to logging plus an outbound HTTP call), and each instance's actual authority matches exactly what it was handed, not what the module's code happens to contain.

A host-side Rust example, using wasmtime's `Linker`, showing exactly one capability (a logging function) wired in for a guest to call:

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

The same wiring with wasmtime-go on the host side:

```go
linker := wasmtime.NewLinker(engine)
err := linker.FuncWrap("env", "host_log", func(caller *wasmtime.Caller, ptr, length int32) {
    mem := caller.GetExport("memory").Memory()
    data := mem.UnsafeData(store)[ptr : ptr+length]
    fmt.Println(string(data))
})
instance, err := linker.Instantiate(store, module)
```

In both, `host_log` is the only door this particular instance has to the outside world. No filesystem function, no socket function, no process function was named, so none exist for this guest to call. That's not because a policy engine is watching for violations; it's because the function table the guest's calls resolve against simply has nothing else in it. Chapter 4 names this exact mechanism when it covers WASI: a standardized set of imports a runtime can offer, each one scoped (a guest can be handed a single pre-opened directory handle rather than open filesystem access, for instance) rather than the all-or-nothing access a process normally inherits from its parent.

{% include excalidraw.html file="02-capability-passing" alt="Diagram showing a host process with several functions available internally: host_log, host_fetch, write_file, open_socket. An instantiation step links only host_log into a guest instance's import table, shown as a single arrow crossing the boundary, while the other three functions remain inside the host with no connecting line to the guest at all." caption="Figure 2.4 — The host chooses, function by function, what crosses into a guest's import table; everything else stays unreachable." %}

## A minimal module, concretely

Stripped of any language's compiler, a Wasm module is text (`.wat`, the spec's human-readable format) or binary (`.wasm`). A module exporting one function and declaring its own memory looks like this:

```wat
(module
  (memory (export "memory") 1)        ;; 1 page = 64 KiB, exported so a host can read/write it
  (func (export "add_one") (param $x i32) (result i32)
    local.get $x
    i32.const 1
    i32.add))
```

That's a complete, valid module: one memory of one page, one exported function taking an `i32` and returning an `i32`. It declares no imports, so an engine can instantiate it with nothing supplied from the host at all, and the resulting instance can do exactly two things from outside: expose its one page of linear memory for the host to read and write, and compute `add_one` on a number the host passes in. Every module this site builds in Rust and Go compiles down to a much larger version of this same shape (more sections, a real memory layout, a real import list) but nothing fundamentally different from it.

## Where this goes next

This chapter fixed two primitives: linear memory as the only address space a guest instance can see, and the import table as the only channel to anything outside it. Chapter 3 builds the Component Model and WIT directly on top of the numbers-only boundary this chapter described, giving the allocate-write-pass-offset pattern a name, a schema, and generated bindings in both Rust and Go instead of hand-written glue. Chapter 4 covers WASI, the standardized set of capability-scoped imports a runtime can offer a guest for files, clocks, and networking, built entirely from the import mechanism in this chapter's last section. Chapter 9 revisits linear memory and traps from the debugging side, once there's a real component to misbehave.

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Every component this site builds, in both Rust and Go, is instantiated with the narrowest import set the example needs and nothing wider — a component that logs gets a logging import, a component that calls out over HTTP gets an HTTP import, and no component gets blanket host access on the theory that it might need more later. That rule follows directly from this chapter's execution model, not from an external policy layer: a Wasm instance's authority is exactly its resolved imports, so the only way to shrink a guest's reach is to resolve fewer imports at instantiation time. Readers coming from containers should expect the opposite default from what a `Dockerfile` or a Kubernetes `securityContext` trains — there, isolation is something subtracted from an ambient starting position; here, it's something added, one named function at a time, to a starting position of none.</p></div>

## For deeper coverage

- Chiarlone, A., *WebAssembly in Action* (Manning, 2022) — modules, instances, and linear memory from the embedder's side, with worked examples in the Rust and C toolchains.
- Jain, K., *Practical WebAssembly* (Apress, 2024) — the stack machine, validation, and the capability-oriented security model this chapter builds from.
- [WebAssembly Core Specification (W3C Recommendation)](https://www.w3.org/TR/wasm-core-2/) — the primary source for module structure, linear memory semantics, the value types, validation, and the instruction set this chapter walks through.

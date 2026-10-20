package main

import "unsafe"

// cabi_realloc for the Go CONSUMER *command* component.
//
// Why this differs from the provider's cabi_realloc (../go/cabi_realloc.go,
// which allocates from the Go heap): the wasip1 -> wasip2 *command* adapter
// fetches the process arguments by calling this exported `cabi_realloc` from
// INSIDE the module's `_start`, while the TinyGo runtime is still bringing
// itself up (runtime.run -> os.Args -> args_sizes_get -> adapter -> back into
// cabi_realloc). A heap-backed realloc reenters `make([]...)` before the GC is
// ready and the adapter trips an assertion ("assertion failed at adapter line
// 2857" in args_sizes_get). A reactor component never hits this because
// `_initialize` finishes before any export runs — but a command's _start IS the
// first entry.
//
// The fix: serve every Canonical ABI allocation from a fixed, statically
// reserved arena with a monotonically advancing offset. It touches no Go heap,
// so it is safe to call during early init, and TinyGo's non-moving GC keeps the
// global array in place while the host reads lifted strings and lists out of it.
// The component runs the scenario once and exits, so the arena is never freed
// and 1 MiB is far more than the scenario's few kilobytes of lifted data.
const cabiArenaSize = 1 << 20

var cabiArena [cabiArenaSize]byte
var cabiOffset uintptr

//export cabi_realloc
func cabiRealloc(ptr unsafe.Pointer, size, align, newsize uintptr) unsafe.Pointer {
	if newsize == 0 {
		// Free / shrink-to-zero: the return value is ignored by the ABI.
		return unsafe.Pointer(&cabiArena[0])
	}
	if align == 0 {
		align = 1
	}
	off := (cabiOffset + align - 1) &^ (align - 1)
	if off+newsize > cabiArenaSize {
		// Out of arena: returning nil signals allocation failure to the ABI
		// rather than silently corrupting memory.
		return nil
	}
	newptr := unsafe.Pointer(&cabiArena[off])
	cabiOffset = off + newsize
	if ptr != nil && size > 0 {
		copy(unsafe.Slice((*byte)(newptr), newsize), unsafe.Slice((*byte)(ptr), size))
	}
	return newptr
}

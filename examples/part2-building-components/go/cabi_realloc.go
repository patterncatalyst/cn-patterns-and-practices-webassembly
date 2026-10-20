package main

import "unsafe"

// cabiRealloc is the Canonical ABI `cabi_realloc` core function. The component
// model calls it to allocate (originalPtr/originalSize = 0) and reallocate the
// linear-memory buffers used to lift and lower strings and lists across the
// component boundary. `wasm-tools component new` fails with "module does not
// export a function named cabi_realloc" without it.
//
// This mirrors go.bytecodealliance.org/x/cabi, inlined here because that
// package ships no export directive of its own: the `//export cabi_realloc`
// pragma below (TinyGo) is what actually publishes the core function. On wasm
// pointers are 32-bit, matching the Canonical ABI's i32 handles.
//
//export cabi_realloc
func cabiRealloc(ptr unsafe.Pointer, size, align, newsize uintptr) unsafe.Pointer {
	if newsize <= size {
		return ptr
	}
	newptr := cabiAlloc(newsize, align)
	if size > 0 {
		copy(unsafe.Slice((*byte)(newptr), newsize), unsafe.Slice((*byte)(ptr), size))
	}
	return newptr
}

// cabiAlloc allocates size bytes aligned to align by picking a slice element
// type of the matching width, so the Go/TinyGo runtime owns the memory and the
// GC keeps it alive while the host reads it.
func cabiAlloc(size, align uintptr) unsafe.Pointer {
	switch align {
	case 1:
		s := make([]uint8, size)
		return unsafe.Pointer(unsafe.SliceData(s))
	case 2:
		s := make([]uint16, (size+1)/2)
		return unsafe.Pointer(unsafe.SliceData(s))
	case 4:
		s := make([]uint32, (size+3)/4)
		return unsafe.Pointer(unsafe.SliceData(s))
	default:
		s := make([]uint64, (size+7)/8)
		return unsafe.Pointer(unsafe.SliceData(s))
	}
}

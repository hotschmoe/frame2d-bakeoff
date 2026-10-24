// Package main builds frame2d_engine as a C shared library (go build -buildmode=c-shared) for dart:ffi.
// Every exported function is a thin wrapper over package session; buffers returned to Dart are pinned
// Go memory owned by the session and stay valid until the next solve or f2d_free.
package main

import "C"

import (
	"unsafe"

	"frame2d/bridge/session"
)

func main() {}

func ptr(f []float64) unsafe.Pointer {
	if len(f) == 0 {
		return nil
	}
	return unsafe.Pointer(&f[0])
}

//export f2d_noop
func f2d_noop() {}

//export f2d_echo
func f2d_echo(n C.int) unsafe.Pointer { return ptr(session.Echo(int(n))) }

//export f2d_load_json
func f2d_load_json(data unsafe.Pointer, n C.int) C.int {
	return C.int(session.FromJSON(C.GoBytes(data, n)))
}

//export f2d_gen
func f2d_gen(b, s C.int) C.int { return C.int(session.Gen(int(b), int(s))) }

//export f2d_free
func f2d_free(h C.int) { session.Free(int32(h)) }

//export f2d_last_error
func f2d_last_error() unsafe.Pointer { return unsafe.Pointer(&session.LastError()[0]) }

//export f2d_counts
func f2d_counts(h C.int, out *C.int) {
	s := session.Get(int32(h))
	if s == nil {
		return
	}
	c := s.Counts()
	o := unsafe.Slice(out, 3)
	o[0], o[1], o[2] = C.int(c[0]), C.int(c[1]), C.int(c[2])
}

//export f2d_geometry
func f2d_geometry(h C.int) unsafe.Pointer {
	if s := session.Get(int32(h)); s != nil {
		return ptr(s.Geometry())
	}
	return nil
}

//export f2d_result
func f2d_result(h C.int) unsafe.Pointer {
	if s := session.Get(int32(h)); s != nil {
		return ptr(s.Result())
	}
	return nil
}

//export f2d_stats
func f2d_stats(h C.int) unsafe.Pointer {
	if s := session.Get(int32(h)); s != nil {
		return ptr(s.Stats())
	}
	return nil
}

// f2d_case_ids writes the load case ids as a JSON array into buf (NUL-terminated) and returns its length.
//
//export f2d_case_ids
func f2d_case_ids(h C.int, buf *C.char, capacity C.int) C.int {
	s := session.Get(int32(h))
	if s == nil {
		return 0
	}
	b := s.CaseIDs()
	if len(b)+1 > int(capacity) {
		return -1
	}
	dst := unsafe.Slice((*byte)(unsafe.Pointer(buf)), len(b)+1)
	copy(dst, b)
	dst[len(b)] = 0
	return C.int(len(b))
}

//export f2d_set_node
func f2d_set_node(h, idx C.int, x, y C.double) {
	if s := session.Get(int32(h)); s != nil {
		s.SetNode(int(idx), float64(x), float64(y))
	}
}

//export f2d_solve
func f2d_solve(h, c C.int) C.int {
	if s := session.Get(int32(h)); s != nil {
		return C.int(s.Solve(int(c)))
	}
	return -1
}

// f2d_to_json returns a pointer to the serialized model; its length is written to outLen.
//
//export f2d_to_json
func f2d_to_json(h C.int, outLen *C.int) unsafe.Pointer {
	s := session.Get(int32(h))
	if s == nil {
		return nil
	}
	b := s.ToJSON()
	*outLen = C.int(len(b))
	return unsafe.Pointer(unsafe.SliceData(b))
}

// f2d_process_age_ms returns milliseconds since process start (0 when unknown).
//
//export f2d_process_age_ms
func f2d_process_age_ms() C.double { return C.double(processAgeMS()) }

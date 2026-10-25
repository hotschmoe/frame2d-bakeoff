// Package zigengine is the cgo boundary to the Zig engine (static library built from ../../zig by stack.sh; stack.sh passes the -L directory of the dev or release build in CGO_LDFLAGS).
// Every function is a thin wrapper over the C ABI in zig/include/frame2d_engine.h: Go moves bytes, Zig does
// all parsing, analysis and result serialization.
package zigengine

/*
#cgo CFLAGS: -I${SRCDIR}/../../zig/include
#cgo LDFLAGS: -lframe2d
#include <stdlib.h>
#include "frame2d_engine.h"
*/
import "C"

import (
	"encoding/json"
	"math"
	"runtime"
	"sync"
	"unsafe"
)

// ModelError is a validation or solve failure caused by the model (SPEC 4.6): HTTP 422 / CLI exit 2.
type ModelError struct {
	Code   string `json:"error"`
	Detail string `json:"detail"`
}

func (e *ModelError) Error() string { return e.Code + ": " + e.Detail }

// BadRequestError is a malformed document (invalid JSON or wrong field types): HTTP 400 / CLI exit 1.
type BadRequestError struct{ Detail string }

func (e *BadRequestError) Error() string { return "bad_request: " + e.Detail }

const (
	rcOK         = 0
	rcBadRequest = 1
	rcModelError = 2
)

func ptr(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return nil
	}
	return unsafe.Pointer(&b[0])
}

// take copies a Zig-owned output buffer into Go memory and frees it.
func take(p unsafe.Pointer, n C.int) []byte {
	if p == nil || n <= 0 {
		return nil
	}
	b := C.GoBytes(p, n)
	C.f2d_buf_free(p, n)
	return b
}

func decodeErr(rc C.int, out []byte) error {
	var me ModelError
	_ = json.Unmarshal(out, &me)
	if rc == rcBadRequest || me.Code == "bad_request" {
		return &BadRequestError{Detail: me.Detail}
	}
	if rc == rcModelError {
		return &me
	}
	return &InternalError{Detail: "engine internal error"}
}

// SolveJSON parses a model, solves every load case and returns the results JSON (SPEC 5.2). With withAlloc the
// stats carry the engine's allocation counters (CLI only).
func SolveJSON(model []byte, withAlloc bool) ([]byte, error) {
	var out unsafe.Pointer
	var n C.int
	w := C.int(0)
	if withAlloc {
		w = 1
	}
	rc := C.f2d_solve_json(ptr(model), C.int(len(model)), w, &out, &n)
	b := take(out, n)
	if rc != rcOK {
		return nil, decodeErr(rc, b)
	}
	return b, nil
}

// Check parses a model without solving it.
func Check(model []byte) error {
	var out unsafe.Pointer
	var n C.int
	rc := C.f2d_check_json(ptr(model), C.int(len(model)), &out, &n)
	b := take(out, n)
	if rc != rcOK {
		return decodeErr(rc, b)
	}
	return nil
}

// GenJSON returns the generated B x S frame (SPEC 4.8) as model JSON.
func GenJSON(bays, stories int) ([]byte, error) {
	var out unsafe.Pointer
	var n C.int
	rc := C.f2d_gen_json(C.int(bays), C.int(stories), &out, &n)
	b := take(out, n)
	if rc != rcOK {
		return nil, decodeErr(rc, b)
	}
	return b, nil
}

// Bench generates and solves B x S reps times and returns JSON with the median timings.
func Bench(bays, stories, reps int) ([]byte, error) {
	var out unsafe.Pointer
	var n C.int
	rc := C.f2d_bench(C.int(bays), C.int(stories), C.int(reps), &out, &n)
	b := take(out, n)
	if rc != rcOK {
		return nil, decodeErr(rc, b)
	}
	return b, nil
}

// Noop calls the exported no-op (boundary benchmark).
func Noop() { C.f2d_noop() }

// Echo copies n float64 values from the engine into dst (len n), the boundary transfer benchmark.
func Echo(dst []float64) {
	p := C.f2d_echo(C.int(len(dst)))
	copy(dst, unsafe.Slice((*float64)(p), len(dst)))
}

// EchoView returns a zero-copy view of the engine's echo buffer; valid until the next Echo/EchoView call.
func EchoView(n int) []float64 { return unsafe.Slice((*float64)(C.f2d_echo(C.int(n))), n) }

// ---- sweep

// SweepVariant is one result of a beam-stiffness sweep.
type SweepVariant struct {
	Scale     float64 `json:"scale"`
	RoofDrift float64 `json:"roof_drift_W"`
	MaxAbsM   float64 `json:"max_abs_M"`
}

// SweepEnvelope is the max over all variants.
type SweepEnvelope struct {
	MaxRoofDrift float64 `json:"max_roof_drift_W"`
	MaxAbsM      float64 `json:"max_abs_M"`
}

// SweepResult is the /sweep response body.
type SweepResult struct {
	Variants []SweepVariant `json:"variants"`
	Envelope SweepEnvelope  `json:"envelope"`
}

// Sweep scales the I of every BM section across n variants (lo..hi), solving them on all cores. Each worker
// goroutine owns a Zig-side forked model, so the solves run fully in parallel inside cgo calls.
func Sweep(model []byte, n int, lo, hi float64) (*SweepResult, error) {
	if n < 1 {
		return nil, &ModelError{Code: "invalid_ref", Detail: "variants must be >= 1"}
	}
	var out unsafe.Pointer
	var outLen, rc C.int
	base := C.f2d_sweep_open(ptr(model), C.int(len(model)), &out, &outLen, &rc)
	if base == nil {
		return nil, decodeErr(rc, take(out, outLen))
	}
	defer C.f2d_sweep_close(base)

	nw := runtime.NumCPU()
	if nw > n {
		nw = n
	}
	workers := make([]unsafe.Pointer, 0, nw)
	defer func() {
		for _, w := range workers {
			C.f2d_sweep_worker_free(w)
		}
	}()
	for i := 0; i < nw; i++ {
		w := C.f2d_sweep_worker(base)
		if w == nil {
			return nil, &InternalError{Detail: "sweep: out of memory"}
		}
		workers = append(workers, w)
	}

	res := &SweepResult{Variants: make([]SweepVariant, n)}
	errs := make([]error, n)
	jobs := make(chan int)
	var wg sync.WaitGroup
	for _, w := range workers {
		wg.Add(1)
		go func(w unsafe.Pointer) {
			defer wg.Done()
			var pt [2]C.double
			var msg [256]C.char
			for k := range jobs {
				scale := lo
				if n > 1 {
					scale = lo + (hi-lo)*float64(k)/float64(n-1)
				}
				if c := C.f2d_sweep_run(w, C.double(scale), &pt[0], &msg[0], C.int(len(msg))); c != 0 {
					if c == rcOOM {
						errs[k] = &InternalError{Detail: "out of memory"}
					} else {
						errs[k] = &ModelError{Code: codeName(int(c)), Detail: C.GoString(&msg[0])}
					}
					continue
				}
				res.Variants[k] = SweepVariant{scale, float64(pt[0]), float64(pt[1])}
			}
		}(w)
	}
	for k := 0; k < n; k++ {
		jobs <- k
	}
	close(jobs)
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return nil, e
		}
	}
	for i, v := range res.Variants {
		if i == 0 || v.RoofDrift > res.Envelope.MaxRoofDrift {
			res.Envelope.MaxRoofDrift = v.RoofDrift
		}
		res.Envelope.MaxAbsM = math.Max(res.Envelope.MaxAbsM, v.MaxAbsM)
	}
	return res, nil
}

// codeName maps an engine error code to the "error" field of the error JSON (the table lives in Zig).
func codeName(c int) string { return C.GoString(C.f2d_code_name(C.int(c))) }

// rcOOM is what f2d_sweep_run returns when the engine ran out of memory.
const rcOOM = -100

// InternalError is an engine failure that is neither the client's nor the model's fault (HTTP 500).
type InternalError struct{ Detail string }

func (e *InternalError) Error() string { return "internal: " + e.Detail }

// libStamp is set at link time (-ldflags -X) to a hash of the Zig static library, so Go relinks when the
// library changes (the go command does not hash library contents into the link action).
var libStamp string

// LibStamp returns the stamp of the linked engine library.
func LibStamp() string { return libStamp }

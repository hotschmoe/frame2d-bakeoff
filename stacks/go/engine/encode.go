package engine

import (
	"encoding/json"
	"io"
	"math"
	"strconv"
	"sync"
)

// WriteJSON streams r as JSON (same shape and field order as encoding/json would produce) through a
// small pooled buffer. The reflection encoder builds the whole document in memory first, which for a
// 50x50 model is megabytes per request; this one never holds more than flushAt bytes.
func (r *Results) WriteJSON(w io.Writer) error {
	e := encoderPool.Get().(*jsonEnc)
	e.w, e.err = w, nil
	e.buf = e.buf[:0]
	e.results(r)
	e.flush()
	err := e.err
	e.w = nil
	encoderPool.Put(e)
	return err
}

const flushAt = 32 << 10

var encoderPool = sync.Pool{New: func() any { return &jsonEnc{buf: make([]byte, 0, flushAt+4096)} }}

type jsonEnc struct {
	w   io.Writer
	buf []byte
	err error
}

func (e *jsonEnc) flush() {
	if e.err == nil && len(e.buf) > 0 {
		_, e.err = e.w.Write(e.buf)
	}
	e.buf = e.buf[:0]
}

func (e *jsonEnc) s(x string) { e.buf = append(e.buf, x...) }

func (e *jsonEnc) maybeFlush() {
	if len(e.buf) >= flushAt {
		e.flush()
	}
}

func (e *jsonEnc) num(v float64) {
	// JSON has no NaN or Inf; encoding/json refuses them. A solved model never produces them, but
	// emit null rather than invalid JSON if one slips through.
	if math.IsNaN(v) || math.IsInf(v, 0) {
		e.s("null")
		return
	}
	abs := math.Abs(v)
	f := byte('f')
	if abs != 0 && (abs < 1e-6 || abs >= 1e21) {
		f = 'e'
	}
	n := len(e.buf)
	e.buf = strconv.AppendFloat(e.buf, v, f, -1, 64)
	if f == 'e' { // clean up e-09 to e-9 as encoding/json does
		if m := len(e.buf); m-n >= 4 && e.buf[m-4] == 'e' && e.buf[m-3] == '-' && e.buf[m-2] == '0' {
			e.buf[m-2] = e.buf[m-1]
			e.buf = e.buf[:m-1]
		}
	}
}

func (e *jsonEnc) str(x string) {
	for i := 0; i < len(x); i++ {
		if c := x[i]; c < 0x20 || c >= 0x7f || c == '"' || c == '\\' || c == '<' || c == '>' || c == '&' {
			b, _ := json.Marshal(x) // rare: let encoding/json do the escaping
			e.buf = append(e.buf, b...)
			return
		}
	}
	e.buf = append(append(append(e.buf, '"'), x...), '"')
}

func (e *jsonEnc) int(v int) { e.buf = strconv.AppendInt(e.buf, int64(v), 10) }

func (e *jsonEnc) field(name string) {
	e.str(name)
	e.s(":")
}

func (e *jsonEnc) opt(name string, v *uint64) {
	e.field(name)
	if v == nil {
		e.s("null")
	} else {
		e.buf = strconv.AppendUint(e.buf, *v, 10)
	}
}

func (e *jsonEnc) results(r *Results) {
	e.s(`{"load_cases":[`)
	for i := range r.LoadCases {
		if i > 0 {
			e.s(",")
		}
		e.caseResult(&r.LoadCases[i])
	}
	e.s(`],"warnings":[`)
	for i, wn := range r.Warnings {
		if i > 0 {
			e.s(",")
		}
		e.s(`{"warning":`)
		e.str(wn.Warning)
		e.s(`,"node":`)
		e.int(wn.Node)
		e.s(`,"dof":`)
		e.str(wn.DOF)
		e.s("}")
	}
	e.s(`],"stats":{"nodes":`)
	st := &r.Stats
	e.int(st.Nodes)
	e.s(`,"members":`)
	e.int(st.Members)
	e.s(`,"free_dofs":`)
	e.int(st.FreeDOFs)
	e.s(`,"profile_before":`)
	e.int(st.ProfileBefore)
	e.s(`,"profile_after":`)
	e.int(st.ProfileAfter)
	e.s(`,"assemble_ms":`)
	e.num(st.AssembleMS)
	e.s(`,"factor_ms":`)
	e.num(st.FactorMS)
	e.s(`,"solve_ms":`)
	e.num(st.SolveMS)
	e.s(",")
	e.opt("alloc_count", st.AllocCount)
	e.s(",")
	e.opt("alloc_bytes", st.AllocBytes)
	e.s(",")
	e.opt("peak_heap_bytes", st.PeakHeapBytes)
	e.s("}}\n")
}

func (e *jsonEnc) caseResult(c *CaseResult) {
	e.s(`{"id":`)
	e.str(c.ID)
	e.s(`,"displacements":[`)
	for i, d := range c.Displacements {
		if i > 0 {
			e.s(",")
		}
		e.s(`{"node":`)
		e.int(d.Node)
		e.s(`,"ux":`)
		e.num(d.UX)
		e.s(`,"uy":`)
		e.num(d.UY)
		e.s(`,"rz":`)
		e.num(d.RZ)
		e.s("}")
		e.maybeFlush()
	}
	e.s(`],"reactions":[`)
	for i, d := range c.Reactions {
		if i > 0 {
			e.s(",")
		}
		e.s(`{"node":`)
		e.int(d.Node)
		e.s(`,"fx":`)
		e.num(d.FX)
		e.s(`,"fy":`)
		e.num(d.FY)
		e.s(`,"mz":`)
		e.num(d.MZ)
		e.s("}")
		e.maybeFlush()
	}
	e.s(`],"members":[`)
	for i := range c.Members {
		if i > 0 {
			e.s(",")
		}
		m := &c.Members[i]
		e.s(`{"id":`)
		e.int(m.ID)
		e.s(`,"end_forces":[`)
		for k, v := range m.EndForces {
			if k > 0 {
				e.s(",")
			}
			e.num(v)
		}
		e.s(`],"stations":[`)
		for k, st := range m.Stations {
			if k > 0 {
				e.s(",")
			}
			e.s(`{"x":`)
			e.num(st.X)
			e.s(`,"N":`)
			e.num(st.N)
			e.s(`,"V":`)
			e.num(st.V)
			e.s(`,"M":`)
			e.num(st.M)
			e.s("}")
		}
		e.s("]}")
		e.maybeFlush()
	}
	e.s(`],"equilibrium_residual":`)
	e.num(c.EquilibriumResidual)
	e.s("}")
}

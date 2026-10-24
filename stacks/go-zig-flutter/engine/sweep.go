package engine

import (
	"math"
	"runtime"
	"sync"
)

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

// Sweep scales the I of every BM section across n variants, solving them on all cores.
func Sweep(base *Model, n int, lo, hi float64) (*SweepResult, error) {
	if n < 1 {
		return nil, modelErr(ErrInvalidRef, "variants must be >= 1")
	}
	// validate once, find the roof node and case W
	p0, err := Prepare(base)
	if err != nil {
		return nil, err
	}
	wCase := -1
	for c := 0; c < p0.NumCases(); c++ {
		if p0.CaseID(c) == "W" {
			wCase = c
		}
	}
	if wCase < 0 {
		return nil, modelErr(ErrInvalidRef, "sweep needs a load case with id W")
	}
	roof := 0
	for k := range p0.NodeIDs {
		if p0.Y[k] > p0.Y[roof] || (p0.Y[k] == p0.Y[roof] && p0.X[k] < p0.X[roof]) {
			roof = k
		}
	}
	res := &SweepResult{Variants: make([]SweepVariant, n)}
	errs := make([]error, n)
	jobs := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < runtime.NumCPU(); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for k := range jobs {
				scale := lo
				if n > 1 {
					scale = lo + (hi-lo)*float64(k)/float64(n-1)
				}
				m := *base
				m.Sections = append([]Section(nil), base.Sections...)
				for i := range m.Sections {
					if m.Sections[i].ID == "BM" {
						m.Sections[i].I *= scale
					}
				}
				p, err := Prepare(&m)
				if err != nil {
					errs[k] = err
					continue
				}
				out, err := p.Solve()
				if err != nil {
					errs[k] = err
					continue
				}
				maxM := 0.0
				for c := range out.Cases {
					for mi := range p.MemIDs {
						ef := out.Cases[c].EF[mi*6 : mi*6+6]
						for _, st := range p.Stations(c, mi, ef, p.MemberLength(mi)) {
							maxM = math.Max(maxM, math.Abs(st.M))
						}
					}
				}
				res.Variants[k] = SweepVariant{scale, out.Cases[wCase].U[roof*3], maxM}
			}
		}()
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

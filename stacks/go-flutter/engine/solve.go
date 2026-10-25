package engine

import (
	"math"
	"time"
)

// pivotTol is the relative pivot threshold of the factorization (SPEC 4.4).
const pivotTol = 1e-12 // BENCH-EDIT:leaf

// CaseOut holds the flat results of one load case, indexed by sorted node / member order.
type CaseOut struct {
	U        []float64 // nodes*3 displacements
	React    []float64 // nodes*3 reactions (zero where unrestrained)
	EF       []float64 // members*6 local end forces
	Residual float64
}

// Out is the flat result of Solve.
type Out struct {
	Cases []CaseOut
	Stats Stats
}

type geom struct{ l, c, s float64 }

func (p *Prepared) geometry() ([]geom, error) {
	g := make([]geom, len(p.MemIDs))
	for m := range g {
		dx := p.X[p.MJ[m]] - p.X[p.MI[m]]
		dy := p.Y[p.MJ[m]] - p.Y[p.MI[m]]
		l := math.Hypot(dx, dy)
		if l < 1e-9 {
			return nil, modelErr(ErrZeroLength, "member %d has zero length", p.MemIDs[m])
		}
		g[m] = geom{l, dx / l, dy / l}
	}
	return g, nil
}

// localK fills the 6x6 local stiffness of member m, statically condensed for end releases.
func (p *Prepared) localK(m int, l float64, k *[6][6]float64) {
	p.rawK(m, l, k)
	p.condense(m, k, nil)
}

// condense removes released rotations (local dof 2 at i, 5 at j) from k and, if given, f.
func (p *Prepared) condense(m int, k *[6][6]float64, f *[6]float64) {
	for e, r := range [2]int{2, 5} {
		if !p.rel[m][e] {
			continue
		}
		piv := k[r][r]
		if piv == 0 {
			continue
		}
		col := [6]float64{}
		for a := 0; a < 6; a++ {
			col[a] = k[a][r]
		}
		for a := 0; a < 6; a++ {
			for b := 0; b < 6; b++ {
				k[a][b] -= col[a] * k[r][b] / piv
			}
		}
		if f != nil {
			fr := f[r]
			for a := 0; a < 6; a++ {
				f[a] -= col[a] * fr / piv
			}
			f[r] = 0
		}
		for a := 0; a < 6; a++ {
			k[a][r], k[r][a] = 0, 0
		}
	}
}

// fixedEndM returns the fixed-end forces of member m, condensed for releases.
func (p *Prepared) fixedEndM(m int, w, l float64) [6]float64 {
	f := fixedEnd(w, l)
	if p.rel[m][0] || p.rel[m][1] {
		var k [6][6]float64
		p.rawK(m, l, &k)
		p.condense(m, &k, &f)
	}
	return f
}

func (p *Prepared) rawK(m int, l float64, k *[6][6]float64) {
	*k = [6][6]float64{}
	ea := p.mE[m] * p.mA[m] / l
	ei := p.mE[m] * p.mI[m]
	l2, l3 := l*l, l*l*l
	a, b, c, d := 12*ei/l3, 6*ei/l2, 4*ei/l, 2*ei/l
	k[0][0], k[0][3], k[3][0], k[3][3] = ea, -ea, -ea, ea
	k[1][1], k[1][2], k[1][4], k[1][5] = a, b, -a, b
	k[2][1], k[2][2], k[2][4], k[2][5] = b, c, -b, d
	k[4][1], k[4][2], k[4][4], k[4][5] = -a, -b, a, -b
	k[5][1], k[5][2], k[5][4], k[5][5] = b, d, -b, c
}

// rotate maps a 6-vector between local and global axes. toLocal: local = T g; otherwise g = T^T local.
func rotate(g geom, v *[6]float64, toLocal bool) [6]float64 {
	var o [6]float64
	c, s := g.c, g.s
	if !toLocal {
		s = -s
	}
	for e := 0; e < 6; e += 3 {
		o[e] = c*v[e] + s*v[e+1]
		o[e+1] = -s*v[e] + c*v[e+1]
		o[e+2] = v[e+2]
	}
	return o
}

func fixedEnd(w, l float64) [6]float64 {
	return [6]float64{0, -w * l / 2, -w * l * l / 12, 0, -w * l / 2, w * l * l / 12}
}

// Solve assembles, factors once and solves every load case.
func (p *Prepared) Solve() (*Out, error) { return p.SolveCase(-1) }

// SolveCase is Solve restricted to one load case (only >= 0); other cases are left empty.
func (p *Prepared) SolveCase(only int) (*Out, error) {
	g, err := p.geometry()
	if err != nil {
		return nil, err
	}
	nN, nM, n := len(p.NodeIDs), len(p.MemIDs), p.nFree

	t0 := time.Now()
	vals := p.vals
	for i := range vals {
		vals[i] = 0
	}
	var kl, kg [6][6]float64
	var gd [6]int
	for m := 0; m < nM; m++ {
		p.localK(m, g[m].l, &kl)
		// kg = T^T kl T
		var tmp [6][6]float64 // tmp = kl * T  (T maps global->local: local = T g)
		for r := 0; r < 6; r++ {
			for e := 0; e < 6; e += 3 {
				tmp[r][e] = kl[r][e]*g[m].c - kl[r][e+1]*g[m].s
				tmp[r][e+1] = kl[r][e]*g[m].s + kl[r][e+1]*g[m].c
				tmp[r][e+2] = kl[r][e+2]
			}
		}
		for cI := 0; cI < 6; cI++ { // kg = T^T tmp
			for e := 0; e < 6; e += 3 {
				kg[e][cI] = g[m].c*tmp[e][cI] - g[m].s*tmp[e+1][cI]
				kg[e+1][cI] = g[m].s*tmp[e][cI] + g[m].c*tmp[e+1][cI]
				kg[e+2][cI] = tmp[e+2][cI]
			}
		}
		for d := 0; d < 3; d++ {
			gd[d] = p.dofOf[p.MI[m]*3+d]
			gd[3+d] = p.dofOf[p.MJ[m]*3+d]
		}
		for a := 0; a < 6; a++ {
			if gd[a] < 0 {
				continue
			}
			for b := 0; b < 6; b++ {
				if gd[b] >= gd[a] {
					vals[p.colPtr[gd[b]]+gd[a]-p.top[gd[b]]] += kg[a][b]
				}
			}
		}
	}
	for k, q := range p.dofOf {
		if q >= 0 && p.spring[k] != 0 {
			vals[p.colPtr[q+1]-1] += p.spring[k]
		}
	}
	maxDiag := 0.0
	for j := 0; j < n; j++ {
		if d := vals[p.colPtr[j+1]-1]; d > maxDiag {
			maxDiag = d
		}
	}
	tAsm := time.Now()

	if err := p.factor(maxDiag); err != nil {
		return nil, err
	}
	tFac := time.Now()

	out := &Out{Cases: make([]CaseOut, len(p.cases))}
	b := make([]float64, n)
	for ci := range p.cases {
		if only >= 0 && ci != only {
			continue
		}
		pc := &p.cases[ci]
		co := &out.Cases[ci]
		// load vector: nodal + equivalent member loads (-T^T f_fixed)
		loads := append([]float64(nil), pc.nodal...)
		ffix := make([][6]float64, nM)
		for m := 0; m < nM; m++ {
			if pc.w[m] == 0 {
				continue
			}
			f := p.fixedEndM(m, pc.w[m], g[m].l)
			ffix[m] = f
			fg := rotate(g[m], &f, false)
			for d := 0; d < 3; d++ {
				loads[p.MI[m]*3+d] -= fg[d]
				loads[p.MJ[m]*3+d] -= fg[3+d]
			}
		}
		for k, q := range p.dofOf {
			if q >= 0 {
				b[q] = loads[k]
			}
		}
		p.solveInPlace(b)
		co.U = make([]float64, nN*3)
		for k, q := range p.dofOf {
			if q >= 0 {
				co.U[k] = b[q]
			}
		}
		// member end forces
		co.EF = make([]float64, nM*6)
		co.React = make([]float64, nN*3)
		sum := make([]float64, nN*3)
		for m := 0; m < nM; m++ {
			var ug [6]float64
			for d := 0; d < 3; d++ {
				ug[d] = co.U[p.MI[m]*3+d]
				ug[3+d] = co.U[p.MJ[m]*3+d]
			}
			ul := rotate(g[m], &ug, true)
			p.localK(m, g[m].l, &kl)
			var f [6]float64
			for r := 0; r < 6; r++ {
				s := ffix[m][r]
				for c := 0; c < 6; c++ {
					s += kl[r][c] * ul[c]
				}
				f[r] = s
			}
			copy(co.EF[m*6:], f[:])
			fg := rotate(g[m], &f, false)
			for d := 0; d < 3; d++ {
				sum[p.MI[m]*3+d] += fg[d]
				sum[p.MJ[m]*3+d] += fg[3+d]
			}
		}
		// reactions and equilibrium
		var rx, ry, scale float64
		for k := 0; k < nN; k++ {
			for d := 0; d < 3; d++ {
				if p.restr[k*3+d] {
					co.React[k*3+d] = sum[k*3+d] - pc.nodal[k*3+d]
				}
			}
			sx, sy := -p.spring[k*3]*co.U[k*3], -p.spring[k*3+1]*co.U[k*3+1] // spring reactions
			rx += co.React[k*3] + pc.nodal[k*3] + sx
			ry += co.React[k*3+1] + pc.nodal[k*3+1] + sy
			scale += math.Abs(co.React[k*3]) + math.Abs(co.React[k*3+1]) + math.Abs(pc.nodal[k*3]) + math.Abs(pc.nodal[k*3+1])
		}
		for m := 0; m < nM; m++ {
			if w := pc.w[m]; w != 0 {
				wl := w * g[m].l
				rx += -g[m].s * wl
				ry += g[m].c * wl
				scale += math.Abs(wl)
			}
		}
		co.Residual = math.Hypot(rx, ry) / math.Max(scale, 1)
	}
	tEnd := time.Now()
	out.Stats = Stats{
		Nodes: nN, Members: nM, FreeDOFs: n,
		ProfileBefore: p.profBefore, ProfileAfter: p.profAfter,
		AssembleMS: ms(tAsm.Sub(t0)), FactorMS: ms(tFac.Sub(tAsm)), SolveMS: ms(tEnd.Sub(tFac)),
	}
	return out, nil
}

func ms(d time.Duration) float64 { return float64(d.Nanoseconds()) / 1e6 }

// dot is the inner product of a and b[:len(a)]. Four independent accumulators break the floating-point
// add dependency chain, which is the bottleneck of the skyline factorization.
func dot(a, b []float64) float64 {
	b = b[:len(a)]
	var s0, s1, s2, s3 float64
	i := 0
	for ; i+4 <= len(a); i += 4 {
		s0 += a[i] * b[i]
		s1 += a[i+1] * b[i+1]
		s2 += a[i+2] * b[i+2]
		s3 += a[i+3] * b[i+3]
	}
	for ; i < len(a); i++ {
		s0 += a[i] * b[i]
	}
	return (s0 + s1) + (s2 + s3)
}

// factor performs the in-place skyline LDL^T factorization. After it, off-diagonal entries of column j
// hold U (unit upper triangular) and the diagonal holds D.
func (p *Prepared) factor(maxDiag float64) error {
	a, top, cp := p.vals, p.top, p.colPtr
	for j := 0; j < p.nFree; j++ {
		mj := top[j]
		cj := cp[j]
		for i := mj + 1; i < j; i++ {
			lo := top[i]
			if lo < mj {
				lo = mj
			}
			ci := cp[i]
			a[cj+i-mj] -= dot(a[ci+lo-top[i]:ci+i-top[i]], a[cj+lo-mj:cj+i-mj])
		}
		d := a[cp[j+1]-1]
		for i := mj; i < j; i++ {
			g := a[cj+i-mj]
			u := g / a[cp[i+1]-1]
			a[cj+i-mj] = u
			d -= u * g
		}
		if !(d > pivotTol*maxDiag) {
			return p.unstable(j)
		}
		a[cp[j+1]-1] = d
	}
	return nil
}

func (p *Prepared) unstable(dof int) error {
	for k, q := range p.dofOf {
		if q == dof {
			return modelErr(ErrUnstable, "pivot failed at node %d %s", p.NodeIDs[k/3], [3]string{"ux", "uy", "rz"}[k%3])
		}
	}
	return modelErr(ErrUnstable, "pivot failed at dof %d", dof)
}

// solveInPlace solves K x = b with the factors from factor; b is overwritten with x.
func (p *Prepared) solveInPlace(b []float64) {
	a, top, cp := p.vals, p.top, p.colPtr
	n := p.nFree
	for j := 0; j < n; j++ { // forward: U^T y = b
		mj := top[j]
		b[j] -= dot(a[cp[j]:cp[j]+j-mj], b[mj:j])
	}
	for j := 0; j < n; j++ { // D z = y
		b[j] /= a[cp[j+1]-1]
	}
	for j := n - 1; j >= 0; j-- { // back: U x = z
		mj := top[j]
		bj := b[j]
		col := a[cp[j] : cp[j]+j-mj]
		dst := b[mj:j]
		for i, u := range col {
			dst[i] -= u * bj
		}
	}
}

// StationMoments fills dst[0..10] with the bending moment M at the 11 stations of member m (the allocation-free
// counterpart of Stations, for hot paths that only need M) and returns max |M|.
func (p *Prepared) StationMoments(c, m int, ef []float64, l float64, dst []float64) float64 {
	w := p.cases[c].w[m]
	vi, mi := ef[1], ef[2]
	maxM := 0.0
	for k := 0; k < 11; k++ {
		x := l * float64(k) / 10
		v := -mi + vi*x + w*x*x/2
		dst[k] = v
		maxM = math.Max(maxM, math.Abs(v))
	}
	return maxM
}

// Stations returns N, V, M at 11 equally spaced points of member m for case c (SPEC 4.5).
func (p *Prepared) Stations(c, m int, ef []float64, l float64) []Station {
	w := p.cases[c].w[m]
	ni, vi, mi := ef[0], ef[1], ef[2]
	st := make([]Station, 11)
	for k := range st {
		x := l * float64(k) / 10
		st[k] = Station{X: x, N: -ni, V: vi + w*x, M: -mi + vi*x + w*x*x/2}
	}
	return st
}

// MemberLength returns the current length of member m.
func (p *Prepared) MemberLength(m int) float64 {
	return math.Hypot(p.X[p.MJ[m]]-p.X[p.MI[m]], p.Y[p.MJ[m]]-p.Y[p.MI[m]])
}

// ResultsJSON converts flat output to the JSON result structure.
func (p *Prepared) ResultsJSON(out *Out) *Results {
	res := &Results{Warnings: append([]any{}, p.Warns...), Stats: out.Stats}
	for c := range out.Cases {
		co := &out.Cases[c]
		cr := CaseResult{ID: p.cases[c].id, EquilibriumResidual: co.Residual,
			Displacements: make([]Displacement, len(p.NodeIDs)),
			Reactions:     []Reaction{}, Members: make([]MemberResult, len(p.MemIDs))}
		for k, id := range p.NodeIDs {
			cr.Displacements[k] = Displacement{id, co.U[k*3], co.U[k*3+1], co.U[k*3+2]}
			if p.Restrained(k, 0) || p.Restrained(k, 1) || p.Restrained(k, 2) {
				cr.Reactions = append(cr.Reactions, Reaction{id, co.React[k*3], co.React[k*3+1], co.React[k*3+2]})
			}
		}
		for m, id := range p.MemIDs {
			ef := co.EF[m*6 : m*6+6]
			cr.Members[m] = MemberResult{ID: id, EndForces: append([]float64(nil), ef...),
				Stations: p.Stations(c, m, ef, p.MemberLength(m))}
		}
		res.LoadCases = append(res.LoadCases, cr)
	}
	return res
}

// SolveModel is the convenience path: prepare, solve, build JSON results.
func SolveModel(m *Model) (*Results, error) {
	p, err := Prepare(m)
	if err != nil {
		return nil, err
	}
	out, err := p.Solve()
	if err != nil {
		return nil, err
	}
	return p.ResultsJSON(out), nil
}

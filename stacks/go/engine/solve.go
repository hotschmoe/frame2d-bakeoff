package engine

import (
	"math"
	"sort"
	"time"
)

// Options narrows what Analyze does. The zero value solves every load case.
type Options struct {
	OnlyCase string // when non-empty, solve just this load case (used by the interactive drag loop)
}

// CaseSolution is the raw numeric result of one load case. Arrays follow the sorted node and member order
// of the owning Solution.
type CaseSolution struct {
	ID        string
	Disp      []float64 // 3 per node: ux, uy, rz (restrained = 0)
	Reac      []float64 // 3 per node: fx, fy, mz (zero at unrestrained DOFs)
	EndForces []float64 // 6 per member, local, acting on the member
	W         []float64 // UDL per member (local y)
	Residual  float64
}

// Solution is the analysis output before it is shaped into JSON.
type Solution struct {
	Nodes    []Node // sorted by id
	Members  []Member
	MemI     []int32 // node index of each member's i end
	MemJ     []int32
	MemL     []float64
	Supports []bool    // 3 per node: restrained flags
	Springs  []float64 // 3 per node: spring stiffness (0 = none)
	Cases    []CaseSolution
	Warnings []Warning
	Stats    Stats
}

type memberGeom struct {
	i, j    int32
	L, c, s float64
	EA, EI  float64
	relI    bool // mz released at end i
	relJ    bool // mz released at end j
}

// solver holds the numbered DOFs and the skyline matrix.
type solver struct {
	dof   []int32 // 3 per node, free index or -1
	nfree int
	h     []int32 // column heights
	ptr   []int   // start of each column in data
	data  []float64
}

// pivotTol is the relative pivot threshold of the stability check (SPEC 4.4).
const pivotTol = 1e-12 // BENCH-EDIT:leaf

// Analyze runs the full pipeline: validate, number, assemble, factor once, solve each load case, post-process.
func Analyze(m *Model, opt Options) (*Solution, error) {
	sol, geom, err := prepare(m)
	if err != nil {
		return nil, err
	}
	nn := len(sol.Nodes)

	edges := make([][2]int32, len(geom))
	for k, g := range geom {
		edges[k] = [2]int32{g.i, g.j}
	}
	g := buildGraph(nn, edges)
	identity := make([]int32, nn)
	for i := range identity {
		identity[i] = int32(i)
	}
	order := rcmOrder(g)

	dofBefore, nBefore := numberDOFs(identity, sol.Supports)
	if nBefore == 0 {
		return nil, modelErr(ErrNoFreeDOFs, "every DOF is restrained")
	}
	_, profBefore := heights(dofBefore, nBefore, geom)
	dof, nfree := numberDOFs(order, sol.Supports)
	h, profAfter := heights(dof, nfree, geom)

	sol.Stats = Stats{Nodes: nn, Members: len(geom), FreeDOFs: nfree, ProfileBefore: profBefore, ProfileAfter: profAfter}

	t0 := time.Now()
	sv := &solver{dof: dof, nfree: nfree, h: h}
	sv.assemble(sol, geom)
	if auto := sv.zeroRotations(sol); len(auto) > 0 { // SPEC 4.7 auto-restraint
		restr := append([]bool(nil), sol.Supports...)
		for _, n := range auto {
			restr[3*n+2] = true
			sol.Warnings = append(sol.Warnings, Warning{Warning: "auto_restrained", Node: sol.Nodes[n].ID, DOF: "rz"})
		}
		dof, nfree = numberDOFs(order, restr)
		if nfree == 0 {
			return nil, modelErr(ErrNoFreeDOFs, "every DOF is restrained")
		}
		h, _ = heights(dof, nfree, geom)
		sol.Stats.FreeDOFs = nfree
		sv = &solver{dof: dof, nfree: nfree, h: h}
		sv.assemble(sol, geom)
	}
	cases := selectCases(m.LoadCases, opt.OnlyCase)
	rhs := make([][]float64, len(cases))
	wOf := make([][]float64, len(cases))
	memIx := make(map[int]int, len(sol.Members))
	for k, mem := range sol.Members {
		memIx[mem.ID] = k
	}
	nodeIx := make(map[int]int32, nn)
	for k, nd := range sol.Nodes {
		nodeIx[nd.ID] = int32(k)
	}
	for ci, lc := range cases {
		rhs[ci], wOf[ci] = buildLoads(lc, sv, geom, nodeIx, memIx)
	}
	t1 := time.Now()
	if bad := sv.factor(); bad >= 0 {
		return nil, unstableErr(sol, sv, bad)
	}
	t2 := time.Now()
	for ci, lc := range cases {
		sv.solve(rhs[ci])
		sol.Cases = append(sol.Cases, postProcess(lc, sol, sv, geom, rhs[ci], wOf[ci], nodeIx))
	}
	t3 := time.Now()
	sol.Stats.AssembleMS = ms(t1.Sub(t0))
	sol.Stats.FactorMS = ms(t2.Sub(t1))
	sol.Stats.SolveMS = ms(t3.Sub(t2))
	return sol, nil
}

// assemble allocates the skyline and adds member and spring stiffness.
func (s *solver) assemble(sol *Solution, geom []memberGeom) {
	s.allocate()
	for k := range geom {
		s.addMember(&geom[k])
	}
	for n := range sol.Nodes {
		for d := 0; d < 3; d++ {
			if f := s.dof[3*n+d]; f >= 0 {
				s.data[s.ptr[f]+int(s.h[f])] += sol.Springs[3*n+d]
			}
		}
	}
}

// zeroRotations lists nodes (by index) whose free rz has no stiffness (SPEC 4.7).
func (s *solver) zeroRotations(sol *Solution) []int {
	maxDiag := 0.0
	for j := 0; j < s.nfree; j++ {
		if d := s.data[s.ptr[j]+int(s.h[j])]; d > maxDiag {
			maxDiag = d
		}
	}
	var out []int
	for n := range sol.Nodes {
		if f := s.dof[3*n+2]; f >= 0 && s.data[s.ptr[f]+int(s.h[f])] <= pivotTol*maxDiag {
			out = append(out, n)
		}
	}
	return out
}

func ms(d time.Duration) float64 { return float64(d.Nanoseconds()) / 1e6 }

func selectCases(all []LoadCase, only string) []LoadCase {
	if only == "" {
		return all
	}
	for _, lc := range all {
		if lc.ID == only {
			return []LoadCase{lc}
		}
	}
	return nil
}

// prepare validates the model (SPEC 4.6) and builds id-sorted arrays plus member geometry.
func prepare(m *Model) (*Solution, []memberGeom, error) {
	sol := &Solution{
		Nodes:   append([]Node(nil), m.Nodes...),
		Members: append([]Member(nil), m.Members...),
	}
	sort.SliceStable(sol.Nodes, func(a, b int) bool { return sol.Nodes[a].ID < sol.Nodes[b].ID })
	sort.SliceStable(sol.Members, func(a, b int) bool { return sol.Members[a].ID < sol.Members[b].ID })
	for k := 1; k < len(sol.Nodes); k++ {
		if sol.Nodes[k].ID == sol.Nodes[k-1].ID {
			return nil, nil, modelErr(ErrDuplicateID, "duplicate node id %d", sol.Nodes[k].ID)
		}
	}
	for k := 1; k < len(sol.Members); k++ {
		if sol.Members[k].ID == sol.Members[k-1].ID {
			return nil, nil, modelErr(ErrDuplicateID, "duplicate member id %d", sol.Members[k].ID)
		}
	}
	nn := len(sol.Nodes)
	nodeIx := make(map[int]int32, nn)
	for k, nd := range sol.Nodes {
		nodeIx[nd.ID] = int32(k)
	}
	mats := make(map[string]Material, len(m.Materials))
	for _, x := range m.Materials {
		mats[x.ID] = x
	}
	secs := make(map[string]Section, len(m.Sections))
	for _, x := range m.Sections {
		secs[x.ID] = x
	}
	sol.Supports = make([]bool, 3*nn)
	for _, s := range m.Supports {
		ix, ok := nodeIx[s.Node]
		if !ok {
			return nil, nil, modelErr(ErrInvalidRef, "support references missing node %d", s.Node)
		}
		sol.Supports[3*ix] = sol.Supports[3*ix] || s.UX
		sol.Supports[3*ix+1] = sol.Supports[3*ix+1] || s.UY
		sol.Supports[3*ix+2] = sol.Supports[3*ix+2] || s.RZ
	}
	sol.Springs = make([]float64, 3*nn)
	for _, sp := range m.Springs {
		ix, ok := nodeIx[sp.Node]
		if !ok {
			return nil, nil, modelErr(ErrInvalidRef, "spring references missing node %d", sp.Node)
		}
		for d, kv := range [3]*float64{sp.KX, sp.KY, sp.KR} {
			if kv == nil {
				continue
			}
			if sol.Supports[3*int(ix)+d] {
				return nil, nil, modelErr(ErrSupportConflict, "node %d dof %d is both restrained and sprung", sp.Node, d)
			}
			sol.Springs[3*int(ix)+d] += *kv
		}
	}
	memIDs := make(map[int]bool, len(sol.Members))
	geom := make([]memberGeom, len(sol.Members))
	sol.MemI = make([]int32, len(geom))
	sol.MemJ = make([]int32, len(geom))
	sol.MemL = make([]float64, len(geom))
	for k, mem := range sol.Members {
		memIDs[mem.ID] = true
		i, okI := nodeIx[mem.I]
		j, okJ := nodeIx[mem.J]
		if !okI || !okJ {
			return nil, nil, modelErr(ErrInvalidRef, "member %d references a missing node", mem.ID)
		}
		mat, okM := mats[mem.Material]
		sec, okS := secs[mem.Section]
		if !okM || !okS {
			return nil, nil, modelErr(ErrInvalidRef, "member %d references a missing material or section", mem.ID)
		}
		geom[k] = memberGeom{i: i, j: j, EA: mat.E * sec.A, EI: mat.E * sec.I}
		if r := mem.Release; r != nil {
			geom[k].relI, geom[k].relJ = hasMZ(r.I), hasMZ(r.J)
		}
		sol.MemI[k], sol.MemJ[k] = i, j
	}
	for _, lc := range m.LoadCases {
		for _, l := range lc.Nodal {
			if _, ok := nodeIx[l.Node]; !ok {
				return nil, nil, modelErr(ErrInvalidRef, "load case %s references missing node %d", lc.ID, l.Node)
			}
		}
		for _, l := range lc.MemberUDL {
			if !memIDs[l.Member] {
				return nil, nil, modelErr(ErrInvalidRef, "load case %s references missing member %d", lc.ID, l.Member)
			}
		}
	}
	for k := range geom {
		g := &geom[k]
		a, b := sol.Nodes[g.i], sol.Nodes[g.j]
		dx, dy := b.X-a.X, b.Y-a.Y
		g.L = math.Hypot(dx, dy)
		if g.L < 1e-9 {
			return nil, nil, modelErr(ErrZeroLength, "member %d has zero length", sol.Members[k].ID)
		}
		g.c, g.s = dx/g.L, dy/g.L
		sol.MemL[k] = g.L
	}
	return sol, geom, nil
}

func hasMZ(l []string) bool {
	for _, d := range l {
		if d == "mz" {
			return true
		}
	}
	return false
}

// condense statically eliminates the released rotations from k and f (SPEC 4.7). Eliminated rows and
// columns of k and entries of f become zero.
func condense(g *memberGeom, k *[6][6]float64, f *[6]float64) {
	for _, r := range [2]int{2, 5} {
		if (r == 2 && !g.relI) || (r == 5 && !g.relJ) {
			continue
		}
		p := k[r][r]
		fr := f[r]
		for a := 0; a < 6; a++ {
			if a == r {
				continue
			}
			ka := k[a][r] / p
			for b := 0; b < 6; b++ {
				if b != r {
					k[a][b] -= ka * k[r][b]
				}
			}
			f[a] -= ka * fr
		}
		for a := 0; a < 6; a++ {
			k[a][r], k[r][a] = 0, 0
		}
		f[r] = 0
	}
}

// numberDOFs assigns free-DOF indices walking nodes in the given order (SPEC 4.3).
func numberDOFs(order []int32, restrained []bool) ([]int32, int) {
	dof := make([]int32, 3*len(order))
	next := int32(0)
	for _, n := range order {
		for d := int32(0); d < 3; d++ {
			if restrained[3*n+d] {
				dof[3*n+d] = -1
			} else {
				dof[3*n+d] = next
				next++
			}
		}
	}
	return dof, int(next)
}

// heights returns skyline column heights (j minus lowest coupled free DOF) and their sum (SPEC 4.4).
func heights(dof []int32, nfree int, geom []memberGeom) ([]int32, int) {
	low := make([]int32, nfree)
	for j := range low {
		low[j] = int32(j)
	}
	var ds [6]int32
	for k := range geom {
		g := &geom[k]
		for d := int32(0); d < 3; d++ {
			ds[d], ds[3+d] = dof[3*g.i+d], dof[3*g.j+d]
		}
		mn := int32(math.MaxInt32)
		for _, v := range ds {
			if v >= 0 && v < mn {
				mn = v
			}
		}
		for _, v := range ds {
			if v >= 0 && mn < low[v] {
				low[v] = mn
			}
		}
	}
	total := 0
	h := make([]int32, nfree)
	for j := range h {
		h[j] = int32(j) - low[j]
		total += int(h[j])
	}
	return h, total
}

func (s *solver) allocate() {
	s.ptr = make([]int, s.nfree+1)
	for j := 0; j < s.nfree; j++ {
		s.ptr[j+1] = s.ptr[j] + int(s.h[j]) + 1
	}
	s.data = make([]float64, s.ptr[s.nfree])
}

// at returns the storage index of (row r, column c) with r <= c inside the profile.
func (s *solver) at(r, c int32) int { return s.ptr[c] + int(s.h[c]) - int(c-r) }

// localK returns the 6x6 local stiffness of an Euler-Bernoulli beam-column.
func localK(g *memberGeom) [6][6]float64 {
	L := g.L
	a := g.EA / L
	b := 12 * g.EI / (L * L * L)
	c := 6 * g.EI / (L * L)
	d := 4 * g.EI / L
	e := 2 * g.EI / L
	return [6][6]float64{
		{a, 0, 0, -a, 0, 0},
		{0, b, c, 0, -b, c},
		{0, c, d, 0, -c, e},
		{-a, 0, 0, a, 0, 0},
		{0, -b, -c, 0, b, -c},
		{0, c, e, 0, -c, d},
	}
}

// rotation returns T with u_local = T * u_global.
func rotation(g *memberGeom) [6][6]float64 {
	var t [6][6]float64
	for o := 0; o < 6; o += 3 {
		t[o][o], t[o][o+1] = g.c, g.s
		t[o+1][o], t[o+1][o+1] = -g.s, g.c
		t[o+2][o+2] = 1
	}
	return t
}

// memberK is the local stiffness with end releases condensed out.
func memberK(g *memberGeom) [6][6]float64 {
	k := localK(g)
	if g.relI || g.relJ {
		var f [6]float64
		condense(g, &k, &f)
	}
	return k
}

func globalK(g *memberGeom) [6][6]float64 {
	k, t := memberK(g), rotation(g)
	var kt, out [6][6]float64
	for a := 0; a < 6; a++ { // kt = k * t
		for b := 0; b < 6; b++ {
			var sum float64
			for c := 0; c < 6; c++ {
				sum += k[a][c] * t[c][b]
			}
			kt[a][b] = sum
		}
	}
	for a := 0; a < 6; a++ { // out = t^T * kt
		for b := 0; b < 6; b++ {
			var sum float64
			for c := 0; c < 6; c++ {
				sum += t[c][a] * kt[c][b]
			}
			out[a][b] = sum
		}
	}
	return out
}

func (s *solver) addMember(g *memberGeom) {
	kg := globalK(g)
	var ds [6]int32
	for d := int32(0); d < 3; d++ {
		ds[d], ds[3+d] = s.dof[3*g.i+d], s.dof[3*g.j+d]
	}
	for a := 0; a < 6; a++ {
		if ds[a] < 0 {
			continue
		}
		for b := 0; b < 6; b++ {
			if ds[b] >= ds[a] {
				s.data[s.at(ds[a], ds[b])] += kg[a][b]
			}
		}
	}
}

// factor performs in-place skyline LDLt. Column j stores U_kj / D_k (that is L_jk) above the diagonal
// and D_j on the diagonal. It returns the failing DOF, or -1.
func (s *solver) factor() int {
	maxDiag := 0.0
	for j := 0; j < s.nfree; j++ {
		if d := s.data[s.ptr[j]+int(s.h[j])]; d > maxDiag {
			maxDiag = d
		}
	}
	data, ptr, h := s.data, s.ptr, s.h
	for j := 0; j < s.nfree; j++ {
		hj := int(h[j])
		mj := j - hj
		col := data[ptr[j] : ptr[j]+hj+1]
		for i := mj + 1; i < j; i++ {
			hi := int(h[i])
			k0 := i - hi
			if k0 < mj {
				k0 = mj
			}
			li := data[ptr[i]+hi-(i-k0) : ptr[i]+hi]
			uj := col[k0-mj : i-mj]
			col[i-mj] -= dot(li, uj)
		}
		diag := col[hj]
		for k := 0; k < hj; k++ {
			u := col[k]
			l := u / data[ptr[mj+k]+int(h[mj+k])]
			diag -= l * u
			col[k] = l
		}
		if !(diag > pivotTol*maxDiag) {
			return j
		}
		col[hj] = diag
	}
	return -1
}

// solve overwrites b (length nfree) with K^-1 b using the factorization.
func (s *solver) solve(b []float64) {
	data, ptr, h := s.data, s.ptr, s.h
	for j := 0; j < s.nfree; j++ {
		hj := int(h[j])
		col := data[ptr[j] : ptr[j]+hj]
		b[j] -= dot(col, b[j-hj:j])
	}
	for j := 0; j < s.nfree; j++ {
		b[j] /= data[ptr[j]+int(h[j])]
	}
	for j := s.nfree - 1; j >= 0; j-- {
		hj := int(h[j])
		col := data[ptr[j] : ptr[j]+hj]
		axpy(-b[j], col, b[j-hj:j])
	}
}

func unstableErr(sol *Solution, s *solver, bad int) error {
	for n := range sol.Nodes {
		for d, name := range [3]string{"ux", "uy", "rz"} {
			if int(s.dof[3*n+d]) == bad {
				return modelErr(ErrUnstable, "singular stiffness at node %d (%s): model is unstable or under-restrained", sol.Nodes[n].ID, name)
			}
		}
	}
	return modelErr(ErrUnstable, "singular stiffness at dof %d", bad)
}

// fixedEndLocal returns the local fixed-end forces acting on the member for UDL w (SPEC 4.2).
func fixedEndLocal(w, L float64) [6]float64 {
	return [6]float64{0, -w * L / 2, -w * L * L / 12, 0, -w * L / 2, w * L * L / 12}
}

// memberFixedEnd is the local fixed-end force vector, condensed for end releases.
func memberFixedEnd(g *memberGeom, w float64) [6]float64 {
	f := fixedEndLocal(w, g.L)
	if g.relI || g.relJ {
		k := localK(g)
		condense(g, &k, &f)
	}
	return f
}

// buildLoads assembles the free-DOF load vector of a case and returns the per-member UDL values.
func buildLoads(lc LoadCase, s *solver, geom []memberGeom, nodeIx map[int]int32, memIx map[int]int) (rhs, w []float64) {
	rhs = make([]float64, s.nfree)
	w = make([]float64, len(geom))
	for _, l := range lc.Nodal {
		n := nodeIx[l.Node]
		for d, v := range [3]float64{l.FX, l.FY, l.MZ} {
			if f := s.dof[3*n+int32(d)]; f >= 0 {
				rhs[f] += v
			}
		}
	}
	for _, l := range lc.MemberUDL {
		w[memIx[l.Member]] += l.W
	}
	for k := range geom {
		if w[k] == 0 {
			continue
		}
		g := &geom[k]
		f := memberFixedEnd(g, w[k])
		// equivalent nodal load = -T^T f
		for a := 0; a < 6; a += 3 {
			n := g.i
			if a == 3 {
				n = g.j
			}
			fx := -(g.c*f[a] - g.s*f[a+1])
			fy := -(g.s*f[a] + g.c*f[a+1])
			mz := -f[a+2]
			for d, v := range [3]float64{fx, fy, mz} {
				if fi := s.dof[3*n+int32(d)]; fi >= 0 {
					rhs[fi] += v
				}
			}
		}
	}
	return rhs, w
}

// postProcess expands displacements, computes member end forces, reactions and the equilibrium residual.
func postProcess(lc LoadCase, sol *Solution, s *solver, geom []memberGeom, x, w []float64, nodeIx map[int]int32) CaseSolution {
	nn := len(sol.Nodes)
	cs := CaseSolution{ID: lc.ID, Disp: make([]float64, 3*nn), Reac: make([]float64, 3*nn), EndForces: make([]float64, 6*len(geom)), W: w}
	for n := 0; n < 3*nn; n++ {
		if f := s.dof[n]; f >= 0 {
			cs.Disp[n] = x[f]
		}
	}
	sum := make([]float64, 3*nn) // member end forces in global axes summed per node DOF
	for k := range geom {
		g := &geom[k]
		kl, t := memberK(g), rotation(g)
		var ug, ul [6]float64
		copy(ug[:3], cs.Disp[3*g.i:3*g.i+3])
		copy(ug[3:], cs.Disp[3*g.j:3*g.j+3])
		for a := 0; a < 6; a++ {
			for b := 0; b < 6; b++ {
				ul[a] += t[a][b] * ug[b]
			}
		}
		ff := memberFixedEnd(g, w[k])
		ef := cs.EndForces[6*k : 6*k+6]
		for a := 0; a < 6; a++ {
			v := ff[a]
			for b := 0; b < 6; b++ {
				v += kl[a][b] * ul[b]
			}
			ef[a] = v
		}
		for a := 0; a < 6; a += 3 {
			n := g.i
			if a == 3 {
				n = g.j
			}
			sum[3*n] += g.c*ef[a] - g.s*ef[a+1]
			sum[3*n+1] += g.s*ef[a] + g.c*ef[a+1]
			sum[3*n+2] += ef[a+2]
		}
	}
	for _, l := range lc.Nodal {
		n := nodeIx[l.Node]
		sum[3*n] -= l.FX
		sum[3*n+1] -= l.FY
		sum[3*n+2] -= l.MZ
	}
	var rx, ry, rm, sx, sy, sm float64 // residual sums and their scales (moments about the origin)
	for n := 0; n < nn; n++ {
		nd := sol.Nodes[n]
		for d := 0; d < 3; d++ {
			if sol.Supports[3*n+d] {
				cs.Reac[3*n+d] = sum[3*n+d]
			}
		}
		fx, fy, mz := cs.Reac[3*n], cs.Reac[3*n+1], cs.Reac[3*n+2]
		rx, ry, rm = rx+fx, ry+fy, rm+mz+nd.X*fy-nd.Y*fx
		sx, sy, sm = sx+math.Abs(fx), sy+math.Abs(fy), sm+math.Abs(mz)+math.Abs(nd.X*fy)+math.Abs(nd.Y*fx)
	}
	add := func(px, py, pm, x0, y0 float64) {
		rx, ry, rm = rx+px, ry+py, rm+pm+x0*py-y0*px
		sx, sy, sm = sx+math.Abs(px), sy+math.Abs(py), sm+math.Abs(pm)+math.Abs(x0*py)+math.Abs(y0*px)
	}
	for _, l := range lc.Nodal {
		nd := sol.Nodes[nodeIx[l.Node]]
		add(l.FX, l.FY, l.MZ, nd.X, nd.Y)
	}
	for k := range geom {
		if w[k] == 0 {
			continue
		}
		g := &geom[k]
		a, b := sol.Nodes[g.i], sol.Nodes[g.j]
		wl := w[k] * g.L // resultant along local y = (-s, c)
		add(-g.s*wl, g.c*wl, 0, (a.X+b.X)/2, (a.Y+b.Y)/2)
	}
	cs.Residual = math.Max(math.Abs(rx)/math.Max(sx, 1), math.Max(math.Abs(ry)/math.Max(sy, 1), math.Abs(rm)/math.Max(sm, 1)))
	return cs
}

// StationCount is the number of diagram points per member (x = 0 .. L in tenths).
const StationCount = 11

// StationAt evaluates the N, V, M diagram of one member at station k (SPEC 4.5).
func StationAt(ef []float64, w, L float64, k int) Station {
	x := L * float64(k) / (StationCount - 1)
	return Station{X: x, N: -ef[0], V: ef[1] + w*x, M: -ef[2] + ef[1]*x + w*x*x/2}
}

// MaxAbsM is the largest |M| over all stations of all members in all cases.
func (s *Solution) MaxAbsM() float64 {
	best := 0.0
	for ci := range s.Cases {
		for k := range s.Members {
			if m := s.MemberMaxM(ci, k); m > best {
				best = m
			}
		}
	}
	return best
}

// MemberMaxM is the largest |M| over the stations of member k in case ci.
func (s *Solution) MemberMaxM(ci, k int) float64 {
	cs := &s.Cases[ci]
	ef := cs.EndForces[6*k : 6*k+6]
	best := 0.0
	for st := 0; st < StationCount; st++ {
		if m := math.Abs(StationAt(ef, cs.W[k], s.MemL[k], st).M); m > best {
			best = m
		}
	}
	return best
}

// Results shapes the solution into the output document of SPEC 5.2.
func (s *Solution) Results() *Results {
	r := &Results{LoadCases: make([]CaseResult, len(s.Cases)), Warnings: s.Warnings, Stats: s.Stats}
	if r.Warnings == nil {
		r.Warnings = []Warning{}
	}
	for ci := range s.Cases {
		cs := &s.Cases[ci]
		out := CaseResult{ID: cs.ID, EquilibriumResidual: cs.Residual,
			Displacements: make([]Displacement, len(s.Nodes)),
			Reactions:     []Reaction{},
			Members:       make([]MemberResult, len(s.Members))}
		for n, nd := range s.Nodes {
			out.Displacements[n] = Displacement{Node: nd.ID, UX: cs.Disp[3*n], UY: cs.Disp[3*n+1], RZ: cs.Disp[3*n+2]}
			if s.Supports[3*n] || s.Supports[3*n+1] || s.Supports[3*n+2] {
				out.Reactions = append(out.Reactions, Reaction{Node: nd.ID, FX: cs.Reac[3*n], FY: cs.Reac[3*n+1], MZ: cs.Reac[3*n+2]})
			}
		}
		for k, mem := range s.Members {
			mr := MemberResult{ID: mem.ID, Stations: make([]Station, StationCount)}
			copy(mr.EndForces[:], cs.EndForces[6*k:6*k+6])
			for st := range mr.Stations {
				mr.Stations[st] = StationAt(mr.EndForces[:], cs.W[k], s.MemL[k], st)
			}
			out.Members[k] = mr
		}
		r.LoadCases[ci] = out
	}
	return r
}

// dot returns sum a[i]*b[i] over len(a) elements, with four accumulators so the loop is not one
// long dependency chain.
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

// axpy performs y += alpha*x.
func axpy(alpha float64, x, y []float64) {
	y = y[:len(x)]
	i := 0
	for ; i+4 <= len(x); i += 4 {
		y[i] += alpha * x[i]
		y[i+1] += alpha * x[i+1]
		y[i+2] += alpha * x[i+2]
		y[i+3] += alpha * x[i+3]
	}
	for ; i < len(x); i++ {
		y[i] += alpha * x[i]
	}
}

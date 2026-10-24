package engine

import "sort"

type preparedCase struct {
	id    string
	nodal []float64 // nodes*3, global axes
	w     []float64 // per member UDL (local y)
}

// Prepared is a validated, indexed and ordered model, ready to solve repeatedly. Node
// coordinates may change between solves (SetCoord) without redoing the topology work.
type Prepared struct {
	NodeIDs []int
	X, Y    []float64
	MemIDs  []int
	MI, MJ  []int // node indices per member
	mE      []float64
	mA      []float64
	mI      []float64

	nodeIdx map[int]int
	dofOf   []int // nodes*3 -> free dof index or -1
	restr   []bool
	nFree   int
	top     []int // per free dof: first row of its skyline column
	colPtr  []int // per free dof: start of its column in the value array
	vals    []float64

	profBefore, profAfter int
	cases                 []preparedCase
}

// NumCases returns the number of load cases.
func (p *Prepared) NumCases() int { return len(p.cases) }

// CaseID returns the id of load case c.
func (p *Prepared) CaseID(c int) string { return p.cases[c].id }

// CaseW returns the UDL (member local y) of member m in case c.
func (p *Prepared) CaseW(c, m int) float64 { return p.cases[c].w[m] }

// SetCoord moves node index k.
func (p *Prepared) SetCoord(k int, x, y float64) { p.X[k], p.Y[k] = x, y }

// Restrained reports whether dof d (0..2) of node index k is restrained.
func (p *Prepared) Restrained(k, d int) bool { return p.restr[k*3+d] }

// Prepare validates the model and builds the RCM-ordered DOF numbering.
func Prepare(m *Model) (*Prepared, error) {
	p := &Prepared{nodeIdx: make(map[int]int, len(m.Nodes))}

	nodes := append([]Node(nil), m.Nodes...)
	sort.Slice(nodes, func(a, b int) bool { return nodes[a].ID < nodes[b].ID })
	for k, n := range nodes {
		if k > 0 && nodes[k-1].ID == n.ID {
			return nil, modelErr(ErrDuplicateID, "duplicate node id %d", n.ID)
		}
		p.NodeIDs = append(p.NodeIDs, n.ID)
		p.X = append(p.X, n.X)
		p.Y = append(p.Y, n.Y)
		p.nodeIdx[n.ID] = k
	}
	members := append([]Member(nil), m.Members...)
	sort.Slice(members, func(a, b int) bool { return members[a].ID < members[b].ID })
	mats := make(map[string]float64, len(m.Materials))
	for _, x := range m.Materials {
		if _, dup := mats[x.ID]; dup {
			return nil, modelErr(ErrDuplicateID, "duplicate material id %q", x.ID)
		}
		mats[x.ID] = x.E
	}
	secs := make(map[string]Section, len(m.Sections))
	for _, x := range m.Sections {
		if _, dup := secs[x.ID]; dup {
			return nil, modelErr(ErrDuplicateID, "duplicate section id %q", x.ID)
		}
		secs[x.ID] = x
	}
	memIdx := make(map[int]int, len(members))
	for k, mb := range members {
		if k > 0 && members[k-1].ID == mb.ID {
			return nil, modelErr(ErrDuplicateID, "duplicate member id %d", mb.ID)
		}
		i, okI := p.nodeIdx[mb.I]
		j, okJ := p.nodeIdx[mb.J]
		if !okI || !okJ {
			return nil, modelErr(ErrInvalidRef, "member %d references missing node", mb.ID)
		}
		e, okM := mats[mb.Material]
		s, okS := secs[mb.Section]
		if !okM || !okS {
			return nil, modelErr(ErrInvalidRef, "member %d references missing material or section", mb.ID)
		}
		p.MemIDs = append(p.MemIDs, mb.ID)
		p.MI = append(p.MI, i)
		p.MJ = append(p.MJ, j)
		p.mE = append(p.mE, e)
		p.mA = append(p.mA, s.A)
		p.mI = append(p.mI, s.I)
		memIdx[mb.ID] = k
	}

	nN, nM := len(p.NodeIDs), len(p.MemIDs)
	p.restr = make([]bool, nN*3)
	for _, s := range m.Supports {
		k, ok := p.nodeIdx[s.Node]
		if !ok {
			return nil, modelErr(ErrInvalidRef, "support references missing node %d", s.Node)
		}
		p.restr[k*3] = p.restr[k*3] || s.UX
		p.restr[k*3+1] = p.restr[k*3+1] || s.UY
		p.restr[k*3+2] = p.restr[k*3+2] || s.RZ
	}
	for _, lc := range m.LoadCases {
		pc := preparedCase{id: lc.ID, nodal: make([]float64, nN*3), w: make([]float64, nM)}
		for _, l := range lc.Nodal {
			k, ok := p.nodeIdx[l.Node]
			if !ok {
				return nil, modelErr(ErrInvalidRef, "load case %q references missing node %d", lc.ID, l.Node)
			}
			pc.nodal[k*3] += l.FX
			pc.nodal[k*3+1] += l.FY
			pc.nodal[k*3+2] += l.MZ
		}
		for _, l := range lc.MemberUDL {
			k, ok := memIdx[l.Member]
			if !ok {
				return nil, modelErr(ErrInvalidRef, "load case %q references missing member %d", lc.ID, l.Member)
			}
			pc.w[k] += l.W
		}
		p.cases = append(p.cases, pc)
	}

	// Ordering and profiles.
	edges := make([][2]int, nM)
	for k := range edges {
		edges[k] = [2]int{p.MI[k], p.MJ[k]}
	}
	identity := make([]int, nN)
	for k := range identity {
		identity[k] = k
	}
	_, _, p.profBefore = p.number(identity)
	order := rcmOrder(buildAdjacency(nN, edges))
	p.dofOf, p.nFree, p.profAfter = p.number(order)
	if p.nFree == 0 {
		return nil, modelErr(ErrNoFreeDOFs, "every DOF is restrained")
	}
	p.top, p.colPtr = p.skyline(p.dofOf, p.nFree)
	p.vals = make([]float64, p.colPtr[p.nFree])
	return p, nil
}

// number assigns free DOF indices walking nodes in the given order and returns the skyline profile.
func (p *Prepared) number(order []int) (dofOf []int, nFree, profile int) {
	dofOf = make([]int, len(p.NodeIDs)*3)
	for _, k := range order {
		for d := 0; d < 3; d++ {
			if p.restr[k*3+d] {
				dofOf[k*3+d] = -1
			} else {
				dofOf[k*3+d] = nFree
				nFree++
			}
		}
	}
	top, _ := p.skyline(dofOf, nFree)
	for j, t := range top {
		profile += j - t
	}
	return dofOf, nFree, profile
}

// skyline computes, per free DOF column j, the lowest coupled row index (top) and the column pointers.
func (p *Prepared) skyline(dofOf []int, nFree int) (top, colPtr []int) {
	top = make([]int, nFree)
	for j := range top {
		top[j] = j
	}
	var ds [6]int
	for m := range p.MemIDs {
		cnt, lo := 0, nFree
		for _, k := range [2]int{p.MI[m], p.MJ[m]} {
			for d := 0; d < 3; d++ {
				if q := dofOf[k*3+d]; q >= 0 {
					ds[cnt] = q
					cnt++
					if q < lo {
						lo = q
					}
				}
			}
		}
		for _, q := range ds[:cnt] {
			if lo < top[q] {
				top[q] = lo
			}
		}
	}
	colPtr = make([]int, nFree+1)
	for j := 0; j < nFree; j++ {
		colPtr[j+1] = colPtr[j] + (j - top[j] + 1)
	}
	return top, colPtr
}

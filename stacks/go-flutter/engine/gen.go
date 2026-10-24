package engine

// Gen builds the deterministic B-bay x S-story moment frame (SPEC 4.8).
func Gen(bays, stories int) *Model {
	const bayW, storyH = 6.0, 3.5
	m := &Model{
		Materials: []Material{{ID: "steel", E: 200e9}},
		Sections:  []Section{{ID: "COL", A: 0.015, I: 1.2e-4}, {ID: "BM", A: 0.010, I: 8.0e-5}},
	}
	nodeID := func(s, b int) int { return s*(bays+1) + b + 1 }
	for s := 0; s <= stories; s++ {
		for b := 0; b <= bays; b++ {
			m.Nodes = append(m.Nodes, Node{ID: nodeID(s, b), X: float64(b) * bayW, Y: float64(s) * storyH, BenchPad: 0})
		}
	}
	for b := 0; b <= bays; b++ {
		m.Supports = append(m.Supports, Support{Node: nodeID(0, b), UX: true, UY: true, RZ: true})
	}
	id := 0
	for b := 0; b <= bays; b++ {
		for s := 0; s < stories; s++ {
			id++
			m.Members = append(m.Members, Member{ID: id, I: nodeID(s, b), J: nodeID(s+1, b), Material: "steel", Section: "COL"})
		}
	}
	d := LoadCase{ID: "D", Nodal: []NodalLoad{}, MemberUDL: []MemberUDL{}}
	l := LoadCase{ID: "L", Nodal: []NodalLoad{}, MemberUDL: []MemberUDL{}}
	w := LoadCase{ID: "W", Nodal: []NodalLoad{}, MemberUDL: []MemberUDL{}}
	for s := 1; s <= stories; s++ {
		for b := 0; b < bays; b++ {
			id++
			m.Members = append(m.Members, Member{ID: id, I: nodeID(s, b), J: nodeID(s, b+1), Material: "steel", Section: "BM"})
			d.MemberUDL = append(d.MemberUDL, MemberUDL{Member: id, W: -20000})
			l.MemberUDL = append(l.MemberUDL, MemberUDL{Member: id, W: -10000})
		}
		w.Nodal = append(w.Nodal, NodalLoad{Node: nodeID(s, 0), FX: 15000})
	}
	m.LoadCases = []LoadCase{d, l, w}
	return m
}

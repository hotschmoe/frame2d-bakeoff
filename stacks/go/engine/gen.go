package engine

// Generate builds the deterministic B-bay x S-story moment frame (SPEC 4.8).
func Generate(bays, stories int) *Model {
	const bayW, storyH = 6.0, 3.5
	nid := func(b, s int) int { return s*(bays+1) + b + 1 }
	m := &Model{
		Materials: []Material{{ID: "steel", E: 200e9}},
		Sections:  []Section{{ID: "COL", A: 0.015, I: 1.2e-4}, {ID: "BM", A: 0.010, I: 8.0e-5}},
		Nodes:     make([]Node, 0, (bays+1)*(stories+1)),
		Members:   make([]Member, 0, (bays+1)*stories+bays*stories),
	}
	for s := 0; s <= stories; s++ {
		for b := 0; b <= bays; b++ {
			m.Nodes = append(m.Nodes, Node{ID: nid(b, s), X: bayW * float64(b), Y: storyH * float64(s)})
		}
	}
	for b := 0; b <= bays; b++ {
		m.Supports = append(m.Supports, Support{Node: nid(b, 0), UX: true, UY: true, RZ: true})
	}
	id := 1
	for b := 0; b <= bays; b++ {
		for s := 0; s < stories; s++ {
			m.Members = append(m.Members, Member{ID: id, I: nid(b, s), J: nid(b, s+1), Material: "steel", Section: "COL"})
			id++
		}
	}
	dead := LoadCase{ID: "D", Nodal: []NodalLoad{}, MemberUDL: []MemberUDL{}}
	live := LoadCase{ID: "L", Nodal: []NodalLoad{}, MemberUDL: []MemberUDL{}}
	wind := LoadCase{ID: "W", Nodal: []NodalLoad{}, MemberUDL: []MemberUDL{}}
	for s := 1; s <= stories; s++ {
		for b := 0; b < bays; b++ {
			m.Members = append(m.Members, Member{ID: id, I: nid(b, s), J: nid(b+1, s), Material: "steel", Section: "BM"})
			dead.MemberUDL = append(dead.MemberUDL, MemberUDL{Member: id, W: -20000})
			live.MemberUDL = append(live.MemberUDL, MemberUDL{Member: id, W: -10000})
			id++
		}
		wind.Nodal = append(wind.Nodal, NodalLoad{Node: nid(0, s), FX: 15000})
	}
	m.LoadCases = []LoadCase{dead, live, wind}
	return m
}

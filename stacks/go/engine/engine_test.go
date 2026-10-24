package engine

import (
	"errors"
	"math"
	"testing"
)

const (
	testE = 200e9
	testA = 0.01
	testI = 8e-5
)

func near(t *testing.T, name string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > math.Max(1e-12, 1e-9*math.Abs(want)) {
		t.Errorf("%s: got %.12g, want %.12g", name, got, want)
	}
}

// beam builds a straight chain of n equal members of total length L along +X.
func beam(n int, L float64, sup []Support, lc LoadCase) *Model {
	m := &Model{
		Materials: []Material{{ID: "steel", E: testE}},
		Sections:  []Section{{ID: "BM", A: testA, I: testI}},
		Supports:  sup,
		LoadCases: []LoadCase{lc},
	}
	for i := 0; i <= n; i++ {
		m.Nodes = append(m.Nodes, Node{ID: i + 1, X: L * float64(i) / float64(n)})
	}
	for i := 0; i < n; i++ {
		m.Members = append(m.Members, Member{ID: i + 1, I: i + 1, J: i + 2, Material: "steel", Section: "BM"})
	}
	return m
}

func solve(t *testing.T, m *Model) *Solution {
	t.Helper()
	sol, err := Analyze(m, Options{})
	if err != nil {
		t.Fatal(err)
	}
	return sol
}

func TestCantileverTipLoad(t *testing.T) {
	m := beam(1, 5, []Support{{Node: 1, UX: true, UY: true, RZ: true}},
		LoadCase{ID: "P", Nodal: []NodalLoad{{Node: 2, FY: -10000}}})
	cs := solve(t, m).Cases[0]
	near(t, "tip uy", cs.Disp[4], -0.02604166667)
	near(t, "tip rz", cs.Disp[5], -0.0078125)
	near(t, "base fy", cs.Reac[1], 10000)
	near(t, "base mz", cs.Reac[2], 50000)
	if cs.Residual > 1e-10 {
		t.Errorf("residual %g", cs.Residual)
	}
}

func TestFixedFixedUDLStations(t *testing.T) {
	m := beam(2, 5, []Support{{Node: 1, UX: true, UY: true, RZ: true}, {Node: 3, UX: true, UY: true, RZ: true}},
		LoadCase{ID: "D", MemberUDL: []MemberUDL{{Member: 1, W: -5000}, {Member: 2, W: -5000}}})
	sol := solve(t, m)
	cs := sol.Cases[0]
	near(t, "mid uy", cs.Disp[4], -0.0005086263021)
	near(t, "left mz", cs.Reac[2], 10416.66667)
	res := sol.Results()
	st := res.LoadCases[0].Members[0].Stations
	near(t, "M(0)", st[0].M, -10416.66667)
	near(t, "M(mid)", st[10].M, 5208.333333)
}

func TestGeneratedProfile(t *testing.T) {
	sol := solve(t, Generate(10, 10))
	s := sol.Stats
	if s.FreeDOFs != 330 || s.ProfileBefore != 10221 || s.ProfileAfter != 7575 {
		t.Errorf("stats %+v", s)
	}
}

func TestRCMTwoComponents(t *testing.T) {
	g := buildGraph(5, [][2]int32{{0, 1}, {1, 2}, {3, 4}, {1, 0}})
	order := rcmOrder(g)
	if len(order) != 5 {
		t.Fatalf("order %v", order)
	}
	seen := map[int32]bool{}
	for _, n := range order {
		seen[n] = true
	}
	if len(seen) != 5 {
		t.Errorf("not a permutation: %v", order)
	}
}

func TestErrors(t *testing.T) {
	fixed := []Support{{Node: 1, UX: true, UY: true, RZ: true}}
	load := LoadCase{ID: "P", Nodal: []NodalLoad{{Node: 2, FY: -1}}}
	cases := map[string]*Model{
		ErrUnstable: beam(1, 5, nil, load),
		ErrInvalidRef: func() *Model {
			m := beam(1, 5, fixed, load)
			m.Members[0].J = 99
			return m
		}(),
		ErrZeroLength: func() *Model {
			m := beam(1, 5, fixed, load)
			m.Nodes[1].X = 0
			return m
		}(),
		ErrDuplicateID: func() *Model {
			m := beam(1, 5, fixed, load)
			m.Nodes[1].ID = 1
			return m
		}(),
		ErrNoFreeDOFs: beam(1, 5, []Support{{Node: 1, UX: true, UY: true, RZ: true}, {Node: 2, UX: true, UY: true, RZ: true}}, load),
	}
	for code, m := range cases {
		_, err := Analyze(m, Options{})
		var me *ModelError
		if !errors.As(err, &me) || me.Code != code {
			t.Errorf("%s: got %v", code, err)
		}
	}
}

func TestOnlyCase(t *testing.T) {
	sol, err := Analyze(Generate(3, 3), Options{OnlyCase: "W"})
	if err != nil || len(sol.Cases) != 1 || sol.Cases[0].ID != "W" {
		t.Fatalf("got %v %v", sol, err)
	}
}

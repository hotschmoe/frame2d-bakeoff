package engine

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"reflect"
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

func BenchmarkAnalyzeDrag50(b *testing.B) {
	m := Generate(50, 50)
	opt := Options{OnlyCase: "D"}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := Analyze(m, opt); err != nil {
			b.Fatal(err)
		}
	}
}

// TestWriteJSONMatchesEncodingJSON checks the streaming encoder against encoding/json on a model with
// releases, springs, warnings and nullable stats.
func TestWriteJSONMatchesEncodingJSON(t *testing.T) {
	m := Generate(4, 3)
	m.Members[5].Release = &Release{I: []string{"mz"}}
	kx := 1e7
	m.Springs = []Spring{{Node: 7, KX: &kx}}
	sol, err := Analyze(m, Options{})
	if err != nil {
		t.Fatal(err)
	}
	res := sol.Results()
	res.Warnings = append(res.Warnings, Warning{Warning: "a\"b<c", Node: 3, DOF: "rz"})
	n := uint64(5)
	res.Stats.AllocCount = &n
	res.LoadCases[0].Displacements[0].UX = 1.5e-9
	res.LoadCases[0].Displacements[0].UY = -2e22
	var buf bytes.Buffer
	if err := res.WriteJSON(&buf); err != nil {
		t.Fatal(err)
	}
	want, _ := json.Marshal(res)
	var a, b any
	if err := json.Unmarshal(buf.Bytes(), &a); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	_ = json.Unmarshal(want, &b)
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("streamed JSON differs from encoding/json")
	}
}

func TestUnknownOnlyCase(t *testing.T) {
	_, err := Analyze(Generate(2, 2), Options{OnlyCase: "nope"})
	var me *ModelError
	if !errors.As(err, &me) || me.Code != ErrInvalidRef {
		t.Fatalf("got %v", err)
	}
}

// A node with an axial spring in series with a bar: u = F / (EA/L + k).
func TestSpringStiffness(t *testing.T) {
	k := 2e8
	m := beam(1, 5, []Support{{Node: 1, UX: true, UY: true, RZ: true}},
		LoadCase{ID: "P", Nodal: []NodalLoad{{Node: 2, FX: 1000}}})
	m.Springs = []Spring{{Node: 2, KX: &k}}
	cs := solve(t, m).Cases[0]
	near(t, "ux", cs.Disp[3], 1000/(testE*testA/5+k))
	near(t, "base fx", cs.Reac[0], -testE*testA/5*cs.Disp[3])
}

func TestSpringOnRestrainedDOF(t *testing.T) {
	k := 1.0
	m := beam(1, 5, []Support{{Node: 1, UX: true, UY: true, RZ: true}}, LoadCase{ID: "P"})
	m.Springs = []Spring{{Node: 1, KX: &k}}
	_, err := Analyze(m, Options{})
	var me *ModelError
	if !errors.As(err, &me) || me.Code != ErrSupportConflict {
		t.Fatalf("got %v", err)
	}
}

// Propped cantilever through an end release: fixed at node 1, member pinned at j, vertical support at
// node 2. M_fixed = wL^2/8 and R_prop = 3wL/8; node 2's rz has no stiffness, so it is auto-restrained.
func TestReleasePropped(t *testing.T) {
	const w, L = -4000.0, 6.0
	m := beam(1, L, []Support{{Node: 1, UX: true, UY: true, RZ: true}, {Node: 2, UY: true}},
		LoadCase{ID: "D", MemberUDL: []MemberUDL{{Member: 1, W: w}}})
	m.Members[0].Release = &Release{J: []string{"mz"}}
	sol := solve(t, m)
	cs := sol.Cases[0]
	near(t, "fixed-end mz", cs.Reac[2], -w*L*L/8)
	near(t, "prop fy", cs.Reac[4], -3*w*L/8)
	near(t, "pin end moment", cs.EndForces[5], 0)
	if len(sol.Warnings) != 1 || sol.Warnings[0].Warning != "auto_restrained" {
		t.Errorf("warnings %+v", sol.Warnings)
	}
	if cs.Residual > 1e-10 {
		t.Errorf("residual %g", cs.Residual)
	}
}

package engine

import (
	"errors"
	"math"
	"testing"
)

func cantilever(fy float64) *Model {
	return &Model{
		Materials: []Material{{ID: "s", E: 200e9}},
		Sections:  []Section{{ID: "b", A: 0.01, I: 8e-5}},
		Nodes:     []Node{{ID: 1}, {ID: 2, X: 5}},
		Supports:  []Support{{Node: 1, UX: true, UY: true, RZ: true}},
		Members:   []Member{{ID: 1, I: 1, J: 2, Material: "s", Section: "b"}},
		LoadCases: []LoadCase{{ID: "P", Nodal: []NodalLoad{{Node: 2, FY: fy}}}},
	}
}

func TestCantileverTipLoad(t *testing.T) {
	res, err := SolveModel(cantilever(-10000))
	if err != nil {
		t.Fatal(err)
	}
	tip := res.LoadCases[0].Displacements[1]
	if math.Abs(tip.UY-(-0.026041666666666668)) > 1e-12 || math.Abs(tip.RZ-(-0.0078125)) > 1e-12 {
		t.Fatalf("tip = %+v", tip)
	}
	r := res.LoadCases[0].Reactions[0]
	if math.Abs(r.FY-10000) > 1e-6 || math.Abs(r.MZ-50000) > 1e-6 {
		t.Fatalf("reaction = %+v", r)
	}
}

func TestGenProfiles(t *testing.T) {
	p, err := Prepare(Gen(10, 10))
	if err != nil {
		t.Fatal(err)
	}
	out, err := p.Solve()
	if err != nil {
		t.Fatal(err)
	}
	s := out.Stats
	if s.FreeDOFs != 330 || s.ProfileBefore != 10221 || s.ProfileAfter != 7575 {
		t.Fatalf("stats = %+v", s)
	}
	for _, c := range out.Cases {
		if c.Residual > 1e-8 {
			t.Fatalf("residual %g", c.Residual)
		}
	}
}

func code(err error) string {
	var me *ModelError
	if errors.As(err, &me) {
		return me.Code
	}
	return ""
}

func TestErrors(t *testing.T) {
	m := cantilever(-1)
	m.Supports = nil
	if _, err := SolveModel(m); code(err) != ErrUnstable {
		t.Fatalf("want unstable, got %v", err)
	}
	m = cantilever(-1)
	m.Members[0].J = 99
	if _, err := SolveModel(m); code(err) != ErrInvalidRef {
		t.Fatalf("want invalid_ref, got %v", err)
	}
	m = cantilever(-1)
	m.Nodes[1].X = 0
	if _, err := SolveModel(m); code(err) != ErrZeroLength {
		t.Fatalf("want zero_length, got %v", err)
	}
	m = cantilever(-1)
	m.Nodes = append(m.Nodes, Node{ID: 2})
	if _, err := SolveModel(m); code(err) != ErrDuplicateID {
		t.Fatalf("want duplicate_id, got %v", err)
	}
	m = cantilever(-1)
	m.Supports = append(m.Supports, Support{Node: 2, UX: true, UY: true, RZ: true})
	if _, err := SolveModel(m); code(err) != ErrNoFreeDOFs {
		t.Fatalf("want no_free_dofs, got %v", err)
	}
}

func TestSweepEndpoints(t *testing.T) {
	res, err := Sweep(Gen(3, 3), 5, 0.5, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Variants) != 5 || res.Variants[0].Scale != 0.5 || res.Variants[4].Scale != 2 {
		t.Fatalf("variants = %+v", res.Variants)
	}
	if res.Variants[0].RoofDrift <= res.Variants[4].RoofDrift {
		t.Fatal("stiffer beams must reduce drift")
	}
}

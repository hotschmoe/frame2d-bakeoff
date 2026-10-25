package zigengine

import (
	"encoding/json"
	"errors"
	"testing"
)

const cantilever = `{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
"load_cases":[{"id":"P","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}`

func TestSolveCantilever(t *testing.T) {
	out, err := SolveJSON([]byte(cantilever), true)
	if err != nil {
		t.Fatal(err)
	}
	var res struct {
		LoadCases []struct {
			Displacements []struct{ UY, RZ float64 } `json:"displacements"`
		} `json:"load_cases"`
		Stats struct {
			AllocCount *uint64 `json:"alloc_count"`
		} `json:"stats"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		t.Fatal(err)
	}
	if res.Stats.AllocCount == nil || *res.Stats.AllocCount == 0 {
		t.Fatalf("alloc stats missing: %s", out)
	}
	if len(res.LoadCases) != 1 || len(res.LoadCases[0].Displacements) != 2 {
		t.Fatalf("unexpected results: %s", out)
	}
}

func TestErrorsMapToTypes(t *testing.T) {
	var me *ModelError
	if _, err := SolveJSON([]byte(`{"nodes":[{"id":1,"x":0,"y":0}],"members":[{"id":1,"i":1,"j":9,"material":"a","section":"b"}]}`), false); !errors.As(err, &me) || me.Code != "invalid_ref" {
		t.Fatalf("want invalid_ref, got %v", err)
	}
	var br *BadRequestError
	if _, err := SolveJSON([]byte(`{"nodes":[`), false); !errors.As(err, &br) {
		t.Fatalf("want bad request, got %v", err)
	}
}

func TestGenAndSweep(t *testing.T) {
	model, err := GenJSON(3, 3)
	if err != nil {
		t.Fatal(err)
	}
	res, err := Sweep(model, 5, 0.5, 2)
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

func TestEchoLength(t *testing.T) {
	dst := make([]float64, 38103)
	Echo(dst)
	if dst[38102] != 38102 || len(EchoView(10)) != 10 {
		t.Fatal("echo mismatch")
	}
}

const badLoadRef = `{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
"nodes":[{"id":1,"x":0,"y":0}],"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],"members":[],
"load_cases":[{"id":"P","nodal":[{"node":42,"fy":-1}],"member_udl":[]}]}`

// Check validates references too (not just JSON syntax), so a model that cannot be prepared is never stored.
func TestCheckRejectsBadReferences(t *testing.T) {
	if err := Check([]byte(cantilever)); err != nil {
		t.Fatalf("valid model rejected: %v", err)
	}
	var me *ModelError
	if err := Check([]byte(badLoadRef)); !errors.As(err, &me) || me.Code != "invalid_ref" {
		t.Fatalf("want invalid_ref, got %v", err)
	}
	var br *BadRequestError
	if err := Check([]byte(`{"nodes":[`)); !errors.As(err, &br) {
		t.Fatalf("want bad request, got %v", err)
	}
}

func TestCodeNames(t *testing.T) {
	for code, want := range map[int]string{-1: "bad_request", -2: "invalid_ref", -3: "zero_length", -4: "duplicate_id",
		-5: "unstable", -6: "no_free_dofs", -7: "support_conflict", -42: "internal"} {
		if got := codeName(code); got != want {
			t.Errorf("codeName(%d) = %q, want %q", code, got, want)
		}
	}
}

func TestSweepRoofDriftStable(t *testing.T) {
	g, err := GenJSON(3, 3)
	if err != nil {
		t.Fatal(err)
	}
	res, err := Sweep(g, 5, 0.5, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Variants) != 5 || res.Variants[0].RoofDrift <= res.Variants[4].RoofDrift {
		t.Fatalf("stiffer beams must reduce drift: %+v", res.Variants)
	}
}

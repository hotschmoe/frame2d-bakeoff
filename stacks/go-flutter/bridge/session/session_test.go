package session

import (
	"math"
	"testing"
)

func TestGenSolveAndMove(t *testing.T) {
	h := Gen(2, 2)
	if h <= 0 {
		t.Fatalf("gen failed: %d", h)
	}
	defer Free(h)
	s := Get(h)
	c := s.Counts()
	if c != [3]int32{9, 10, 3} {
		t.Fatalf("counts = %v", c)
	}
	if rc := s.Solve(0); rc != 0 {
		t.Fatalf("solve rc = %d", rc)
	}
	res := s.Result()
	base := append([]float64(nil), res...)
	if st := s.Stats(); st[0] != 18 || st[6] > 1e-8 {
		t.Fatalf("stats = %v", st)
	}
	s.SetNode(8, 12.5, 7.5) // top middle-right region node
	if rc := s.Solve(0); rc != 0 {
		t.Fatal(rc)
	}
	changed := false
	for i := range base {
		if math.Abs(res[i]-base[i]) > 1e-12 {
			changed = true
		}
	}
	if !changed {
		t.Fatal("moving a node must change results")
	}
}

func TestErrors(t *testing.T) {
	if h := FromJSON([]byte(`{"nodes":[{"id":1,"x":0,"y":0}],"members":[{"id":1,"i":1,"j":9,"material":"a","section":"b"}]}`)); h != -2 {
		t.Fatalf("want invalid_ref (-2), got %d", h)
	}
	if string(LastError()) == "" {
		t.Fatal("expected an error message")
	}
}

func TestEchoLength(t *testing.T) {
	if n := len(Echo(38103)); n != 38103 {
		t.Fatalf("echo len %d", n)
	}
}

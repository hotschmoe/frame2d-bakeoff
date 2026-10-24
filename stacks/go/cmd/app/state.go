package main

import (
	"fmt"
	"math"
	"sort"
	"time"

	"frame2d/engine"
)

// view maps world metres (Y up) to canvas pixels (Y down).
type engineCase = engine.CaseSolution

const stationCount = engine.StationCount

func stationM(ef []float64, w, L float64, k int) float64 { return engine.StationAt(ef, w, L, k).M }

type view struct {
	cx, cy float64 // world point at the canvas centre
	zoom   float64 // pixels per metre
}

// state is everything the UI shows: the model, its latest solution and view settings.
type state struct {
	model *engine.Model
	sol   *engine.Solution
	err   string

	caseID      string
	showDeflect bool
	showMoment  bool
	defMult     float64 // user multiplier on the automatic deflection scale
	autoScale   float64
	maxM        float64   // largest |M| of the current case
	memMaxM     []float64 // per member max |M| of the current case
	meanLen     float64   // mean member length (m)

	v view

	solveMS  float64 // wall time of the last solve
	dragSolv bool    // last solve was a partial (drag) solve
}

func newState() *state {
	return &state{showDeflect: true, defMult: 1}
}

// setModel installs a model (sorted by id so solver and UI indices agree), solves it and fits the view.
func (s *state) setModel(m *engine.Model, viewW, viewH int) {
	sort.SliceStable(m.Nodes, func(a, b int) bool { return m.Nodes[a].ID < m.Nodes[b].ID })
	sort.SliceStable(m.Members, func(a, b int) bool { return m.Members[a].ID < m.Members[b].ID })
	s.model = m
	s.sol = nil
	if !s.hasCase(s.caseID) {
		s.caseID = ""
		if len(m.LoadCases) > 0 {
			s.caseID = m.LoadCases[0].ID
		}
	}
	s.solve(false)
	s.fit(viewW, viewH)
}

func (s *state) hasCase(id string) bool {
	if s.model == nil {
		return false
	}
	for _, lc := range s.model.LoadCases {
		if lc.ID == id {
			return true
		}
	}
	return false
}

// solve runs the engine. A partial solve only handles the selected case (used while dragging).
func (s *state) solve(partial bool) {
	if s.model == nil {
		return
	}
	only := ""
	if partial {
		only = s.caseID
	}
	t0 := time.Now()
	sol, err := engine.Analyze(s.model, engine.Options{OnlyCase: only})
	s.solveMS = float64(time.Since(t0).Nanoseconds()) / 1e6
	s.dragSolv = partial
	if err != nil {
		s.err = err.Error()
		return
	}
	s.err = ""
	s.sol = sol
	s.refreshCase(!partial)
}

// current returns the solved case matching caseID.
func (s *state) current() (int, *engine.CaseSolution) {
	if s.sol == nil {
		return -1, nil
	}
	for i := range s.sol.Cases {
		if s.sol.Cases[i].ID == s.caseID {
			return i, &s.sol.Cases[i]
		}
	}
	if len(s.sol.Cases) > 0 {
		return 0, &s.sol.Cases[0]
	}
	return -1, nil
}

// refreshCase recomputes per-member |M| maxima and, optionally, the automatic deflection scale.
func (s *state) refreshCase(rescale bool) {
	ci, cs := s.current()
	if cs == nil {
		s.memMaxM, s.maxM = s.memMaxM[:0], 0
		return
	}
	n := len(s.sol.Members)
	if cap(s.memMaxM) < n {
		s.memMaxM = make([]float64, n)
	}
	s.memMaxM = s.memMaxM[:n]
	s.maxM = 0
	for k := 0; k < n; k++ {
		m := s.sol.MemberMaxM(ci, k)
		s.memMaxM[k] = m
		s.maxM = math.Max(s.maxM, m)
	}
	sumL := 0.0
	for _, l := range s.sol.MemL {
		sumL += l
	}
	s.meanLen = sumL / math.Max(float64(n), 1)
	if rescale {
		maxD := 0.0
		for i := 0; i < len(s.sol.Nodes); i++ {
			maxD = math.Max(maxD, math.Hypot(cs.Disp[3*i], cs.Disp[3*i+1]))
		}
		x0, y0, x1, y1 := s.bounds()
		ext := math.Max(x1-x0, y1-y0)
		if maxD > 0 {
			s.autoScale = 0.05 * ext / maxD
		} else {
			s.autoScale = 1
		}
	}
}

func (s *state) selectCase(id string) {
	s.caseID = id
	if s.sol != nil {
		if _, cs := s.current(); cs == nil || cs.ID != id {
			s.solve(false)
			return
		}
		s.refreshCase(true)
	}
}

func (s *state) bounds() (x0, y0, x1, y1 float64) {
	if s.model == nil || len(s.model.Nodes) == 0 {
		return 0, 0, 1, 1
	}
	x0, y0 = math.Inf(1), math.Inf(1)
	x1, y1 = math.Inf(-1), math.Inf(-1)
	for _, n := range s.model.Nodes {
		x0, x1 = math.Min(x0, n.X), math.Max(x1, n.X)
		y0, y1 = math.Min(y0, n.Y), math.Max(y1, n.Y)
	}
	return
}

// fitZoom is the zoom that shows the whole model with a margin.
func (s *state) fitZoom(w, h int) float64 {
	x0, y0, x1, y1 := s.bounds()
	dx, dy := math.Max(x1-x0, 1e-6), math.Max(y1-y0, 1e-6)
	return 0.9 * math.Min(float64(w)/dx, float64(h)/dy)
}

func (s *state) fit(w, h int) {
	if w <= 0 || h <= 0 {
		w, h = 800, 600
	}
	x0, y0, x1, y1 := s.bounds()
	s.v = view{cx: (x0 + x1) / 2, cy: (y0 + y1) / 2, zoom: s.fitZoom(w, h)}
}

func (s *state) deflScale() float64 { return s.autoScale * s.defMult }

func (s *state) status() string {
	if s.err != "" {
		return "error: " + s.err
	}
	if s.sol == nil {
		return "no model"
	}
	st := s.sol.Stats
	kind := ""
	if s.dragSolv {
		kind = " (drag)"
	}
	return fmt.Sprintf("%d nodes, %d members, %d free DOF, profile %d | solve %.1f ms%s", st.Nodes, st.Members, st.FreeDOFs, st.ProfileAfter, s.solveMS, kind)
}

func (s *state) avgLen() float64 {
	if s.meanLen <= 0 {
		return 1
	}
	return s.meanLen
}

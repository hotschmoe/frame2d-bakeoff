// Package session is the handle-based, flat-buffer API that both bridges (c-shared for desktop,
// js/wasm for web) expose to Dart. All analysis stays in package engine; this is only marshalling.
package session

import (
	"encoding/json"
	"errors"
	"runtime"
	"sync"

	"frame2d/engine"
)

// Layout constants shared with the Dart side.
const (
	NodeStride   = 4  // id, x, y, restraint bitmask (1=ux 2=uy 4=rz)
	MemberStride = 3  // id, node index i, node index j
	ResMember    = 18 // 6 end forces, max |M|, 11 M stations
	StatCount    = 7  // free_dofs, profile_before, profile_after, assemble_ms, factor_ms, solve_ms, residual
)

// Session is one loaded model and its latest results.
type Session struct {
	model *engine.Model
	p     *engine.Prepared
	geo   []float64
	res   []float64
	stats *[StatCount]float64
	js    []byte
	pin   runtime.Pinner
	jsPin runtime.Pinner
}

var (
	mu       sync.Mutex
	sessions = map[int32]*Session{}
	nextID   int32
	lastErr  = []byte{0}
)

func init() { errPin.Pin(&lastErr[0]) }

// LastError returns the NUL-terminated message of the most recent failure.
func LastError() []byte { return lastErr }

var errPin runtime.Pinner

func setErr(err error) {
	var me *engine.ModelError
	msg := err.Error()
	if errors.As(err, &me) {
		msg = me.Code + ": " + me.Detail
	}
	errPin.Unpin()
	lastErr = append([]byte(msg), 0)
	errPin.Pin(&lastErr[0])
}

// ErrCode maps an error to the small integer codes used across the boundary.
func ErrCode(err error) int32 {
	var me *engine.ModelError
	if !errors.As(err, &me) {
		return -1
	}
	switch me.Code {
	case engine.ErrInvalidRef:
		return -2
	case engine.ErrZeroLength:
		return -3
	case engine.ErrDuplicateID:
		return -4
	case engine.ErrUnstable:
		return -5
	case engine.ErrNoFreeDOFs:
		return -6
	case engine.ErrSupportConflict:
		return -7
	}
	return -1
}

func register(m *engine.Model) (int32, error) {
	p, err := engine.Prepare(m)
	if err != nil {
		setErr(err)
		return ErrCode(err), err
	}
	s := &Session{model: m, p: p, stats: new([StatCount]float64)}
	s.buildGeometry()
	mu.Lock()
	defer mu.Unlock()
	nextID++
	sessions[nextID] = s
	return nextID, nil
}

// FromJSON loads a model; returns a handle > 0 or a negative error code.
func FromJSON(data []byte) int32 {
	var m engine.Model
	if err := json.Unmarshal(data, &m); err != nil {
		setErr(err)
		return -1
	}
	h, _ := register(&m)
	return h
}

// Gen builds a generated frame; returns a handle or a negative error code.
func Gen(b, s int) int32 {
	h, _ := register(engine.Gen(b, s))
	return h
}

// Get returns the session for a handle, or nil.
func Get(h int32) *Session {
	mu.Lock()
	defer mu.Unlock()
	return sessions[h]
}

// Free releases a session.
func Free(h int32) {
	mu.Lock()
	s := sessions[h]
	delete(sessions, h)
	mu.Unlock()
	if s != nil {
		s.pin.Unpin()
		s.jsPin.Unpin()
	}
}

func (s *Session) buildGeometry() {
	p := s.p
	nN, nM := len(p.NodeIDs), len(p.MemIDs)
	s.geo = make([]float64, nN*NodeStride+nM*MemberStride)
	for k, id := range p.NodeIDs {
		mask := 0.0
		for d := 0; d < 3; d++ {
			if p.Restrained(k, d) {
				mask += float64(int(1) << d)
			}
		}
		copy(s.geo[k*NodeStride:], []float64{float64(id), p.X[k], p.Y[k], mask})
	}
	base := nN * NodeStride
	for m, id := range p.MemIDs {
		copy(s.geo[base+m*MemberStride:], []float64{float64(id), float64(p.MI[m]), float64(p.MJ[m])})
	}
	s.res = make([]float64, nN*3+nM*ResMember)
	s.pin.Pin(&s.geo[0])
	s.pin.Pin(&s.res[0])
	s.pin.Pin(s.stats)
}

// Counts returns node, member and load case counts.
func (s *Session) Counts() [3]int32 {
	return [3]int32{int32(len(s.p.NodeIDs)), int32(len(s.p.MemIDs)), int32(s.p.NumCases())}
}

// Geometry returns the geometry buffer: nodes*NodeStride then members*MemberStride.
func (s *Session) Geometry() []float64 { return s.geo }

// Result returns the result buffer: nodes*3 displacements then members*ResMember.
func (s *Session) Result() []float64 { return s.res }

// Stats returns the statistics of the last solve.
func (s *Session) Stats() []float64 { return s.stats[:] }

// CaseIDs returns the load case ids as JSON.
func (s *Session) CaseIDs() []byte {
	ids := make([]string, s.p.NumCases())
	for c := range ids {
		ids[c] = s.p.CaseID(c)
	}
	b, _ := json.Marshal(ids)
	return b
}

// SetNode moves a node (by index) in the session.
func (s *Session) SetNode(k int, x, y float64) {
	if k < 0 || k >= len(s.p.NodeIDs) {
		return
	}
	s.p.SetCoord(k, x, y)
	s.model.Nodes[s.modelIndex(k)].X, s.model.Nodes[s.modelIndex(k)].Y = x, y
	s.geo[k*NodeStride+1], s.geo[k*NodeStride+2] = x, y
}

func (s *Session) modelIndex(k int) int {
	id := s.p.NodeIDs[k]
	if k < len(s.model.Nodes) && s.model.Nodes[k].ID == id {
		return k
	}
	for i := range s.model.Nodes {
		if s.model.Nodes[i].ID == id {
			return i
		}
	}
	return 0
}

// Solve solves load case c and fills the result buffer. Returns 0 or a negative error code.
func (s *Session) Solve(c int) int32 {
	if c < 0 || c >= s.p.NumCases() {
		c = 0
	}
	out, err := s.p.SolveCase(c)
	if err != nil {
		setErr(err)
		return ErrCode(err)
	}
	co := out.Cases[c]
	nN := len(s.p.NodeIDs)
	copy(s.res, co.U)
	for m := range s.p.MemIDs {
		row := s.res[nN*3+m*ResMember : nN*3+(m+1)*ResMember]
		ef := co.EF[m*6 : m*6+6]
		copy(row, ef)
		maxM := s.p.StationMoments(c, m, ef, s.p.MemberLength(m), row[7:18])
		row[6] = maxM
	}
	st := out.Stats
	*s.stats = [StatCount]float64{float64(st.FreeDOFs), float64(st.ProfileBefore), float64(st.ProfileAfter),
		st.AssembleMS, st.FactorMS, st.SolveMS, co.Residual}
	return 0
}

// ToJSON serializes the current model (with moved nodes).
func (s *Session) ToJSON() []byte {
	b, _ := json.Marshal(s.model)
	s.jsPin.Unpin()
	s.js = b
	if len(b) > 0 {
		s.jsPin.Pin(&b[0])
	}
	return b
}

var echoBuf []float64
var echoPin runtime.Pinner

// Echo returns n float64 values for the boundary transfer benchmark.
func Echo(n int) []float64 {
	if len(echoBuf) != n {
		echoPin.Unpin()
		echoBuf = make([]float64, n)
		for i := range echoBuf {
			echoBuf[i] = float64(i)
		}
		if n > 0 {
			echoPin.Pin(&echoBuf[0])
		}
	}
	return echoBuf
}

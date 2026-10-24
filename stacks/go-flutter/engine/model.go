// Package engine is the Frame2D analysis engine: model types, validation, RCM ordering,
// skyline LDL^T solver and post-processing (SPEC section 4).
package engine

import "fmt"

// Material is an elastic material (Pa).
type Material struct {
	ID string  `json:"id"`
	E  float64 `json:"E"`
}

// Section holds area (m^2) and second moment of area (m^4).
type Section struct {
	ID string  `json:"id"`
	A  float64 `json:"A"`
	I  float64 `json:"I"`
}

// Node is a joint with 3 DOF (ux, uy, rz).
type Node struct {
	ID       int     `json:"id"`
	X        float64 `json:"x"`
	Y        float64 `json:"y"`
	BenchPad uint32  `json:"-"` // BENCH-EDIT:struct
}

// Support restrains DOFs of a node.
type Support struct {
	Node int  `json:"node"`
	UX   bool `json:"ux"`
	UY   bool `json:"uy"`
	RZ   bool `json:"rz"`
}

// Member is a prismatic Euler-Bernoulli member from node I to node J.
type Member struct {
	ID       int    `json:"id"`
	I        int    `json:"i"`
	J        int    `json:"j"`
	Material string `json:"material"`
	Section  string `json:"section"`
}

// NodalLoad is a load in global axes.
type NodalLoad struct {
	Node int     `json:"node"`
	FX   float64 `json:"fx"`
	FY   float64 `json:"fy"`
	MZ   float64 `json:"mz"`
}

// MemberUDL is a uniform load in member local y over the full length.
type MemberUDL struct {
	Member int     `json:"member"`
	W      float64 `json:"w"`
}

// LoadCase groups nodal loads and member UDLs.
type LoadCase struct {
	ID        string      `json:"id"`
	Nodal     []NodalLoad `json:"nodal"`
	MemberUDL []MemberUDL `json:"member_udl"`
}

// Model is the input JSON document (SPEC 5.1).
type Model struct {
	Materials []Material `json:"materials"`
	Sections  []Section  `json:"sections"`
	Nodes     []Node     `json:"nodes"`
	Supports  []Support  `json:"supports"`
	Members   []Member   `json:"members"`
	LoadCases []LoadCase `json:"load_cases"`
}

// Error codes (SPEC 4.6).
const (
	ErrInvalidRef  = "invalid_ref"
	ErrZeroLength  = "zero_length"
	ErrDuplicateID = "duplicate_id"
	ErrUnstable    = "unstable"
	ErrNoFreeDOFs  = "no_free_dofs"
)

// ModelError is a validation or solve failure caused by the model.
type ModelError struct {
	Code   string `json:"error"`
	Detail string `json:"detail"`
}

func (e *ModelError) Error() string { return e.Code + ": " + e.Detail }

func modelErr(code, format string, args ...any) *ModelError {
	return &ModelError{Code: code, Detail: fmt.Sprintf(format, args...)}
}

// Results is the output JSON document (SPEC 5.2).
type Results struct {
	LoadCases []CaseResult `json:"load_cases"`
	Warnings  []any        `json:"warnings"`
	Stats     Stats        `json:"stats"`
}

// CaseResult holds the results of one load case.
type CaseResult struct {
	ID                  string         `json:"id"`
	Displacements       []Displacement `json:"displacements"`
	Reactions           []Reaction     `json:"reactions"`
	Members             []MemberResult `json:"members"`
	EquilibriumResidual float64        `json:"equilibrium_residual"`
}

// Displacement is a node displacement.
type Displacement struct {
	Node int     `json:"node"`
	UX   float64 `json:"ux"`
	UY   float64 `json:"uy"`
	RZ   float64 `json:"rz"`
}

// Reaction is a support reaction in global axes.
type Reaction struct {
	Node int     `json:"node"`
	FX   float64 `json:"fx"`
	FY   float64 `json:"fy"`
	MZ   float64 `json:"mz"`
}

// MemberResult holds end forces and stations of a member.
type MemberResult struct {
	ID        int       `json:"id"`
	EndForces []float64 `json:"end_forces"`
	Stations  []Station `json:"stations"`
}

// Station is a diagram point.
type Station struct {
	X float64 `json:"x"`
	N float64 `json:"N"`
	V float64 `json:"V"`
	M float64 `json:"M"`
}

// Stats are solve statistics. Alloc fields are null unless the CLI fills them.
type Stats struct {
	Nodes         int     `json:"nodes"`
	Members       int     `json:"members"`
	FreeDOFs      int     `json:"free_dofs"`
	ProfileBefore int     `json:"profile_before"`
	ProfileAfter  int     `json:"profile_after"`
	AssembleMS    float64 `json:"assemble_ms"`
	FactorMS      float64 `json:"factor_ms"`
	SolveMS       float64 `json:"solve_ms"`
	AllocCount    *uint64 `json:"alloc_count"`
	AllocBytes    *uint64 `json:"alloc_bytes"`
	PeakHeapBytes *uint64 `json:"peak_heap_bytes"`
}

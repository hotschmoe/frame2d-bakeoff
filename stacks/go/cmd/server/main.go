// Command server is the Frame2D HTTP server (SPEC 5.4).
package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync"

	_ "modernc.org/sqlite"

	"frame2d/engine"
)

const maxBody = 64 << 20

const serverTag = "x-frame2d: a" // BENCH-EDIT:server

type server struct {
	db *sql.DB
}

func main() {
	addr := os.Getenv("FRAME2D_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	dbPath := os.Getenv("FRAME2D_DB")
	if dbPath == "" {
		dbPath = "frame2d.sqlite"
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS models (id TEXT PRIMARY KEY, body BLOB NOT NULL)`); err != nil {
		log.Fatal(err)
	}
	s := &server{db: db}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.health)
	mux.HandleFunc("POST /solve", s.solve)
	mux.HandleFunc("POST /models", s.putModel)
	mux.HandleFunc("GET /models/{id}", s.getModel)
	mux.HandleFunc("POST /models/{id}/solve", s.solveStored)
	mux.HandleFunc("POST /sweep", s.sweep)
	log.Printf("frame2d server listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, tag(mux)))
}

// tag adds the benchmarked response header to every response.
func tag(next http.Handler) http.Handler {
	name, value, _ := strings.Cut(serverTag, ": ")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(name, value)
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// fail maps an error to HTTP: model errors are 422 with the error JSON, anything else 400/500.
func fail(w http.ResponseWriter, err error) {
	var me *engine.ModelError
	switch {
	case errors.As(err, &me):
		writeJSON(w, http.StatusUnprocessableEntity, me)
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad_request", "detail": err.Error()})
	}
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	return io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
}

func (s *server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func solveModel(m *engine.Model) (*engine.Results, error) {
	sol, err := engine.Analyze(m, engine.Options{})
	if err != nil {
		return nil, err
	}
	return sol.Results(), nil
}

func (s *server) solve(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(w, r)
	if err != nil {
		fail(w, err)
		return
	}
	m, err := engine.ParseModel(body)
	if err != nil {
		fail(w, err)
		return
	}
	res, err := solveModel(m)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *server) putModel(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(w, r)
	if err != nil {
		fail(w, err)
		return
	}
	if _, err := engine.ParseModel(body); err != nil {
		fail(w, err)
		return
	}
	var raw [8]byte
	_, _ = rand.Read(raw[:])
	id := hex.EncodeToString(raw[:])
	if _, err := s.db.Exec(`INSERT INTO models (id, body) VALUES (?, ?)`, id, body); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "storage", "detail": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
}

// load fetches a stored model body; ok is false when the id is unknown.
func (s *server) load(id string) (body []byte, ok bool, err error) {
	err = s.db.QueryRow(`SELECT body FROM models WHERE id = ?`, id).Scan(&body)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	return body, err == nil, err
}

func (s *server) getModel(w http.ResponseWriter, r *http.Request) {
	body, ok, err := s.load(r.PathValue("id"))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "storage", "detail": err.Error()})
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such model"})
		return
	}
	w.Header().Set("content-type", "application/json")
	_, _ = w.Write(body)
}

func (s *server) solveStored(w http.ResponseWriter, r *http.Request) {
	body, ok, err := s.load(r.PathValue("id"))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "storage", "detail": err.Error()})
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such model"})
		return
	}
	m, err := engine.ParseModel(body)
	if err != nil {
		fail(w, err)
		return
	}
	res, err := solveModel(m)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

type sweepRequest struct {
	Model      *engine.Model `json:"model"`
	ModelID    string        `json:"model_id"`
	Variants   int           `json:"variants"`
	BeamIScale [2]float64    `json:"beam_I_scale"`
}

type sweepVariant struct {
	Scale     float64 `json:"scale"`
	RoofDrift float64 `json:"roof_drift_W"`
	MaxAbsM   float64 `json:"max_abs_M"`
}

type sweepResult struct {
	Variants []sweepVariant `json:"variants"`
	Envelope struct {
		MaxRoofDrift float64 `json:"max_roof_drift_W"`
		MaxAbsM      float64 `json:"max_abs_M"`
	} `json:"envelope"`
}

func (s *server) sweep(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(w, r)
	if err != nil {
		fail(w, err)
		return
	}
	var req sweepRequest
	if err := json.Unmarshal(body, &req); err != nil {
		fail(w, err)
		return
	}
	if req.Model == nil && req.ModelID != "" {
		stored, ok, err := s.load(req.ModelID)
		if err != nil || !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found", "detail": "no such model"})
			return
		}
		if req.Model, err = engine.ParseModel(stored); err != nil {
			fail(w, err)
			return
		}
	}
	if req.Model == nil || req.Variants < 1 {
		fail(w, errors.New("sweep needs a model (or model_id) and variants >= 1"))
		return
	}
	res, err := runSweep(req)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// runSweep solves every variant concurrently, one goroutine per core pulling variant indices.
func runSweep(req sweepRequest) (*sweepResult, error) {
	lo, hi := req.BeamIScale[0], req.BeamIScale[1]
	n := req.Variants
	out := &sweepResult{Variants: make([]sweepVariant, n)}
	top := topLeftNode(req.Model)

	jobs := make(chan int)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var firstErr error
	for range runtime.NumCPU() {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for k := range jobs {
				scale := lo
				if n > 1 {
					scale = lo + (hi-lo)*float64(k)/float64(n-1)
				}
				v, err := solveVariant(req.Model, scale, top)
				if err != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					mu.Unlock()
					continue
				}
				out.Variants[k] = v
			}
		}()
	}
	for k := 0; k < n; k++ {
		jobs <- k
	}
	close(jobs)
	wg.Wait()
	if firstErr != nil {
		return nil, firstErr
	}
	for k, v := range out.Variants {
		if k == 0 || v.RoofDrift > out.Envelope.MaxRoofDrift {
			out.Envelope.MaxRoofDrift = v.RoofDrift
		}
		if v.MaxAbsM > out.Envelope.MaxAbsM {
			out.Envelope.MaxAbsM = v.MaxAbsM
		}
	}
	return out, nil
}

// topLeftNode is the node with the greatest y, ties broken by least x then lowest id.
func topLeftNode(m *engine.Model) int {
	best := -1
	for k, nd := range m.Nodes {
		if best < 0 {
			best = k
			continue
		}
		b := m.Nodes[best]
		if nd.Y > b.Y || (nd.Y == b.Y && (nd.X < b.X || (nd.X == b.X && nd.ID < b.ID))) {
			best = k
		}
	}
	if best < 0 {
		return 0
	}
	return m.Nodes[best].ID
}

func solveVariant(base *engine.Model, scale float64, topID int) (sweepVariant, error) {
	m := *base // shallow copy; only Sections is replaced
	m.Sections = append([]engine.Section(nil), base.Sections...)
	for k := range m.Sections {
		if m.Sections[k].ID == "BM" {
			m.Sections[k].I *= scale
		}
	}
	sol, err := engine.Analyze(&m, engine.Options{})
	if err != nil {
		return sweepVariant{}, err
	}
	v := sweepVariant{Scale: scale, MaxAbsM: sol.MaxAbsM()}
	for ci, cs := range sol.Cases {
		if cs.ID != "W" {
			continue
		}
		for n, nd := range sol.Nodes {
			if nd.ID == topID {
				v.RoofDrift = sol.Cases[ci].Disp[3*n]
			}
		}
	}
	return v, nil
}

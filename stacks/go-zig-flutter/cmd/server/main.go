// Command server is the Frame2D HTTP server (SPEC 5.4). HTTP and SQLite are Go; every model is parsed,
// analysed and serialized by the Zig engine through cgo. `server bench-boundary` measures the Go -> Zig call cost.
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
	"strings"
	"time"

	_ "modernc.org/sqlite"

	zigengine "frame2d/bridge/zig"
)

const serverHeader = "x-frame2d: a" // BENCH-EDIT:server

const maxBody = 64 << 20

type server struct{ db *sql.DB }

func main() {
	if len(os.Args) > 1 && os.Args[1] == "bench-boundary" {
		benchBoundary()
		return
	}
	addr := os.Getenv("FRAME2D_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	path := os.Getenv("FRAME2D_DB")
	if path == "" {
		path = ":memory:"
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(1) // keeps :memory: coherent and serializes writers
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
	log.Fatal(http.ListenAndServe(addr, header(mux)))
}

func header(next http.Handler) http.Handler {
	k, v, _ := strings.Cut(serverHeader, ": ")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(k, v)
		next.ServeHTTP(w, r)
	})
}

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func replyErr(w http.ResponseWriter, err error) {
	var me *zigengine.ModelError
	var br *zigengine.BadRequestError
	switch {
	case errors.As(err, &me):
		reply(w, http.StatusUnprocessableEntity, me)
	case errors.As(err, &br):
		reply(w, http.StatusBadRequest, map[string]string{"error": "bad_request", "detail": br.Detail})
	default:
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			reply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "too_large", "detail": err.Error()})
			return
		}
		reply(w, http.StatusBadRequest, map[string]string{"error": "bad_request", "detail": err.Error()})
	}
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	return io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
}

func (s *server) health(w http.ResponseWriter, r *http.Request) {
	reply(w, 200, map[string]bool{"ok": true})
}

func (s *server) solveBytes(w http.ResponseWriter, body []byte) {
	res, err := zigengine.SolveJSON(body, false)
	if err != nil {
		replyErr(w, err)
		return
	}
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(200)
	_, _ = w.Write(res)
}

func (s *server) solve(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(w, r)
	if err != nil {
		replyErr(w, err)
		return
	}
	s.solveBytes(w, body)
}

func (s *server) putModel(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(w, r)
	if err != nil {
		replyErr(w, err)
		return
	}
	if err := zigengine.Check(body); err != nil {
		replyErr(w, err)
		return
	}
	var raw [8]byte
	_, _ = rand.Read(raw[:])
	id := hex.EncodeToString(raw[:])
	if _, err := s.db.Exec(`INSERT INTO models (id, body) VALUES (?, ?)`, id, body); err != nil {
		reply(w, 500, map[string]string{"error": "internal", "detail": err.Error()})
		return
	}
	reply(w, 201, map[string]string{"id": id})
}

func (s *server) load(id string) ([]byte, error) {
	var body []byte
	err := s.db.QueryRow(`SELECT body FROM models WHERE id = ?`, id).Scan(&body)
	return body, err
}

func (s *server) getModel(w http.ResponseWriter, r *http.Request) {
	body, err := s.load(r.PathValue("id"))
	if err != nil {
		reply(w, 404, map[string]string{"error": "not_found", "detail": "no such model"})
		return
	}
	w.Header().Set("content-type", "application/json")
	_, _ = w.Write(body)
}

func (s *server) solveStored(w http.ResponseWriter, r *http.Request) {
	body, err := s.load(r.PathValue("id"))
	if err != nil {
		reply(w, 404, map[string]string{"error": "not_found", "detail": "no such model"})
		return
	}
	s.solveBytes(w, body)
}

type sweepReq struct {
	Model     json.RawMessage `json:"model"`
	ModelID   string          `json:"model_id"`
	Variants  int             `json:"variants"`
	BeamIScle [2]float64      `json:"beam_I_scale"`
}

func (s *server) sweep(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(w, r)
	if err != nil {
		replyErr(w, err)
		return
	}
	var req sweepReq
	if err := json.Unmarshal(body, &req); err != nil {
		replyErr(w, err)
		return
	}
	m := []byte(req.Model)
	if len(m) == 0 || string(m) == "null" {
		stored, err := s.load(req.ModelID)
		if err != nil {
			reply(w, 404, map[string]string{"error": "not_found", "detail": "no such model"})
			return
		}
		m = stored
	}
	res, err := zigengine.Sweep(m, req.Variants, req.BeamIScle[0], req.BeamIScle[1])
	if err != nil {
		replyErr(w, err)
		return
	}
	reply(w, 200, res)
}

// benchBoundary measures the cgo boundary Go -> Zig (SPEC 5.5 `boundary`): 1,000,000 no-op calls, then 1,000
// calls that return 38,103 f64 values, copied into a Go slice (and, separately, viewed zero-copy).
func benchBoundary() {
	const noopCalls, echoCalls, n = 1_000_000, 1_000, 38103
	t0 := time.Now()
	for i := 0; i < noopCalls; i++ {
		zigengine.Noop()
	}
	noopNS := float64(time.Since(t0).Nanoseconds()) / noopCalls
	dst := make([]float64, n)
	t0 = time.Now()
	for i := 0; i < echoCalls; i++ {
		zigengine.Echo(dst)
	}
	copyUS := float64(time.Since(t0).Nanoseconds()) / echoCalls / 1e3
	sink := 0.0
	t0 = time.Now()
	for i := 0; i < echoCalls; i++ {
		sink += zigengine.EchoView(n)[i]
	}
	viewUS := float64(time.Since(t0).Nanoseconds()) / echoCalls / 1e3
	out, _ := json.Marshal(map[string]any{"mode": "boundary", "noop_ns": noopNS, "transfer_us": copyUS,
		"mechanism": "memcpy (cgo call, copy into Go slice)", "transfer_view_us": viewUS, "check": sink + dst[n-1]})
	os.Stdout.WriteString("BENCH " + string(out) + "\n")
}

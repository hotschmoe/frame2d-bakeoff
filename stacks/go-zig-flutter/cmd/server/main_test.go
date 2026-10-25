package main

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

const cantilever = `{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
"load_cases":[{"id":"P","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}`

const badRef = `{"materials":[],"sections":[],"nodes":[{"id":1,"x":0,"y":0}],"supports":[{"node":1,"ux":true}],
"members":[{"id":1,"i":1,"j":99,"material":"s","section":"b"}],"load_cases":[]}`

func newTestServer(t *testing.T) http.Handler {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE models (id TEXT PRIMARY KEY, body BLOB NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	s := &server{db: db}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /solve", s.solve)
	mux.HandleFunc("POST /models", s.putModel)
	mux.HandleFunc("GET /models/{id}", s.getModel)
	mux.HandleFunc("POST /models/{id}/solve", s.solveStored)
	return mux
}

func do(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(method, path, strings.NewReader(body)))
	return w
}

// SPEC 5.4: model errors are 422 with the error JSON, malformed documents 400, unknown ids 404.
func TestStatusMapping(t *testing.T) {
	h := newTestServer(t)
	for _, c := range []struct {
		name, method, path, body string
		want                     int
	}{
		{"solve ok", "POST", "/solve", cantilever, 200},
		{"invalid_ref", "POST", "/solve", badRef, 422},
		{"malformed json", "POST", "/solve", `{"nodes":[`, 400},
		{"store invalid model", "POST", "/models", badRef, 422},
		{"store malformed", "POST", "/models", `nope`, 400},
		{"missing model", "GET", "/models/nope", "", 404},
		{"solve missing", "POST", "/models/nope/solve", "", 404},
	} {
		if got := do(h, c.method, c.path, c.body).Code; got != c.want {
			t.Errorf("%s: status %d, want %d", c.name, got, c.want)
		}
	}
}

func TestStoreRoundTrip(t *testing.T) {
	h := newTestServer(t)
	w := do(h, "POST", "/models", cantilever)
	if w.Code != 201 {
		t.Fatalf("store: %d %s", w.Code, w.Body)
	}
	id := strings.Split(w.Body.String(), `"`)[3]
	if got := do(h, "GET", "/models/"+id, "").Body.String(); got != cantilever {
		t.Errorf("stored body changed: %q", got)
	}
	if got := do(h, "POST", "/models/"+id+"/solve", "").Code; got != 200 {
		t.Errorf("stored solve: %d", got)
	}
}

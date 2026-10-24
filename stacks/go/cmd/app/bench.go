package main

import (
	"fmt"
	"math"
	"sort"
	"time"

	"frame2d/engine"
)

const benchFrames = 600

// benchRun drives the SPEC 5.5 bench modes from the frame loop.
type benchRun struct {
	mode    string
	frame   int
	last    time.Time
	frameMS []float64
	solveMS []float64
	node    int // node index moved by the drag bench
	bx, by  float64
	fitZoom float64
	x0, x1  float64
	done    bool
}

// newBench prepares the model for the mode. It runs before the window exists, so that the
// startup measurement includes model generation and the first solve.
func newBench(u *ui, mode string) *benchRun {
	b := &benchRun{mode: mode}
	switch mode {
	case "drag":
		const bays, stories = 50, 50
		u.st.caseID = "D"
		u.generate(bays, stories)
		b.node = stories*(bays+1) + bays/2 // index of id S*(B+1)+B/2+1
		n := u.st.model.Nodes[b.node]
		b.bx, b.by = n.X, n.Y
		u.cv.selNode = b.node
		u.deflBox.Value = true
	case "render":
		u.generate(200, 200)
		u.deflBox.Value, u.momBox.Value = false, true
		b.x0, _, b.x1, _ = u.st.bounds()
	case "startup":
		u.generate(50, 50)
	default: // "ready" and anything else: the normal start state
		u.generate(10, 10)
	}
	u.st.showDeflect, u.st.showMoment = u.deflBox.Value, u.momBox.Value
	return b
}

func (b *benchRun) wantsFrames() bool {
	return !b.done && (b.mode == "drag" || b.mode == "render")
}

// before runs at the top of each frame: it records the frame interval and applies this frame's input.
func (b *benchRun) before(u *ui, start time.Time) {
	if b.done {
		return
	}
	switch b.mode {
	case "drag", "render":
	default:
		return
	}
	if b.frame > 0 {
		b.frameMS = append(b.frameMS, float64(start.Sub(b.last).Nanoseconds())/1e6)
	}
	b.last = start
	if b.frame >= benchFrames {
		b.finish(u)
		return
	}
	t := float64(b.frame) / benchFrames
	switch b.mode {
	case "drag":
		th := 2 * math.Pi * t
		n := &u.st.model.Nodes[b.node]
		n.X, n.Y = b.bx+0.5*math.Cos(th), b.by+0.5*math.Sin(th)
		u.st.solve(true)
		b.solveMS = append(b.solveMS, u.st.solveMS)
	case "render":
		if b.fitZoom == 0 {
			b.fitZoom = u.st.fitZoom(u.cv.size.X, u.cv.size.Y)
		}
		z := 1 + 7*(1-math.Abs(2*t-1)) // 1x -> 8x -> 1x
		_, y0, _, y1 := u.st.bounds()
		cy := (y0 + y1) / 2
		u.st.v = view{cx: b.x0 + t*(b.x1-b.x0), cy: cy, zoom: b.fitZoom * z}
	}
	b.frame++
}

// after runs once the frame has been submitted.
func (b *benchRun) after(u *ui) {
	if b.done {
		return
	}
	switch b.mode {
	case "startup":
		emit(fmt.Sprintf(`BENCH {"mode":"startup","first_frame_ms":%.2f}`, sinceProcessStartMS()))
		b.finish(u)
	case "ready":
		emit(fmt.Sprintf(`BENCH {"mode":"ready","tti_ms":%.2f}`, sinceProcessStartMS()))
		b.finish(u)
	}
}

func (b *benchRun) finish(u *ui) {
	if b.done {
		return
	}
	b.done = true
	switch b.mode {
	case "drag":
		emit(fmt.Sprintf(`BENCH {"mode":"drag","p50":%.3f,"p95":%.3f,"p99":%.3f,"max":%.3f,"solve_p50":%.3f,"lag_max":0,"rss_mb":%.1f}`,
			pct(b.frameMS, 0.50), pct(b.frameMS, 0.95), pct(b.frameMS, 0.99), pct(b.frameMS, 1), pct(b.solveMS, 0.50), rssMB()))
	case "render":
		emit(fmt.Sprintf(`BENCH {"mode":"render","p50":%.3f,"p95":%.3f,"p99":%.3f,"max":%.3f,"rss_mb":%.1f}`,
			pct(b.frameMS, 0.50), pct(b.frameMS, 0.95), pct(b.frameMS, 0.99), pct(b.frameMS, 1), rssMB()))
	}
	exitProcess()
}

// pct is the nearest-rank percentile of v (p in 0..1).
func pct(v []float64, p float64) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	i := int(math.Ceil(p*float64(len(s)))) - 1
	if i < 0 {
		i = 0
	}
	return s[i]
}

// The Go engine is compiled into the app, so there is no language boundary. The boundary mode
// still times the same call shapes in-process: a no-op call and an n-float result.
//
//go:noinline
func noop() {}

var sink []float64

func runBoundary() {
	const calls, echoCalls, echoN = 1_000_000, 1000, 38103
	t0 := time.Now()
	for i := 0; i < calls; i++ {
		noop()
	}
	noopNS := float64(time.Since(t0).Nanoseconds()) / calls
	t0 = time.Now()
	for i := 0; i < echoCalls; i++ {
		sink = engine.Echo(echoN)
	}
	transferUS := float64(time.Since(t0).Nanoseconds()) / 1e3 / echoCalls
	emit(fmt.Sprintf(`BENCH {"mode":"boundary","noop_ns":%.2f,"transfer_us":%.2f,"mechanism":"in-process Go call, no boundary (fresh []float64 per call)"}`, noopNS, transferUS))
}

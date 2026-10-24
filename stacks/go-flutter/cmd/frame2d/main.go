// Command frame2d is the Frame2D CLI: solve, gen, bench (SPEC 5.3).
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"time"

	"frame2d/engine"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var code int
	switch os.Args[1] {
	case "solve":
		code = cmdSolve(os.Args[2:])
	case "gen":
		code = cmdGen(os.Args[2:])
	case "bench":
		code = cmdBench(os.Args[2:])
	default:
		usage()
	}
	os.Exit(code)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: frame2d solve <model.json> [-o results.json] | gen <B> <S> [-o model.json] | bench <B> <S> [--reps N]")
	os.Exit(1)
}

func fail(err error) int {
	var me *engine.ModelError
	if errors.As(err, &me) {
		_ = json.NewEncoder(os.Stdout).Encode(me)
		return 2
	}
	fmt.Fprintln(os.Stderr, "error:", err)
	return 1
}

// splitArgs separates positional arguments from flags so flags may come after positionals.
func splitArgs(fs *flag.FlagSet, args []string) ([]string, error) {
	var pos []string
	for len(args) > 0 {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) > 0 {
			pos = append(pos, args[0])
			args = args[1:]
		}
	}
	return pos, nil
}

func writeJSON(path string, v any) error {
	f := os.Stdout
	if path != "" {
		var err error
		if f, err = os.Create(path); err != nil {
			return err
		}
		defer f.Close()
	}
	w := bufio.NewWriterSize(f, 1<<20)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		return err
	}
	return w.Flush()
}

// memSampler tracks the peak HeapInuse while a solve runs.
type memSampler struct {
	stop chan struct{}
	wg   sync.WaitGroup
	peak uint64
}

func startSampler() *memSampler {
	s := &memSampler{stop: make(chan struct{})}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		var ms runtime.MemStats
		for {
			runtime.ReadMemStats(&ms)
			if ms.HeapInuse > s.peak {
				s.peak = ms.HeapInuse
			}
			select {
			case <-s.stop:
				return
			case <-time.After(2 * time.Millisecond):
			}
		}
	}()
	return s
}

func (s *memSampler) finish() uint64 { close(s.stop); s.wg.Wait(); return s.peak }

// measuredSolve solves and fills the allocation stats (Go: MemStats deltas, sampled peak HeapInuse).
func measuredSolve(m *engine.Model) (*engine.Results, error) {
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	smp := startSampler()
	p, err := engine.Prepare(m)
	var out *engine.Out
	if err == nil {
		out, err = p.Solve()
	}
	runtime.ReadMemStats(&after)
	peak := smp.finish()
	if err != nil {
		return nil, err
	}
	res := p.ResultsJSON(out)
	cnt, byt := after.Mallocs-before.Mallocs, after.TotalAlloc-before.TotalAlloc
	if after.HeapInuse > peak {
		peak = after.HeapInuse
	}
	res.Stats.AllocCount, res.Stats.AllocBytes, res.Stats.PeakHeapBytes = &cnt, &byt, &peak
	return res, nil
}

func cmdSolve(args []string) int {
	fs := flag.NewFlagSet("solve", flag.ExitOnError)
	out := fs.String("o", "", "output file")
	pos, err := splitArgs(fs, args)
	if err != nil || len(pos) != 1 {
		usage()
	}
	data, err := os.ReadFile(pos[0])
	if err != nil {
		return fail(err)
	}
	var m engine.Model
	if err := json.Unmarshal(data, &m); err != nil {
		return fail(err)
	}
	res, err := measuredSolve(&m)
	if err != nil {
		return fail(err)
	}
	if err := writeJSON(*out, res); err != nil {
		return fail(err)
	}
	return 0
}

func parseBS(pos []string) (int, int) {
	if len(pos) != 2 {
		usage()
	}
	b, e1 := strconv.Atoi(pos[0])
	s, e2 := strconv.Atoi(pos[1])
	if e1 != nil || e2 != nil || b < 1 || s < 1 {
		usage()
	}
	return b, s
}

func cmdGen(args []string) int {
	fs := flag.NewFlagSet("gen", flag.ExitOnError)
	out := fs.String("o", "", "output file")
	pos, err := splitArgs(fs, args)
	if err != nil {
		usage()
	}
	b, s := parseBS(pos)
	if err := writeJSON(*out, engine.Gen(b, s)); err != nil {
		return fail(err)
	}
	return 0
}

func median(v []float64) float64 {
	sort.Float64s(v)
	return v[len(v)/2]
}

func cmdBench(args []string) int {
	fs := flag.NewFlagSet("bench", flag.ExitOnError)
	reps := fs.Int("reps", 5, "repetitions")
	pos, err := splitArgs(fs, args)
	if err != nil {
		usage()
	}
	b, s := parseBS(pos)
	var asm, fac, sol []float64
	var last *engine.Results
	for r := 0; r < *reps; r++ {
		res, err := measuredSolve(engine.Gen(b, s))
		if err != nil {
			return fail(err)
		}
		asm, fac, sol = append(asm, res.Stats.AssembleMS), append(fac, res.Stats.FactorMS), append(sol, res.Stats.SolveMS)
		last = res
	}
	st := last.Stats
	st.AssembleMS, st.FactorMS, st.SolveMS = median(asm), median(fac), median(sol)
	if err := writeJSON("", map[string]any{"bays": b, "stories": s, "reps": *reps, "stats": st}); err != nil {
		return fail(err)
	}
	return 0
}

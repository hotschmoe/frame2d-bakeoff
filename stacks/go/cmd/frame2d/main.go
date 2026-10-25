// Command frame2d is the Frame2D CLI: solve, gen and bench (SPEC 5.3).
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync/atomic"
	"time"

	"frame2d/engine"
)

const usage = `usage:
  frame2d solve <model.json> [-o results.json]
  frame2d gen <B> <S> [-o model.json]
  frame2d bench <B> <S> [--reps N]`

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, usage)
		return 1
	}
	var err error
	switch args[0] {
	case "solve":
		err = cmdSolve(args[1:])
	case "gen":
		err = cmdGen(args[1:])
	case "bench":
		err = cmdBench(args[1:])
	default:
		fmt.Fprintln(os.Stderr, usage)
		return 1
	}
	if err == nil {
		return 0
	}
	var me *engine.ModelError
	if errors.As(err, &me) {
		_ = json.NewEncoder(os.Stdout).Encode(me)
		return 2
	}
	fmt.Fprintln(os.Stderr, "frame2d:", err)
	return 1
}

// splitArgs separates positionals from -o/--reps style flags.
func splitArgs(args []string, flags ...string) (pos []string, vals map[string]string, err error) {
	vals = map[string]string{}
	for i := 0; i < len(args); i++ {
		isFlag := false
		for _, f := range flags {
			if args[i] == f {
				if i+1 >= len(args) {
					return nil, nil, fmt.Errorf("missing value for %s", f)
				}
				vals[f] = args[i+1]
				i++
				isFlag = true
				break
			}
		}
		if !isFlag {
			pos = append(pos, args[i])
		}
	}
	return pos, vals, nil
}

// writeOut runs emit against stdout, or the file at path, through a buffered writer. A failed close of
// the output file is reported (a full disk shows up there).
func writeOut(path string, emit func(w io.Writer) error) (err error) {
	w := os.Stdout
	if path != "" {
		f, err := os.Create(path)
		if err != nil {
			return err
		}
		defer func() {
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}()
		w = f
	}
	bw := bufio.NewWriterSize(w, 256<<10)
	if err := emit(bw); err != nil {
		return err
	}
	return bw.Flush()
}

func writeJSON(path string, v any) error {
	return writeOut(path, func(w io.Writer) error { return json.NewEncoder(w).Encode(v) })
}

func cmdGen(args []string) error {
	pos, vals, err := splitArgs(args, "-o")
	if err != nil || len(pos) != 2 {
		return fmt.Errorf("gen needs <B> <S>")
	}
	b, e1 := strconv.Atoi(pos[0])
	s, e2 := strconv.Atoi(pos[1])
	if e1 != nil || e2 != nil || b < 1 || s < 1 {
		return fmt.Errorf("gen: B and S must be positive integers")
	}
	return writeJSON(vals["-o"], engine.Generate(b, s))
}

func cmdSolve(args []string) error {
	pos, vals, err := splitArgs(args, "-o")
	if err != nil || len(pos) != 1 {
		return fmt.Errorf("solve needs <model.json>")
	}
	data, err := os.ReadFile(pos[0])
	if err != nil {
		return err
	}
	m, err := engine.ParseModel(data)
	if err != nil {
		return err
	}
	res, err := measuredSolve(m)
	if err != nil {
		return err
	}
	return writeOut(vals["-o"], res.WriteJSON)
}

// measuredSolve runs one solve and records allocation counts around it (SPEC 5.2, Go row).
func measuredSolve(m *engine.Model) (*engine.Results, error) {
	var peak atomic.Uint64
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		var ms runtime.MemStats
		t := time.NewTicker(time.Millisecond)
		defer t.Stop()
		for {
			runtime.ReadMemStats(&ms)
			if ms.HeapInuse > peak.Load() {
				peak.Store(ms.HeapInuse)
			}
			select {
			case <-stop:
				return
			case <-t.C:
			}
		}
	}()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	sol, err := engine.Analyze(m, engine.Options{})
	var res *engine.Results
	if err == nil {
		res = sol.Results()
	}
	runtime.ReadMemStats(&after)
	close(stop)
	<-done
	if err != nil {
		return nil, err
	}
	count, bytes, pk := after.Mallocs-before.Mallocs, after.TotalAlloc-before.TotalAlloc, peak.Load()
	if after.HeapInuse > pk {
		pk = after.HeapInuse
	}
	res.Stats.AllocCount, res.Stats.AllocBytes, res.Stats.PeakHeapBytes = &count, &bytes, &pk
	return res, nil
}

func cmdBench(args []string) error {
	pos, vals, err := splitArgs(args, "--reps")
	if err != nil || len(pos) != 2 {
		return fmt.Errorf("bench needs <B> <S> [--reps N]")
	}
	b, e1 := strconv.Atoi(pos[0])
	s, e2 := strconv.Atoi(pos[1])
	reps := 5
	if v, ok := vals["--reps"]; ok {
		if reps, err = strconv.Atoi(v); err != nil || reps < 1 {
			return fmt.Errorf("bench: bad --reps")
		}
	}
	if e1 != nil || e2 != nil || b < 1 || s < 1 {
		return fmt.Errorf("bench: B and S must be positive integers")
	}
	var runs []engine.Stats
	for i := 0; i < reps; i++ {
		m := engine.Generate(b, s)
		res, err := measuredSolve(m)
		if err != nil {
			return err
		}
		runs = append(runs, res.Stats)
	}
	last := runs[len(runs)-1]
	last.AssembleMS = median(runs, func(s engine.Stats) float64 { return s.AssembleMS })
	last.FactorMS = median(runs, func(s engine.Stats) float64 { return s.FactorMS })
	last.SolveMS = median(runs, func(s engine.Stats) float64 { return s.SolveMS })
	return writeJSON("", struct {
		engine.Stats
		B    int `json:"B"`
		S    int `json:"S"`
		Reps int `json:"reps"`
	}{last, b, s, reps})
}

func median(runs []engine.Stats, f func(engine.Stats) float64) float64 {
	v := make([]float64, len(runs))
	for i, r := range runs {
		v[i] = f(r)
	}
	sort.Float64s(v)
	return v[len(v)/2]
}

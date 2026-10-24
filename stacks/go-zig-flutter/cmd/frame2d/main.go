// Command frame2d is the Frame2D CLI: solve, gen, bench (SPEC 5.3). All analysis runs in the Zig engine (cgo).
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"

	zigengine "frame2d/bridge/zig"
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
	var me *zigengine.ModelError
	if errors.As(err, &me) {
		fmt.Fprintf(os.Stdout, "{\"error\":%q,\"detail\":%q}%c", me.Code, me.Detail, '\n')
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

// writeBytes writes b (plus a newline) to path, or to stdout when path is empty.
func writeBytes(path string, b []byte) error {
	b = append(b, '\n')
	if path == "" {
		_, err := os.Stdout.Write(b)
		return err
	}
	return os.WriteFile(path, b, 0o644)
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
	res, err := zigengine.SolveJSON(data, true)
	if err != nil {
		return fail(err)
	}
	if err := writeBytes(*out, res); err != nil {
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
	model, err := zigengine.GenJSON(b, s)
	if err != nil {
		return fail(err)
	}
	if err := writeBytes(*out, model); err != nil {
		return fail(err)
	}
	return 0
}

func cmdBench(args []string) int {
	fs := flag.NewFlagSet("bench", flag.ExitOnError)
	reps := fs.Int("reps", 5, "repetitions")
	pos, err := splitArgs(fs, args)
	if err != nil {
		usage()
	}
	b, s := parseBS(pos)
	res, err := zigengine.Bench(b, s, *reps)
	if err != nil {
		return fail(err)
	}
	if err := writeBytes("", res); err != nil {
		return fail(err)
	}
	return 0
}

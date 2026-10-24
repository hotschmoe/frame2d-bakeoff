//go:build !js

package main

import (
	"fmt"
	"os"
	"strings"
)

// benchMode returns the --bench=<mode> argument, or "".
func benchMode() string {
	for _, a := range os.Args[1:] {
		if m, ok := strings.CutPrefix(a, "--bench="); ok {
			return m
		}
	}
	return ""
}

// emit prints a BENCH line to stdout.
func emit(line string) {
	fmt.Fprintln(os.Stdout, line)
	_ = os.Stdout.Sync()
}

func exitProcess() { os.Exit(0) }

func (u *ui) openFile() {
	data, err := os.ReadFile(strings.TrimSpace(u.pathEd.Text()))
	if err != nil {
		u.note = "Open: " + err.Error()
		return
	}
	u.loadModel(data)
}

func (u *ui) saveFile(data []byte) error {
	return os.WriteFile(strings.TrimSpace(u.pathEd.Text()), data, 0o644)
}

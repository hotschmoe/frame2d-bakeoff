//go:build !windows && !js

package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

var processStart = time.Now()

func sinceProcessStartMS() float64 {
	return float64(time.Since(processStart).Nanoseconds()) / 1e6
}

// rssMB reads the peak resident set (VmHWM) from /proc.
func rssMB() float64 {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, "VmHWM:"); ok {
			f := strings.Fields(rest)
			if len(f) > 0 {
				kb, _ := strconv.ParseFloat(f[0], 64)
				return kb / 1024
			}
		}
	}
	return 0
}

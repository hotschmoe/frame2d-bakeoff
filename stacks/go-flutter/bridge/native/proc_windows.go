package main

import (
	"syscall"
	"time"
)

func processAgeMS() float64 {
	h, err := syscall.GetCurrentProcess()
	if err != nil {
		return 0
	}
	var creation, exit, kernel, user syscall.Filetime
	if err := syscall.GetProcessTimes(h, &creation, &exit, &kernel, &user); err != nil {
		return 0
	}
	started := time.Unix(0, creation.Nanoseconds())
	return float64(time.Since(started).Nanoseconds()) / 1e6
}

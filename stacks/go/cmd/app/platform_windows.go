//go:build windows

package main

import (
	"syscall"
	"time"
	"unsafe"
)

var processStart = func() time.Time {
	h, err := syscall.GetCurrentProcess()
	if err != nil {
		return time.Now()
	}
	var creation, exit, kernel, user syscall.Filetime
	if err := syscall.GetProcessTimes(h, &creation, &exit, &kernel, &user); err != nil {
		return time.Now()
	}
	return time.Unix(0, creation.Nanoseconds())
}()

// sinceProcessStartMS is the time since the OS created this process.
func sinceProcessStartMS() float64 {
	return float64(time.Since(processStart).Nanoseconds()) / 1e6
}

type processMemoryCounters struct {
	cb                         uint32
	pageFaultCount             uint32
	peakWorkingSetSize         uintptr
	workingSetSize             uintptr
	quotaPeakPagedPoolUsage    uintptr
	quotaPagedPoolUsage        uintptr
	quotaPeakNonPagedPoolUsage uintptr
	quotaNonPagedPoolUsage     uintptr
	pagefileUsage              uintptr
	peakPagefileUsage          uintptr
}

// rssMB is the peak working set of the process in MiB.
func rssMB() float64 {
	h, err := syscall.GetCurrentProcess()
	if err != nil {
		return 0
	}
	proc := syscall.NewLazyDLL("psapi.dll").NewProc("GetProcessMemoryInfo")
	var c processMemoryCounters
	c.cb = uint32(unsafe.Sizeof(c))
	if r, _, _ := proc.Call(uintptr(h), uintptr(unsafe.Pointer(&c)), uintptr(c.cb)); r == 0 {
		return 0
	}
	return float64(c.peakWorkingSetSize) / (1 << 20)
}

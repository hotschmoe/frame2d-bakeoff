#!/usr/bin/env python3
"""Portable stand-in for the cgroup accounting in measure.sh (SPEC 15.4). usage: measure_fallback.py <out.json> <cmd...>

Reports wall_s always. With psutil installed it also samples the process tree every 50 ms for
peak total RSS (mem_peak_mb), peak process count (procs_peak) and CPU seconds (cpu_s, user+system,
including children that have exited while they were observed). Without psutil those fields are null.
cgroup-only fields (swap_peak_mb, io_*) are always null here.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

out, cmd = sys.argv[1], sys.argv[2:]
if os.name == "nt" and cmd and cmd[0] == "bash":
    # a bare "bash" resolves to System32/bash.exe (the WSL stub) on Windows; use $F2D_BASH or Git bash
    git = shutil.which("git")
    cands = [os.environ.get("F2D_BASH"), git and str(pathlib.Path(git).resolve().parent.parent / "bin" / "bash.exe"),
             r"C:\Program Files\Git\bin\bash.exe"]
    cmd[0] = next((c for c in cands if c and os.path.exists(c)), "bash")
try:
    import psutil
except ImportError:
    psutil = None

t0 = time.perf_counter()
p = subprocess.Popen(cmd)
mem_peak = procs_peak = 0
cpu = {}  # pid -> last seen cpu seconds, so exited children still count
if psutil:
    root = psutil.Process(p.pid)
    while p.poll() is None:
        try:
            tree = [root] + root.children(recursive=True)
        except psutil.Error:
            tree = []
        rss = 0
        for q in tree:
            try:
                rss += q.memory_info().rss
                t = q.cpu_times()
                cpu[q.pid] = t.user + t.system
            except psutil.Error:
                pass
        mem_peak, procs_peak = max(mem_peak, rss), max(procs_peak, len(tree))
        time.sleep(0.05)
rc = p.wait()
wall = time.perf_counter() - t0
cpu_s = sum(cpu.values()) if psutil else None
json.dump({"wall_s": wall, "cpu_s": cpu_s, "parallelism": (cpu_s / wall) if cpu_s and wall else None,
           "mem_peak_mb": mem_peak / 2**20 if psutil else None, "swap_peak_mb": None,
           "io_read_mb": None, "io_write_mb": None, "procs_peak": procs_peak if psutil else None,
           "exit_code": rc, "method": "psutil" if psutil else "wall-only"}, open(out, "w"))
sys.exit(rc)

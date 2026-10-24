#!/usr/bin/env python3
"""SPEC 9.3 Zig incremental probing: run the stack's build_check under `zig build --watch [-fincremental]` (via the
BL_ZIG_WATCH shim in call.sh), then toggle the leaf edit and time file write -> next "Build Summary" line.

usage: zigwatch.py <bash> <stack-dir> <call.sh> <edit.sh> <mode: plain|incremental> <fn> <out.json> <reps> [timeout-s]
Writes {"mode":..,"fn":..,"supported":bool,"initial_build_s":..,"rebuild_s":[..],"note":..}.
The caller restores the leaf edit (edit.sh --restore counts these toggles).
"""
import json
import os
import subprocess
import sys
import time

import proc

bash, sd, call, edit_sh, mode, fn, out, reps = sys.argv[1:9]
reps = int(reps)
to = float(sys.argv[9]) if len(sys.argv) > 9 else 600.0
res = {"mode": mode, "fn": fn, "supported": False, "rebuild_s": []}
env = dict(os.environ, BL_ZIG_WATCH=mode)
t0 = time.perf_counter()
p = proc.spawn([bash, call, sd, fn], env=env)


def summary(line):
    return line.startswith("Build Summary")


try:
    t, _ = proc.wait_line(p, summary, to)
    if isinstance(t, str):
        res["note"] = f"no Build Summary from zig build --watch ({t}); last output: " + " | ".join(p.log[-6:])
    else:
        res["initial_build_s"] = t - t0
        for i in range(reps):
            time.sleep(1.0)
            subprocess.run([bash, edit_sh, sd, "leaf"], check=True)
            tw = time.perf_counter()
            t, _ = proc.wait_line(p, summary, to)
            if isinstance(t, str):
                res["note"] = f"rebuild {i} produced no Build Summary ({t})"
                break
            res["rebuild_s"].append(t - tw)
        res["supported"] = bool(res["rebuild_s"])
finally:
    proc.kill_tree(p)
json.dump(res, open(out, "w"), indent=1)

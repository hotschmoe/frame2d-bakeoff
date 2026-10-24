#!/usr/bin/env python3
"""SPEC 9.2 engine edit to running app (Flutter stacks): after a leaf edit and a build_dev, start the freshly built
desktop app with --bench=startup and time until its BENCH startup line (first frame).

usage: engine.py launch <stack-dir> <out.jsonl> [timeout-s]                      (appends one record)
       engine.py combine <engine-build.jsonl> <engine-launch.jsonl> <out.jsonl>  (edit_to_first_frame per rep)
"""
import glob
import json
import os
import pathlib
import sys
import time

import proc


def find_exe(sd):
    """Newest debug desktop executable named frame2d_app* / app* under the stack's build trees."""
    sd = pathlib.Path(sd)
    cands = set()
    for pat in ("app/build/**/runner/Debug/*.exe", "app/build/**/debug/bundle/*", "**/build/**/runner/Debug/*.exe"):
        for f in glob.glob(str(sd / pat), recursive=True):
            f = pathlib.Path(f)
            if f.is_file() and f.name.lower().startswith(("frame2d", "app")) and (f.suffix == ".exe" or os.access(f, os.X_OK)) \
                    and f.suffix not in (".so", ".dll", ".dylib", ".pdb"):
                cands.add(f)
    cands = sorted(cands, key=lambda f: -f.stat().st_mtime)
    return cands[0] if cands else None


def launch(sd, out, timeout=120.0):
    exe = find_exe(sd)
    if not exe:
        rec = {"kind": "error", "error": "no debug desktop app executable found under app/build"}
    else:
        t0 = time.perf_counter()
        p = proc.spawn([str(exe), "--bench=startup"], cwd=str(exe.parent))
        t, line = proc.wait_line(p, lambda l: l.startswith("BENCH "), timeout)
        if isinstance(t, str):
            rec = {"kind": "error", "error": f"no BENCH line ({t})", "exe": str(exe), "tail": p.log[-10:]}
        else:
            bench = json.loads(line[6:])
            rec = {"kind": "launch", "exe": str(exe), "launch_to_bench_s": t - t0,
                   "first_frame_ms": bench.get("first_frame_ms"), "bench": bench}
        proc.kill_tree(p)
    with open(out, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def combine(b, l, out):
    rb = [json.loads(x) for x in open(b, encoding="utf-8") if x.strip()]
    rl = [json.loads(x) for x in open(l, encoding="utf-8") if x.strip()]
    with open(out, "w", encoding="utf-8") as f:
        for i, (x, y) in enumerate(zip(rb, rl)):
            ok = x.get("exit_code") == 0 and y.get("kind") == "launch"
            f.write(json.dumps({"rep": i, "ok": ok, "build_wall_s": x["wall_s"], "build_cpu_s": x.get("cpu_s"),
                                "launch_to_first_frame_s": y.get("launch_to_bench_s"),
                                "first_frame_ms_reported": y.get("first_frame_ms"),
                                "edit_to_first_frame_s": (x["wall_s"] + y["launch_to_bench_s"]) if ok else None}) + "\n")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "launch":
        launch(a[1], a[2], float(a[3]) if len(a) > 3 else 120.0)
    elif a[0] == "combine":
        combine(a[1], a[2], a[3])

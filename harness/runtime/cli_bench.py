#!/usr/bin/env python3
"""SPEC 8.3 CLI part + 8.8 allocation stats: `frame2d bench B S --reps 5` for 10,50,100,200 (the CLI itself reports the
median assemble/factor/solve over its reps). Peak RSS of the whole process is exact (wait4 rusage on Linux, which is what
/usr/bin/time -v prints; PeakWorkingSetSize via the process handle on Windows). Writes cli.json."""
import json
import sys

import f2d


def extra(ap):
    ap.add_argument("--reps", type=int, default=None)
    ap.add_argument("--sizes", default=None)


a = f2d.cli_args("cli bench", extra)
stack, out = a.stack, a.outp
art = f2d.load_artifacts(stack, out)
cli = art.get("cli")
if not cli:
    sys.exit(f"[{stack}] no cli artifact")
reps = a.reps or (1 if a.quick else 5)
sizes = [int(x) for x in a.sizes.split(",")] if a.sizes else ([10, 50] if a.quick else [10, 50, 100, 200])
rows = {}
for n in sizes:
    r = f2d.run_measured([cli, "bench", str(n), str(n), "--reps", str(reps)], timeout=3600)
    row = {"bays": n, "stories": n, "reps": reps, "rc": r["rc"], "wall_s": r["wall_s"], "peak_rss_mb": r["peak_rss_mb"],
           "cpu_s": r["cpu_s"], "rss_method": r["rss_method"]}
    try:
        line = [l for l in r["stdout"].splitlines() if l.strip().startswith("{")][-1]
        d = json.loads(line)
        s = d.get("stats", d)
        for k in ("nodes", "members", "free_dofs", "profile_before", "profile_after", "assemble_ms", "factor_ms", "solve_ms",
                  "alloc_count", "alloc_bytes", "peak_heap_bytes"):
            row[k] = s.get(k)
    except Exception as e:  # noqa: BLE001
        row["error"] = f"unparseable bench output: {e}; stderr tail: {f2d.tail(r['stderr'], 5)}"
    rows[f"{n}x{n}"] = row
    print(f"[{stack}] cli bench {n}x{n}: " + ", ".join(f"{k}={row.get(k)}" for k in ("assemble_ms", "factor_ms", "solve_ms", "peak_rss_mb")), flush=True)
alloc = {k: {x: v.get(x) for x in ("alloc_count", "alloc_bytes", "peak_heap_bytes")} for k, v in rows.items() if k in ("50x50", "200x200")}
f2d.jwrite(out / "cli.json", {"stack": stack, "cmd": "frame2d bench B S --reps N", "reps": reps, "cli": cli, "sizes": rows,
                              "alloc_stats_8_8": alloc,
                              "alloc_note": "Go peak_heap_bytes is approximate (sampled HeapInuse); counts cover one solve, excluding gen/parse (SPEC 5.2)"})

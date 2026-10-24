#!/usr/bin/env python3
"""SPEC 8.3 desktop app: --bench=startup|drag|render|boundary, N runs each (5; --quick 1), BENCH {json} parsed from stdout,
median of each field. Records renderer lines the app prints (hardware vs software, SPEC 15.3) and sampled peak tree RSS.
Writes desktop.json."""
import platform
import sys

import f2d


def extra(ap):
    ap.add_argument("--runs", type=int, default=None)
    ap.add_argument("--modes", default="startup,drag,render,boundary")


a = f2d.cli_args("desktop app bench", extra)
stack, out = a.stack, a.outp
conf = f2d.cfg(stack)
art = f2d.load_artifacts(stack, out)
exe = art.get("desktop_exe")
if not exe:
    sys.exit(f"[{stack}] no desktop_exe artifact")
runs = a.runs or (1 if a.quick else 5)
res = {"stack": stack, "exe": exe, "runs_per_mode": runs, "host_arch": platform.machine(),
       "emulation_note": ("Flutter desktop apps are x64 builds run under emulation on win-arm64; pure stacks are native arm64 "
                          "(do not compare directly on this machine, versions.md)") if conf.get("flutter") and f2d.IS_WIN and
       platform.machine().lower() in ("arm64", "aarch64") else None,
       "modes": {}, "renderer_lines": []}
for mode in a.modes.split(","):
    rs = []
    for i in range(runs):
        r = f2d.run_app(exe, mode, timeout=900)
        r.pop("gc_stderr", None)
        rs.append(r)
        b = r["bench"] or {}
        print(f"[{stack}] desktop {mode} run {i + 1}/{runs}: " + (", ".join(f"{k}={v}" for k, v in b.items() if k != "mechanism") if b else "NO BENCH LINE (rc=%s timeout=%s) %s" % (r["rc"], r["timed_out"], r["stderr_tail"][-200:])), flush=True)
        for l in r["renderer_lines"]:
            if l not in res["renderer_lines"]:
                res["renderer_lines"].append(l)
    benches = [r["bench"] for r in rs if r["bench"]]
    med = f2d.median_fields(benches)
    med["peak_rss_mb_tree_sampled"] = f2d.median([r["peak_rss_mb_tree"] for r in rs])
    mech = next((b.get("mechanism") for b in benches if b.get("mechanism")), None)
    res["modes"][mode] = {"ok_runs": len(benches), "median": med, "mechanism": mech, "runs": rs}
res["renderer_note"] = ("renderer lines are whatever the app printed matching impeller/opengl/d3d/vulkan/software/...; "
                        "empty means the app does not report its renderer (see AGENT_LOG.md / env.md for GPU)")
f2d.jwrite(out / "desktop.json", res)

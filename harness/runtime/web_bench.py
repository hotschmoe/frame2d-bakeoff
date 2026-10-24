#!/usr/bin/env python3
"""SPEC 8.4: run harness/bench_web.mjs on the stack's default web build (-> web.json) and on the alternate build, if the
stack has one (-> web_alt.json, recorded as extra)."""
import subprocess
import sys

import f2d


def extra(ap):
    ap.add_argument("--runs", type=int, default=None)
    ap.add_argument("--modes", default="ready,startup,drag,render,boundary")
    ap.add_argument("--no-alt", action="store_true")


a = f2d.cli_args("web bench", extra)
stack, out = a.stack, a.outp
art = f2d.load_artifacts(stack, out)
node = f2d.find_tool("node")
if not node:
    sys.exit("node not found")
runs = a.runs or (1 if a.quick else 5)
rc_all = 0
for key, fname in (("web", "web.json"), ("web_alt", "web_alt.json")):
    w = art.get(key)
    if not w:
        continue
    if key == "web_alt" and a.no_alt:
        continue
    cmd = [node, str(f2d.ROOT / "harness" / "bench_web.mjs"), "--root", w["dist"], "--out", str(out / fname), "--stack", stack,
           "--label", w["label"], "--runs", str(runs), "--modes", a.modes]
    if f2d.os.environ.get("F2D_PLAYWRIGHT_DIR"):
        cmd += ["--playwright", f2d.npath(f2d.os.environ["F2D_PLAYWRIGHT_DIR"])]
    print(f"[{stack}] web bench ({w['label']}): {w['dist']}", flush=True)
    with open(out / "logs" / f"{fname}.log", "wb") as lf:
        p = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT)
    log = (out / "logs" / f"{fname}.log").read_text(errors="replace")
    print("\n".join(l for l in log.splitlines() if l.startswith("[") )[-3000:], flush=True)
    rc_all |= p.returncode
    r = f2d.jread(out / fname)
    if r:
        r["what"] = w.get("what")
        r["is_alternate_extra"] = key == "web_alt"
        f2d.jwrite(out / fname, r)
sys.exit(rc_all)

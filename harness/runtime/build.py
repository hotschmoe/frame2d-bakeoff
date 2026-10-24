#!/usr/bin/env python3
"""Build the release artifacts the runtime sections measure, ONLY through stack.sh (build_*_release), and write
artifacts.json (paths) + build.json (wall time per build; informational, the controlled build timings are harness/buildloop's).
Web outputs are snapshotted into harness/runtime/.work/<stack>/webdist/<label>/ so later builds cannot disturb them."""
import shutil
import sys
from pathlib import Path

import f2d


def extra(ap):
    ap.add_argument("--only", default="cli,server,desktop,web", help="comma list of cli,server,desktop,web")


a = f2d.cli_args("build release artifacts", extra)
stack, out = a.stack, a.outp
conf = f2d.cfg(stack)
log = out / "logs" / "build.log"
only = set(a.only.split(","))
art = f2d.jread(out / "artifacts.json", {}) or {}
rec = f2d.jread(out / "build.json", {}) or {}
wd = f2d.work_dir(stack)
art["stack"] = stack


def build(kind, fn, env=None):
    print(f"[{stack}] {fn} ...", flush=True)
    r = f2d.stack_fn(stack, fn, env=env, log=log)
    rec[kind] = {"fn": fn, "env": env or {}, "rc": r["rc"], "wall_s": r["wall_s"], "last_line": r["last_line"]}
    print(f"[{stack}]   rc={r['rc']} {r['wall_s']:.1f}s -> {r['last_line']}", flush=True)
    return r if r["rc"] == 0 else None


def snapshot(src, label):
    dst = wd / "webdist" / label
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    return str(dst)


if "cli" in only:
    r = build("cli", "build_cli_release")
    art["cli"] = f2d.npath(r["last_line"]) if r else None
if "server" in only:
    r = build("server", "build_server_release")
    art["server"] = f2d.npath(r["last_line"]) if r else None
if "desktop" in only:
    r = build("desktop", "build_desktop_release")
    if r:
        exe = Path(f2d.npath(r["last_line"]))
        art["desktop_exe"] = str(exe)
        art["desktop_bundle_dir"] = str(exe.parent) if conf["desktop_bundle"] == "dir" else None
    else:
        art["desktop_exe"] = art["desktop_bundle_dir"] = None
if "web" in only:
    r = build("web", "build_web_release")
    art["web"] = None
    art["web_alt"] = None
    if r:
        alt = conf.get("web_alt")
        prim = [l for l in r["lines"] if not l.startswith("wasm:")][-1]
        art["web"] = {"label": "default", "src": f2d.npath(prim), "dist": snapshot(f2d.npath(prim), "default"),
                      "what": "build_web_release (stack default)"}
        if alt:
            alt_src = None
            if alt["mode"] == "stdout_prefix":
                for l in r["lines"]:
                    if l.startswith(alt["prefix"]):
                        alt_src = f2d.npath(l[len(alt["prefix"]):].strip())
            elif alt["mode"] == "fn":
                r2 = build("web_alt", alt["fn"])
                alt_src = f2d.npath(r2["last_line"]) if r2 else None
            elif alt["mode"] == "env":
                r2 = build("web_alt", "build_web_release", env=alt["env"])
                alt_src = f2d.npath(r2["last_line"]) if r2 else None
            if alt_src:
                art["web_alt"] = {"label": alt["label"], "src": alt_src, "dist": snapshot(alt_src, "alt-" + alt["label"]),
                                  "what": alt.get("note") or alt.get("fn") or "extra web build"}
f2d.jwrite(out / "artifacts.json", art)
f2d.jwrite(out / "build.json", rec)
bad = [k for k, v in rec.items() if v.get("rc") != 0]
if bad:
    print(f"[{stack}] BUILD FAILED: {bad} (see {log})", file=sys.stderr)
    sys.exit(1)

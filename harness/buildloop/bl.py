#!/usr/bin/env python3
"""Helpers for the build-loop harness (SPEC 9). Python 3 stdlib only.

  bl.py trim <label.jsonl> <n>             move the first n (warmup) records to <label>.warmup.jsonl
  bl.py summary <record-dir>               write <record-dir>/summary.json from the *.jsonl measure records
  bl.py footprint <stack-dir> [--baseline <json>]   print build-output sizes as JSON
  bl.py breakdown <tool> <trace-dir> <stack-dir> <since-epoch>   parse cargo/go/zig/flutter traces (SPEC 9.5)
  bl.py contention <contention-dir>        summarize a contention run (SPEC 9.6; Linux data)
"""
import glob
import json
import os
import pathlib
import re
import statistics
import subprocess
import sys


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def read_jsonl(path):
    out = []
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line:
                out.append(json.loads(line))
    except OSError:
        pass
    return out


# ---------------------------------------------------------------- trim / summary
def cmd_trim(path, n):
    n = int(n)
    p = pathlib.Path(path)
    lines = p.read_text(encoding="utf-8").splitlines() if p.exists() else []
    if n > 0:
        p.with_name(p.stem + ".warmup.jsonl").write_text("".join(l + "\n" for l in lines[:n]), encoding="utf-8")
    p.write_text("".join(l + "\n" for l in lines[n:]), encoding="utf-8")


def stat(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"n": len(xs), "min": min(xs), "p50": pct(xs, 50), "mean": statistics.fmean(xs), "p95": pct(xs, 95), "max": max(xs)}


def cmd_summary(d):
    d = pathlib.Path(d)
    out = {}
    for f in sorted(d.glob("*.jsonl")):
        if f.name.endswith(".warmup.jsonl"):
            continue
        recs = read_jsonl(f)
        if not recs:
            continue
        label = f.stem
        ent = {"n": len(recs), "failures": sum(1 for r in recs if r.get("exit_code")),
               "method": recs[0].get("method")}
        for k in ("wall_s", "cpu_s", "parallelism", "mem_peak_mb", "swap_peak_mb", "io_read_mb", "io_write_mb", "procs_peak"):
            s = stat([r.get(k) for r in recs])
            if s:
                ent[k] = s
        out[label] = ent
    hyper = {}
    for f in sorted((d / "hyperfine").glob("*.json")) if (d / "hyperfine").is_dir() else []:
        try:
            for r in json.load(open(f))["results"]:
                hyper[r["command"]] = {"mean": r["mean"], "stddev": r["stddev"], "median": r["median"],
                                       "min": r["min"], "max": r["max"], "runs": len(r["times"])}
        except (OSError, KeyError, ValueError):
            pass
    for label, h in hyper.items():
        out.setdefault(label, {})["hyperfine_s"] = h
    (d / "summary.json").write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"summary: {len(out)} labels -> {d / 'summary.json'}")


# ---------------------------------------------------------------- footprint (SPEC 9.4)
def dir_size(path):
    """(apparent bytes, allocated bytes or None, files)."""
    app = alloc = files = 0
    have_blocks = True
    stack = [str(path)]
    while stack:
        cur = stack.pop()
        try:
            it = os.scandir(cur)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    if e.is_symlink():
                        continue
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    else:
                        st = e.stat(follow_symlinks=False)
                        app += st.st_size
                        files += 1
                        if hasattr(st, "st_blocks"):
                            alloc += st.st_blocks * 512
                        else:
                            have_blocks = False
                except OSError:
                    pass
    return app, (alloc if have_blocks else None), files


# Build outputs and compiled deps. Downloaded sources (cargo registry, pub cache, zig .zig-global/p, zig-pkg, go module cache)
# are deliberately not listed: they survive clean_all (SPEC 9.1).
CANDIDATES = ["target", "build", "zig-out", ".zig-cache", "app/build", "app/.dart_tool", "app/web/engine"]


def footprint_items(sd):
    sd = pathlib.Path(sd)
    items = {}
    for c in CANDIDATES:
        if (sd / c).is_dir():
            items[c] = sd / c
    zg = sd / ".zig-global"
    if zg.is_dir():
        for ch in sorted(zg.iterdir()):
            if ch.is_dir() and ch.name != "p":   # p = package source tarballs, kept by clean_all
                items[".zig-global/" + ch.name] = ch
    if (sd / "go.mod").exists() or (sd / "app" / "go.mod").exists():
        try:
            gc = subprocess.run(["go", "env", "GOCACHE"], capture_output=True, text=True, cwd=sd, timeout=60).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            gc = ""
        if gc and os.path.isdir(gc):
            items["GOCACHE"] = pathlib.Path(gc)
    return items


def cmd_footprint(sd, baseline=None):
    base = {}
    if baseline:
        base = {k: v["bytes"] for k, v in json.load(open(baseline))["items"].items()}
    items, total = {}, 0
    for name, p in footprint_items(sd).items():
        app, alloc, files = dir_size(p)
        ent = {"bytes": app, "disk_bytes": alloc, "files": files}
        counted = app
        if name == "GOCACHE":   # shared cache: report the delta over the baseline taken right after clean_all
            ent["baseline_bytes"] = base.get(name, 0)
            counted = max(0, app - ent["baseline_bytes"])
            ent["delta_bytes"] = counted
        ent["counted_bytes"] = counted
        total += counted
        items[name] = ent
    print(json.dumps({"stack_dir": str(sd), "total_bytes": total, "total_mb": round(total / 2**20, 1), "items": items}, indent=1))


# ---------------------------------------------------------------- breakdown (SPEC 9.5)
CATS = ["deps", "frontend", "codegen", "link", "tools"]


def workspace_names(sd):
    names = set()
    for f in pathlib.Path(sd).rglob("Cargo.toml"):
        if "target" in f.parts:
            continue
        m = re.search(r"\[package\][^\[]*?\bname\s*=\s*\"([^\"]+)\"", f.read_text(encoding="utf-8", errors="replace"), re.S)
        if m:
            names.add(m.group(1))
    return names


def parse_cargo(trace, sd, since):
    """cargo --timings HTML embeds `const UNIT_DATA = [...]`. frontend ~ rmeta_time, codegen ~ duration - rmeta_time."""
    ws = workspace_names(sd)
    files = [f for f in glob.glob(str(pathlib.Path(sd) / "**" / "cargo-timing-*.html"), recursive=True) if os.path.getmtime(f) >= since]
    t = dict.fromkeys(CATS, 0.0)
    units = []
    for f in files:
        html = open(f, encoding="utf-8", errors="replace").read()
        m = re.search(r"const UNIT_DATA = (\[.*?\]);\s*\n", html, re.S)
        if not m:
            continue
        for u in json.loads(m.group(1)):
            dur = float(u.get("duration") or 0)
            rm = u.get("rmeta_time")
            tgt = (u.get("target") or "")
            if u.get("mode") == "run-custom-build" or "build script" in tgt:
                cat = "tools"
            elif u["name"] not in ws:
                cat = "deps"
            else:
                cat = "workspace"
            if cat == "workspace":
                secs = {k: v["end"] - v["start"] for k, v in (u.get("sections") or [])}
                if secs:                      # cargo >= 1.9x reports per-unit frontend/codegen sections
                    t["frontend"] += secs.get("frontend", 0.0)
                    t["codegen"] += secs.get("codegen", 0.0)
                elif '"bin"' in tgt:          # no sections: a binary target = a tiny compile plus the link
                    t["link"] += dur
                elif rm:
                    t["frontend"] += float(rm)
                    t["codegen"] += max(0.0, dur - float(rm))
                else:
                    t["codegen"] += dur
            else:
                t[cat] += dur
            units.append({"name": u["name"], "cat": cat, "duration_s": dur})
    units.sort(key=lambda u: -u["duration_s"])
    return {"tool": "cargo --timings", "reports": len(files), "units": len(units), "seconds_by_category": t,
            "note": "sum of per-unit work seconds (units overlap, so this exceeds wall time). Workspace crates: frontend/codegen from cargo's "
                    "per-unit sections (older cargo: rmeta time); binary targets have no sections and are filed under link (a small compile plus the link). "
                    "deps = all registry crates (frontend+codegen together); tools = build scripts and their compile",
            "top_units": units[:12]}


def _iso(s):
    from datetime import datetime
    s = re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00"))
    return datetime.fromisoformat(s)


def parse_go(trace, sd, since):
    mod = ""
    gm = pathlib.Path(sd) / "go.mod"
    if not gm.exists():
        gm = pathlib.Path(sd) / "app" / "go.mod"
    if gm.exists():
        m = re.search(r"^module\s+(\S+)", gm.read_text(encoding="utf-8"), re.M)
        mod = m.group(1) if m else ""
    t = dict.fromkeys(CATS, 0.0)
    n = 0
    top = []
    for f in glob.glob(str(pathlib.Path(trace) / "ag-*.json")):
        acts = json.load(open(f))
        for a in acts:
            mode, pkg = a.get("Mode", ""), a.get("Package", "")
            if mode not in ("build", "link") and not mode.startswith(("cgo", "asm", "gcc")):
                continue                      # cache lookups, installs, nops, built-in packages: no work
            if a.get("CmdReal"):              # wall ns of the compiler/linker process itself (0 for cache hits)
                d = a["CmdReal"] / 1e9
            else:
                ts, td = a.get("TimeStart"), a.get("TimeDone")
                if not ts or not td or ts.startswith("0001"):
                    continue
                d = (_iso(td) - _iso(ts)).total_seconds() if mode != "build" else 0.0   # build without a command = cached
            if d <= 0:
                continue
            own = bool(mod) and (pkg == mod or pkg.startswith(mod + "/") or pkg == "main" or pkg.startswith("command-line"))
            cat = "link" if mode == "link" else ("frontend" if own else "deps") if mode == "build" else "tools"
            t[cat] += d
            n += 1
            top.append({"name": f"{mode} {pkg}", "cat": cat, "duration_s": d})
    top.sort(key=lambda u: -u["duration_s"])
    return {"tool": "go -debug-actiongraph", "actions": n, "seconds_by_category": t,
            "note": "per-action wall seconds (parallel actions overlap). Go's compile action covers frontend+codegen together; "
                    "it is reported under frontend for own packages and deps for others. link = link actions. tools = cgo/asm/other",
            "top_units": top[:12]}


def _secs(txt):
    tot = 0.0
    for v, u in re.findall(r"(\d+(?:\.\d+)?)\s*(ms|m|s)\b", txt):
        tot += float(v) * {"ms": 0.001, "s": 1.0, "m": 60.0}[u]
    return tot


def parse_zig(trace, sd, since):
    t = dict.fromkeys(CATS, 0.0)
    steps = []
    for f in glob.glob(str(pathlib.Path(trace) / "*.out")):
        for line in open(f, encoding="utf-8", errors="replace"):
            m = re.match(r"^[\s│├└─+|\\-]*?(compile|run|install|options|WriteFile|write)\b(.*?)\s(success|failure|cached|skipped)\b(.*)$", line.rstrip())
            if not m:
                continue
            kind, what, status, rest = m.groups()
            d = _secs(rest.split("MaxRSS")[0])
            if status != "success" or d <= 0:
                continue
            cat = {"compile": "frontend", "run": "tools"}.get(kind)
            if cat:
                t[cat] += d
                steps.append({"name": f"{kind}{what}", "cat": cat, "duration_s": d})
    steps.sort(key=lambda u: -u["duration_s"])
    return {"tool": "zig build --summary all", "steps": len(steps), "seconds_by_category": t,
            "note": "Zig reports a compile step as one number: frontend+codegen+link are NOT separable, all compile steps are filed under "
                    "'frontend'. 'run' steps (generators) are 'tools'. Cached steps are 0. Zig does not time package fetch here",
            "top_units": steps[:12]}


FLUTTER_RULES = [  # first match wins; the delta in front of a log line is attributed to what that line reports
    ("deps", r"pub get|pub\.dev|Resolving dependencies|\.pub-cache|pubspec"),
    ("frontend", r"kernel_snapshot|frontend_server|dart2js|dart2wasm|dartdevc|Wasm dry run|Compiled [\d,]+ input bytes|Compiling .*\.dart|compile.*\bdart\b|dill|analyz"),
    ("link", r"\blink\b|linking|Creating library|\.lib\b"),
    ("codegen", r"cmake|msbuild|ninja|\bcl\.exe|clang|\.cpp|\.obj\b|\.o\b|runner\.vcxproj|build\\windows|build/linux"),
]


def parse_flutter(trace, sd, since):
    t = dict.fromkeys(CATS, 0.0)
    gaps = []
    for f in glob.glob(str(pathlib.Path(trace) / "*.out")):
        for line in open(f, encoding="utf-8", errors="replace"):
            m = re.match(r"^\[\s*\+(\d+)\s*(ms|s)\s*\]\s*(.*)$", line.rstrip())
            if not m:
                continue
            d = float(m.group(1)) * (0.001 if m.group(2) == "ms" else 1.0)
            msg = m.group(3)
            cat = "tools"
            for c, rx in FLUTTER_RULES:
                if re.search(rx, msg, re.I):
                    cat = c
                    break
            t[cat] += d
            gaps.append({"name": msg[:110], "cat": cat, "duration_s": d})
    gaps.sort(key=lambda u: -u["duration_s"])
    return {"tool": "flutter -v timestamps", "seconds_by_category": t,
            "note": "heuristic: the gap printed in front of each `flutter -v` line is attributed by keyword to the activity that line reports "
                    "(unmatched = flutter tooling). Native (zig/cargo/go) steps inside a stack's build_dev are reported by their own tools. Approximate",
            "top_units": gaps[:15]}


def cmd_breakdown(tool, trace, sd, since):
    fn = {"cargo": parse_cargo, "go": parse_go, "zig": parse_zig, "flutter": parse_flutter}[tool]
    r = fn(trace, sd, float(since))
    lt = read_jsonl(pathlib.Path(trace) / "links.jsonl")   # harness/shims/link-timer output, when it was wired in
    if lt:
        r["link_timer"] = {"links": len(lt), "total_wall_s": round(sum(x["wall_s"] for x in lt), 3),
                           "max_peak_rss_mb": max((x.get("peak_rss_mb") or 0) for x in lt), "slowest": sorted(lt, key=lambda x: -x["wall_s"])[:5]}
        if tool == "cargo":   # cargo's timings fold linking into codegen; split it back out
            c = r["seconds_by_category"]
            c["link"] = r["link_timer"]["total_wall_s"]
            c["codegen"] = max(0.0, c["codegen"] - c["link"])
    r["seconds_by_category"] = {k: round(v, 3) for k, v in r["seconds_by_category"].items()}
    for u in r.get("top_units", []):
        u["duration_s"] = round(u["duration_s"], 3)
    print(json.dumps(r, indent=1))


# ---------------------------------------------------------------- contention (SPEC 9.6)
def cmd_contention(d):
    d = pathlib.Path(d)
    out = {}
    for cfg in sorted(p for p in d.iterdir() if p.is_dir() and p.name not in ("work", "solo-run") and not (p / "skipped.json").exists()):
        iters = []
        for f in cfg.glob("copy*/iter.jsonl"):
            iters += read_jsonl(f)
        by = {}
        for r in iters:
            by.setdefault(r["step"], []).append(r["wall_s"])
        ent = {"iterations": len(iters), "steps": {s: {"p50": pct(v, 50), "p95": pct(v, 95), "n": len(v)} for s, v in by.items()}}
        tot = read_jsonl(cfg / "total.jsonl")
        if tot:
            ent["total_wall_s"] = tot[-1].get("wall_s")
        ts = cfg / "timeseries.csv"
        if ts.exists():
            rows = [l.strip().split(",") for l in ts.read_text().splitlines()[1:] if l.strip()]
            hdr = ts.read_text().splitlines()[0].split(",")
            cols = {h: [float(r[i]) for r in rows if r[i] not in ("", "nan")] for i, h in enumerate(hdr)}
            for k in ("psi_cpu_avg10", "psi_mem_avg10", "psi_io_avg10"):
                if cols.get(k):
                    ent[k] = {"max": max(cols[k]), "mean": statistics.fmean(cols[k])}
            if cols.get("mem_used_mb"):
                ent["machine_mem_peak_mb"] = max(cols["mem_used_mb"])
            for k in ("pswpin", "pswpout"):
                if cols.get(k):
                    ent[k + "_delta"] = cols[k][-1] - cols[k][0]
        lat = cfg / "latency.json"
        if lat.exists():
            ent["wakeup_latency_ms"] = json.load(open(lat))
        out[cfg.name] = ent
    solo = {}
    sf = d / "solo.jsonl"
    for r in read_jsonl(sf):
        solo.setdefault(r["step"], []).append(r["wall_s"])
    for cfg, ent in out.items():
        for s, v in ent["steps"].items():
            if s in solo and v["p50"]:
                v["slowdown_p50_vs_solo"] = v["p50"] / pct(solo[s], 50)
    (d / "contention_summary.json").write_text(json.dumps(out, indent=1), encoding="utf-8")
    print(f"contention summary -> {d / 'contention_summary.json'}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    c = a[0]
    if c == "trim":
        cmd_trim(a[1], a[2])
    elif c == "summary":
        cmd_summary(a[1])
    elif c == "footprint":
        cmd_footprint(a[1], a[a.index("--baseline") + 1] if "--baseline" in a else None)
    elif c == "breakdown":
        cmd_breakdown(*a[1:5])
    elif c == "contention":
        cmd_contention(a[1])
    else:
        sys.exit(__doc__)

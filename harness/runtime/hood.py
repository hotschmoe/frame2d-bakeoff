#!/usr/bin/env python3
"""SPEC 8.8 under the hood: allocation stats (from cli.json), Go GC trace summaries, boundary table, binary composition
(bloaty if present; FALLBACK twiggy for wasm and LLVM tools for native, documented in the output), dependency footprint
(deps_report count + best-effort scc of dependency sources). Writes hood.json."""
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import f2d

a = f2d.cli_args("under the hood")
stack, out = a.stack, a.outp
conf = f2d.cfg(stack)
art = f2d.load_artifacts(stack, out)
log = out / "logs" / "hood.log"
res = {"stack": stack}
cli_json = f2d.jread(out / "cli.json") or {}

# ------------------------------------------------------------------------------------------ alloc stats
res["alloc_stats"] = cli_json.get("alloc_stats_8_8") or "run the `cli` section first"

# ------------------------------------------------------------------------------------------ Go GC trace
GC_RE = re.compile(r"gc (\d+) @([\d.]+)s (\d+)%: ([\d.]+)\+([\d.]+)\+([\d.]+) ms clock")


def gc_summary(text):
    pauses = []
    for m in GC_RE.finditer(text):
        a1, c1 = float(m.group(4)), float(m.group(6))  # sweep-termination and mark-termination STW phases
        pauses.append((a1, c1))
    if not pauses:
        return {"cycles": 0}
    stw = [x + y for x, y in pauses]
    return {"cycles": len(pauses), "total_stw_pause_ms": round(sum(stw), 4), "max_stw_pause_ms": round(max(max(x, y) for x, y in pauses), 4),
            "max_cycle_stw_ms": round(max(stw), 4), "note": "pause = STW phases of the gctrace 'ms clock' triple (first + third)"}


gc = {"enabled": conf["gctrace"]}
if conf["gctrace"].get("cli") and art.get("cli"):
    sizes = [50] if a.quick else [50, 200]
    gc["cli"] = {}
    for n in sizes:
        r = f2d.run_measured([art["cli"], "bench", str(n), str(n), "--reps", "1" if a.quick else "5"], env={"GODEBUG": "gctrace=1"}, timeout=3600)
        gc["cli"][f"{n}x{n}"] = gc_summary(r["stderr"] + r["stdout"])
        print(f"[{stack}] gctrace cli {n}x{n}: {gc['cli'][f'{n}x{n}']}", flush=True)
if conf["gctrace"].get("app") and art.get("desktop_exe"):
    r = f2d.run_app(art["desktop_exe"], "drag", env={"GODEBUG": "gctrace=1"}, timeout=900)
    s = gc_summary(r["gc_stderr"])
    s["drag_bench"] = r["bench"]
    s["drag_p99_ms"] = (r["bench"] or {}).get("p99")
    if s["cycles"] == 0:
        s["note"] = "no gctrace lines observed on stderr (app is a GUI process or the Go runtime is inside a c-shared library)"
    gc["app_drag"] = s
    print(f"[{stack}] gctrace app drag: {s}", flush=True)
res["go_gc"] = gc if (conf["gctrace"].get("cli") or conf["gctrace"].get("app")) else "n/a (not a Go-runtime engine path)"

# ------------------------------------------------------------------------------------------ boundary table
solve50 = ((cli_json.get("sizes") or {}).get("50x50") or {}).get("solve_ms")
bt = []


def brow(platform_, src_json, mode_med, mech, solve_p50):
    nn, tu = mode_med.get("noop_ns"), mode_med.get("transfer_us")
    share = None
    if tu is not None and solve_p50:
        share = round(tu / (solve_p50 * 1000), 6)
    bt.append({"platform": platform_, "noop_ns": nn, "transfer_us": tu, "mechanism": mech, "solve_p50_ms_used": solve_p50,
               "transfer_share_of_50x50_solve": share, "extra_fields": {k: v for k, v in mode_med.items() if k not in ("noop_ns", "transfer_us")}})


dj = f2d.jread(out / "desktop.json")
if dj and dj.get("modes", {}).get("boundary"):
    b = dj["modes"]["boundary"]
    drag = dj["modes"].get("drag", {}).get("median", {})
    brow("desktop", "desktop.json", b["median"], b.get("mechanism"), drag.get("solve_p50") or solve50)
for key, nm in (("web.json", "web (default build)"), ("web_alt.json", "web (alternate build)")):
    wj = f2d.jread(out / key)
    if wj and wj.get("modes_out", {}).get("boundary", {}).get("median"):
        b = wj["modes_out"]["boundary"]
        drag = wj["modes_out"].get("drag", {}).get("median", {})
        brow(nm + " [" + (wj.get("label") or "") + "]", key, b["median"], b.get("mechanism"), drag.get("solve_p50") or solve50)
if conf.get("bench_boundary_server") and art.get("server"):
    r = f2d.run_measured([art["server"], "bench-boundary"], timeout=300)
    bl = f2d.parse_bench_lines(r["stdout"] + "\n" + r["stderr"])
    bl = [x for x in bl if x.get("mode") == "boundary"] or bl
    if bl:
        brow("cgo (Go -> Zig, server bench-boundary)", "server", {k: v for k, v in bl[-1].items() if isinstance(v, (int, float))}, bl[-1].get("mechanism"), solve50)
    else:
        bt.append({"platform": "cgo (Go -> Zig, server bench-boundary)", "error": "no BENCH line: " + f2d.tail(r["stderr"] + r["stdout"], 3)})
res["boundary_table"] = bt
res["boundary_note"] = ("transfer share = transfer_us / (solve_p50_ms * 1000); solve_p50 is the same platform's drag solve_p50 when available, "
                        "else the CLI 50x50 solve_ms. Pure stacks have no language boundary on desktop; their web 'boundary' row is the WASM call path.")

# ------------------------------------------------------------------------------------ binary composition
LLVM_DIRS = [r"C:\Program Files\LLVM\bin", "/usr/lib/llvm/bin", "/usr/local/bin"] + [str(p) for p in Path("/usr/lib").glob("llvm-*/bin")] if True else []
tools = {
    "bloaty": f2d.find_tool("bloaty"), "twiggy": f2d.find_tool("twiggy"),
    "llvm-nm": f2d.find_tool("llvm-nm", extra_dirs=LLVM_DIRS), "llvm-size": f2d.find_tool("llvm-size", extra_dirs=LLVM_DIRS),
    "llvm-objdump": f2d.find_tool("llvm-objdump", extra_dirs=LLVM_DIRS), "nm": f2d.find_tool("nm"), "size": f2d.find_tool("size"),
}
comp = {"tools": tools, "grouping": "heuristic by symbol name: own | runtime_std | third_party | other (see classify() in hood.py)"}
if not tools["bloaty"]:
    comp["fallback"] = ("bloaty is not installed: wasm uses `twiggy top -n 30`, native binaries use LLVM tools (llvm-size -A sections; "
                        "llvm-nm --size-sort symbol sizes when the binary still has symbols). The release binaries are stripped, so native "
                        "symbol attribution is usually unavailable; real compile-unit attribution needs unstripped builds (TODO, needs per-stack flags).")
fam = conf["family"]


def classify(name):
    n = name.strip()
    if fam == "rust":
        if "frame2d" in n or n.startswith("engine::"):
            return "own"
        if re.match(r"^(<)?(std|core|alloc|hashbrown|compiler_builtins|rustc_demangle|backtrace|gimli|addr2line|object|miniz_oxide|memchr|panic_|__rust|__rdl|rust_)", n):
            return "runtime_std"
        return "third_party"
    if fam == "go":
        if n.startswith(("main.", "frame2d/", "type:.eq.main", "go:itab.main")) or "frame2d/" in n:
            return "own"
        first = re.sub(r"^(type:|go:itab\.|go:string\.)", "", n).split("/")[0].split(".")[0]
        if "." in n.split("/")[0] and not n.startswith(("runtime.", "internal.")):
            return "third_party"
        return "runtime_std"
    if fam == "zig":
        if re.match(r"^(std\.|debug\.|start\.|os\.|mem\.|fmt\.|heap\.|compiler_rt|__|_)", n):
            return "runtime_std"
        if re.match(r"^(sqlite3|SDL_|FT_|stbi|png_|hb_|dvui\.)", n):
            return "third_party"
        return "own"
    return "other"


def native_comp(path):
    if not path or not Path(path).exists():
        return None
    r = {"path": path, "bytes": f2d.file_size(path)}
    if tools["bloaty"]:
        for d in ("sections", "compileunits", "symbols"):
            p = subprocess.run([tools["bloaty"], "-d", d, "-n", "30", path], capture_output=True, text=True)
            r["bloaty_" + d] = p.stdout.splitlines()[:40]
        return r
    sz = tools["llvm-size"] or tools["size"]
    if sz:
        p = subprocess.run([sz, "-A", path] if tools["llvm-size"] else [sz, "-A", path], capture_output=True, text=True)
        secs = []
        for line in p.stdout.splitlines():
            m = re.match(r"^(\S+)\s+(\d+)\s+(\S+)$", line.strip())
            if m and m.group(1) != "Total":
                secs.append({"section": m.group(1), "bytes": int(m.group(2))})
        r["sections"] = sorted(secs, key=lambda s: -s["bytes"])[:16]
    nm = tools["llvm-nm"] or tools["nm"]
    if nm:
        p = subprocess.run([nm, "-S", "--size-sort", "-C", "--defined-only", path] if tools["llvm-nm"] else [nm, "-S", "--size-sort", "-C", "--defined-only", path],
                           capture_output=True, text=True)
        syms = []
        for line in p.stdout.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) == 4:
                try:
                    syms.append((int(parts[1], 16), parts[3]))
                except ValueError:
                    pass
        r["symbols_available"] = len(syms) > 50
        if r["symbols_available"]:
            g = defaultdict(int)
            for s, n in syms:
                g[classify(n)] += s
            r["grouped_bytes"] = dict(g)
            r["top_symbols"] = [{"bytes": s, "name": n[:140]} for s, n in sorted(syms, reverse=True)[:25]]
        else:
            r["symbols_note"] = "stripped: no usable symbol table"
    return r


def wasm_comp(wasm):
    if not wasm or not Path(wasm).exists():
        return None
    r = {"path": wasm, "bytes": f2d.file_size(wasm)}
    if tools["bloaty"]:
        p = subprocess.run([tools["bloaty"], "-d", "symbols", "-n", "30", wasm], capture_output=True, text=True)
        r["bloaty_symbols"] = p.stdout.splitlines()[:40]
    if tools["twiggy"]:
        p = subprocess.run([tools["twiggy"], "top", "-n", "30", "-f", "json", wasm], capture_output=True, text=True)
        try:
            items = json.loads(p.stdout)
            items = items if isinstance(items, list) else items.get("items", items)
            r["twiggy_top30"] = [{"name": i.get("name"), "shallow_size": i.get("shallow_size"), "shallow_pct": i.get("shallow_size_percent")} for i in items]
            g = defaultdict(int)
            named = [i for i in items if i.get("name") and not str(i["name"]).startswith(("code[", "data[", "custom section"))]
            for i in named:
                g[classify(str(i["name"]))] += i.get("shallow_size") or 0
            r["top30_grouped_bytes"] = dict(g)
            r["names_available"] = len(named) > 3
            if not r["names_available"]:
                r["note"] = "name section stripped: twiggy shows only code[N]/data[N] items, so no own/std/dependency grouping (TODO: needs an unstripped wasm build)"
        except Exception:  # noqa: BLE001
            p2 = subprocess.run([tools["twiggy"], "top", "-n", "30", wasm], capture_output=True, text=True)
            r["twiggy_top30_text"] = p2.stdout.splitlines()[:40]
            r["twiggy_error"] = f2d.tail(p.stderr, 3)
    return r


comp["cli"] = native_comp(art.get("cli"))
comp["server"] = native_comp(art.get("server"))
wasm = []
for key in ("web", "web_alt"):
    w = art.get(key)
    if not w:
        continue
    import fnmatch
    for rel in [p for p in Path(w["dist"]).rglob("*.wasm") if any(fnmatch.fnmatch(str(p.relative_to(w["dist"])).replace("\\", "/"), g) for g in conf["web_engine_globs"])][:1]:
        c = wasm_comp(str(rel))
        if c:
            c["web_build"] = w["label"]
            wasm.append(c)
    if key == "web" and wasm:
        pass
comp["wasm_engine"] = wasm
res["binary_composition"] = comp

# --------------------------------------------------------------------------------------------- dependencies
deps = {}
r = f2d.stack_fn(stack, "deps_report", log=log, timeout=900)
lines = sorted({l.strip() for l in r["lines"] if l.strip()})
deps["deps_report_rc"] = r["rc"]
deps["transitive_count"] = len(lines)
deps["list_head"] = lines[:60]
(out / "deps_report.txt").write_text("\n".join(lines) + "\n")
deps["note"] = ("count = unique non-empty lines of deps_report (formats differ per stack: some list name@version, some bare names; "
                "Flutter stacks include pub packages, Rust stacks include crates for host+wasm targets)")
scc = f2d.find_tool("scc")


def scc_dirs(dirs, test_filter=None, exact=False):
    """scc over dirs; exact=True keeps only files directly inside the listed dirs (Go packages: no nested packages)."""
    dirs = sorted({str(d) for d in dirs if Path(d).is_dir()})
    dset = {f2d.os.path.normcase(f2d.os.path.normpath(d)) for d in dirs}
    if not dirs or not scc:
        return None
    seen = {}
    for i in range(0, len(dirs), 40):
        p = subprocess.run([scc, "--by-file", "--format", "json", "--no-cocomo", "--no-complexity", *dirs[i:i + 40]], capture_output=True, text=True)
        for l in json.loads(p.stdout or "[]"):
            if l["Name"] in ("Markdown", "JSON", "YAML", "TOML", "Plain Text", "License", "Lockfile", "gitignore", "Document"):
                continue
            for f in l.get("Files", []):
                loc = f["Location"].replace("\\", "/")
                if test_filter and test_filter(loc):
                    continue
                if exact and f2d.os.path.normcase(f2d.os.path.normpath(str(Path(loc).parent))) not in dset:
                    continue
                seen[loc] = f["Code"]
    return {"files": len(seen), "code_lines": sum(seen.values()), "dirs": len(dirs)}


loc_kind = conf.get("deps_loc")
src_loc = {}
try:
    if loc_kind == "go":
        # packages used by the stack's binaries; module cache dirs only; tests excluded
        r2 = f2d.stack_fn(stack, "go list -deps -f '{{if and (not .Standard) .Module}}{{.Dir}}|{{.Module.Main}}{{end}}' ./cmd/... ./bridge/... 2>/dev/null", log=log, timeout=600)
        pk = [l.split("|")[0] for l in r2["lines"] if l.endswith("|false")]
        pk = [f2d.npath(p) for p in pk]
        src_loc["go_packages"] = scc_dirs(pk, test_filter=lambda p: p.endswith("_test.go"), exact=True)
        src_loc["go_package_dirs"] = len(pk)
        src_loc["note_go"] = "files directly inside each package dir returned by go list -deps (non-standard-library, non-main-module), _test.go excluded; cgo/asm files included, build-tag variants for other OSes included"
    elif loc_kind == "cargo":
        dirs = set()
        for flt in (None, "wasm32-unknown-unknown"):
            cmd = "cargo metadata --format-version 1 --offline --all-features" + (f" --filter-platform {flt}" if flt else "")
            r2 = f2d.stack_fn(stack, cmd, log=log, timeout=600)
            md = json.loads(r2["stdout"] or "{}")
            ids = {n["id"] for n in md.get("resolve", {}).get("nodes", [])}
            for p in md.get("packages", []):
                if p["id"] in ids and p.get("source"):
                    dirs.add(str(Path(f2d.npath(p["manifest_path"])).parent))
        src_loc["cargo_crates"] = scc_dirs(dirs, test_filter=lambda p: "/tests/" in p or "/benches/" in p or "/examples/" in p)
        src_loc["cargo_crate_dirs"] = len(dirs)
        src_loc["note_cargo"] = "registry crates in the resolve graph for host + wasm32 targets, whole crate sources excluding tests/benches/examples"
    elif loc_kind == "zig":
        sd = f2d.stack_dir(stack)
        cand = [d for base in (sd / "zig-pkg", sd / ".zig-global" / "p") if base.is_dir() for d in base.iterdir() if d.is_dir()]
        src_loc["zig_packages"] = scc_dirs(cand)
        src_loc["zig_package_dirs"] = len(cand)
    if conf.get("flutter"):
        pc = Path(f2d.os.environ.get("PUB_CACHE") or (Path(f2d.os.environ.get("LOCALAPPDATA", "")) / "Pub" / "Cache" if f2d.IS_WIN else Path.home() / ".pub-cache"))
        pdirs = []
        for l in lines:
            m = re.match(r"^(?:pub[: ])\s*([a-z0-9_]+)[ @]+(\d[^\s]*)", l)
            if m:
                d = pc / "hosted" / "pub.dev" / f"{m.group(1)}-{m.group(2)}"
                if d.is_dir():
                    pdirs.append(d)
        src_loc["pub_packages"] = scc_dirs(pdirs, test_filter=lambda p: "/test/" in p or "/example/" in p)
        src_loc["pub_package_dirs"] = len(pdirs)
        src_loc["note_pub"] = "hosted pub.dev packages found in the pub cache; Flutter SDK packages (flutter, flutter_test, sky_engine) are not included"
except Exception as e:  # noqa: BLE001
    src_loc["error"] = str(e)
src_loc["vendoring"] = "not done: sources are counted in place (module cache / cargo registry / zig packages / pub cache), nothing is vendored into the stack dirs"
deps["dependency_source_loc"] = src_loc
res["dependencies"] = deps
f2d.jwrite(out / "hood.json", res)
print(f"[{stack}] hood done: deps={deps['transitive_count']} boundary_rows={len(bt)} tools={ {k: bool(v) for k, v in tools.items()} }")

#!/usr/bin/env python3
"""report.py: turn the measurement records of one run/machine into SUMMARY.md + summary.json.

    python harness/report.py run1 win-arm64

Stdlib only. Reads results/<run>/<machine>/{runtime,buildloop,agent,review}/..., versions.md.
Every input is optional: a missing file or section shows as "n/a" and the stack simply has no value for
that metric (it is left out of that metric's normalisation and averages).

Scoring (SPEC 11): each metric is normalised to the best stack (best = 1.0; lower-is-better metrics score
(best+eps)/(value+eps), higher-is-better (value+eps)/(best+eps); eps is a small additive smoothing used
only for counts/rates that can legitimately be 0). A category is the mean of its groups; a group is the mean
of its metrics that exist for that stack. The overall score uses the SPEC 11 weights renormalised over the
categories that exist for the stack. Machine cost is Linux-only (SPEC 15.4) and is not scored here.
"""
import json
import os
import statistics
import sys

STACKS = ["rust", "zig", "go", "rust-flutter", "zig-flutter", "go-flutter", "go-zig-flutter"]
FLUTTER = {"rust-flutter", "zig-flutter", "go-flutter", "go-zig-flutter"}
EDITS = ["leaf", "struct", "server", "ui"]
COLD_TARGETS = ["cli", "server", "desktop", "web", "dev"]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# SPEC 11 weights (Machine cost omitted: Linux-only)
WEIGHTS = {"Build loop": 20, "Agent handling": 15, "Maintainability": 15, "Desktop": 10, "Web": 10,
           "Server": 10, "Binary size": 5, "Code size": 5}


# Known data problems found while reporting: (run, machine) -> [(stack, metric key, note)].
# The measured value is still shown (with the note) but is excluded from normalisation and scores.
KNOWN_ISSUES = {
    # run1/win-arm64 go-flutter and go-zig-flutter server sizes were first read after run_server had overwritten the
    # release binary; remeasured with `runtime/run.sh <stack> build binsize` (run.sh now always runs binsize before server).
}


# ----------------------------------------------------------------------------- helpers
def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def load_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def g(d, *keys, default=None):
    for k in keys:
        if isinstance(d, dict) and k in d:
            d = d[k]
        elif isinstance(d, list) and isinstance(k, int) and -len(d) <= k < len(d):
            d = d[k]
        else:
            return default
    return d if d is not None else default


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else None


def mean(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return sum(xs) / len(xs) if xs else None


def add(*xs):
    if any(x is None for x in xs):
        return None
    return sum(xs)


# ----------------------------------------------------------------------------- extraction
class Ctx:
    def __init__(self, run, machine):
        self.run, self.machine = run, machine
        self.base = os.path.join(ROOT, "results", run, machine)
        self.notes = {}      # (stack, key) -> note text
        self.excluded = {}   # stack -> set of metric keys left out of scoring
        self.global_notes = []

    def p(self, *parts):
        return os.path.join(self.base, *parts)

    def note(self, stack, key, text):
        self.notes[(stack, key)] = text


def extract_runtime(cx, s, m):
    rt = lambda f: load(cx.p("runtime", s, f))
    b = rt("binsize.json")
    if b:
        m["bin_cli"] = g(b, "cli", "bytes")
        m["bin_server"] = g(b, "server", "bytes")
        m["bin_desktop_bundle"] = g(b, "desktop", "bundle_bytes", default=g(b, "desktop", "exe_bytes"))
        lib = g(b, "desktop", "engine_lib_bytes")
        if lib is None:
            lib = g(b, "desktop", "engine_alone_proxy", "bytes")
            if lib is not None:
                cx.note(s, "bin_engine_lib", "pure stack: no separate engine library; the CLI binary is the proxy (harness/runtime README)")
        m["bin_engine_lib"] = lib
        m["bin_web_dir_br"] = g(b, "web", "total_br_bytes")
        m["bin_web_wasm_br"] = g(b, "web", "engine_wasm_br_bytes")
    w = rt("web.json")
    if w:
        sm = w.get("summary") or {}
        m["web_transferred_br"] = sm.get("transferred_br_bytes")
        m["web_uncompressed"] = sm.get("uncompressed_bytes")
        m["w_tti"] = sm.get("tti_ms")
        m["w_drag_p50"] = g(sm, "drag", "p50")
        m["w_drag_p99"] = g(sm, "drag", "p99")
        m["w_render_p50"] = g(sm, "render", "p50")
        m["w_solve_p50"] = sm.get("solve_p50_ms")
        m["w_runs"] = w.get("runs")
        ttis = [g(r, "bench", "tti_ms") for r in g(w, "modes_out", "ready", "runs", default=[])]
        ttis = [t for t in ttis if t is not None]
        m["w_tti_runs"] = ttis
        if ttis and m["w_tti"] and max(ttis) > 3 * m["w_tti"]:
            cx.note(s, "w_tti", "median %.0f ms, but one run took %.0f ms (reproducible first-load effect, seen again on rerun; see CAMPAIGN_LOG)" % (m["w_tti"], max(ttis)))
        m["w_gpu_software"] = g(w, "env", "software_rendering_suspected")
    paths = [f.get("path", "") for f in g(w, "manifest", "files", default=[])] if w else []
    if any(x.endswith("main.dart.wasm") for x in paths):
        m["web_flavor"] = "Flutter --wasm (skwasm)"
    elif any(x.endswith("main.dart.js") for x in paths):
        m["web_flavor"] = "Flutter dart2js (CanvasKit)"
    elif any(x.endswith(".wasm") for x in paths):
        m["web_flavor"] = "native wasm app"
    else:
        m["web_flavor"] = None
    d = rt("desktop.json")
    if d:
        md = d.get("modes") or {}
        m["d_runs"] = d.get("runs_per_mode")
        m["d_startup"] = g(md, "startup", "median", "first_frame_ms")
        m["d_drag_p50"] = g(md, "drag", "median", "p50")
        m["d_drag_p99"] = g(md, "drag", "median", "p99")
        m["d_render_p50"] = g(md, "render", "median", "p50")
        m["d_drag_rss"] = g(md, "drag", "median", "peak_rss_mb_tree_sampled", default=g(md, "drag", "median", "rss_mb"))
        m["d_render_rss"] = g(md, "render", "median", "peak_rss_mb_tree_sampled", default=g(md, "render", "median", "rss_mb"))
        m["d_renderer"] = "; ".join(d.get("renderer_lines") or [])[:120]
        if m["d_runs"] and m["d_runs"] != 3:
            cx.note(s, "d_drag_p50", "%s runs per mode instead of 3 (benchmarked before the reduced-protocol instruction)" % m["d_runs"])
    c = rt("cli.json")
    if c:
        sz = c.get("sizes") or {}
        m["c_reps"] = c.get("reps")
        for n in ("10x10", "50x50", "100x100", "200x200"):
            r = sz.get(n)
            if not r:
                continue
            k = n.split("x")[0]
            m["c%s_fs" % k] = add(r.get("factor_ms"), r.get("solve_ms"))
            m["c%s_factor" % k] = r.get("factor_ms")
            m["c%s_solve" % k] = r.get("solve_ms")
            m["c%s_rss" % k] = r.get("peak_rss_mb")
            if n == "10x10" and any(r.get(x) == 0 for x in ("assemble_ms", "factor_ms", "solve_ms")):
                cx.note(s, "c10_fs", "a 0.000 ms phase at 10x10: timer resolution")
    sv = rt("server.json")
    if sv:
        o = sv.get("oha") or {}
        m["s_rps"] = o.get("rps")
        m["s_p50"] = o.get("p50_ms")
        m["s_p99"] = o.get("p99_ms")
        m["s_cpu1000"] = o.get("cpu_s_per_1000_req")
        m["s_peak_rss"] = o.get("peak_rss_mb")
        m["s_threads"] = o.get("peak_threads")
        m["s_idle_rss"] = sv.get("idle_rss_mb")
        m["s_sweep200_wall"] = g(sv, "sweep_200_gen50x50", "wall_s")
        m["s_sweep1000_wall"] = g(sv, "sweep_1000_gen10x10", "wall_s")
        m["s_sweep200_cores"] = g(sv, "sweep_200_gen50x50", "avg_cores_busy")
        m["s_success"] = o.get("success_rate")
        if m["s_sweep1000_wall"] is not None and m["s_sweep1000_wall"] < 0.1:
            cx.note(s, "s_sweep1000_wall", "under 0.1 s: close to timer resolution")
        if m["s_sweep200_wall"] is not None and m["s_sweep200_wall"] < 0.5:
            cx.note(s, "s_sweep200_wall", "under 0.5 s: coarse (single HTTP request, 3 phases, no repeat)")
    lc = rt("loc.json")
    if lc:
        t = lc.get("totals_code") or {}
        m["l_engine"], m["l_ui"], m["l_server"], m["l_glue"], m["l_tests"] = (t.get(k) for k in ("engine", "ui", "server", "glue", "tests"))
        m["l_total"] = t.get("total_excluding_generated")
        m["l_generated"] = lc.get("generated_code_not_in_totals")


def extract_buildloop(cx, s, m):
    bd = cx.p("buildloop", s)
    sm = load(os.path.join(bd, "summary.json")) or {}

    def stat(label, what="wall_s", q="p50"):
        return g(sm, label, what, q)

    for t in COLD_TARGETS:
        m["cold_" + t] = stat("cold-" + t)
        m["cold_%s_cpu" % t] = stat("cold-" + t, "cpu_s")
        m["cold_%s_n" % t] = g(sm, "cold-" + t, "wall_s", "n")
    for e in EDITS:
        for k in ("check", "dev"):
            m["%s_%s" % (e, k)] = stat("edit-%s-%s" % (e, k))
            m["%s_%s_cpu" % (e, k)] = stat("edit-%s-%s" % (e, k), "cpu_s")
            m["%s_%s_mem" % (e, k)] = stat("edit-%s-%s" % (e, k), "mem_peak_mb")
    for k in ("check", "dev"):
        m["noop_" + k] = stat("noop-" + k)
        m["mean_" + k] = mean([m.get("%s_%s" % (e, k)) for e in EDITS]) if all(m.get("%s_%s" % (e, k)) is not None for e in EDITS) else None
    reps = [r for r in load_jsonl(os.path.join(bd, "hotreload.jsonl")) if r.get("kind") == "rep"]
    m["hot_reload"] = med([r.get("file_write_to_reloaded_s") for r in reps])
    m["hot_reload_reps"] = [r.get("file_write_to_reloaded_s") for r in reps]
    eng = [r for r in load_jsonl(os.path.join(bd, "engine-e2e.jsonl")) if r.get("ok")]
    m["engine_e2e"] = med([r.get("edit_to_first_frame_s") for r in eng])
    m["engine_build"] = med([r.get("build_wall_s") for r in eng])
    m["engine_launch"] = med([r.get("launch_to_first_frame_s") for r in eng])
    if s == "go" and m.get("cold_server") is not None:
        cx.note(s, "cold_server", "first attempt stalled (35.3 s, external); target rerun, rerun values used (CAMPAIGN_LOG)")
    if s == "go-zig-flutter":
        for k in ("leaf_check", "leaf_dev", "noop_check", "noop_dev"):
            cx.note(s, k, "build_check/build_dev redo every step, so no-op ~ edit (CAMPAIGN_LOG)")
    m["sections"] = {name: g(load(os.path.join(bd, "sections", name + ".json")), "status") for name in ("cold", "edits", "hotreload", "engine")}
    m["bl_failures"] = sum((v or {}).get("failures", 0) or 0 for v in sm.values() if isinstance(v, dict)) if sm else None


def extract_agent(cx, stacks, M):
    met = load(cx.p("agent", "metrics.json")) or {}
    tax = load(cx.p("agent", "taxonomy.json")) or {}
    ds = load(cx.p("agent", "diffstat.json")) or {}
    recs = {(r["stack"], r["phase"]): r for r in met.get("records", [])}
    for s in stacks:
        m = M[s]
        ph = {p: recs.get((s, p)) for p in ("P1", "P2", "P3")}
        m["a_phases"] = {p: {k: r.get(k) for k in ("wall_corrected_s", "wall_raw_s", "stall_s", "turns", "tool_calls", "build_invocations", "failed_builds",
                                                     "pure_build_wait_s", "pure_build_wait_fraction_of_corrected_wall", "test_runs", "failed_test_runs",
                                                     "failures_total", "interventions", "est_cost_usd")} for p, r in ph.items() if r}
        if ph["P1"] and ph["P2"]:
            P1, P2 = ph["P1"], ph["P2"]
            m["a_p1_wall"] = P1["wall_corrected_s"]
            m["a_p2_wall"] = P2["wall_corrected_s"]
            m["a_ttg"] = P1["wall_corrected_s"] + P2["wall_corrected_s"]
            m["a_turns"] = P1["turns"] + P2["turns"]
            m["a_failed_builds"] = P1["failed_builds"] + P2["failed_builds"]
            m["a_cost"] = P1["est_cost_usd"] + P2["est_cost_usd"]
            m["a_interventions"] = P1["interventions"] + P2["interventions"]
            m["a_buildwait_frac"] = P1.get("pure_build_wait_fraction_of_corrected_wall")
            m["a_builds"] = P1["build_invocations"] + P2["build_invocations"]
        elif ph["P3"]:
            P3 = ph["P3"]
            m["a_p3_wall"] = P3["wall_corrected_s"]
            m["a_p3_stall"] = P3["stall_s"]
            m["a_p3_turns"] = P3["turns"]
            m["a_p3_failed_builds"] = P3["failed_builds"]
            m["a_p3_cost"] = P3["est_cost_usd"]
            m["a_p3_interventions"] = P3["interventions"]
            m["a_p3_builds"] = P3["build_invocations"]
        t = next((x for x in tax.get("stacks", []) if x["stack"] == s), None)
        if t:
            m["a_tax_count"] = t.get("count")
            m["a_tax_minutes"] = t.get("minutes")
            m["a_failures_classified"] = t.get("total_classified_failures")
            m["a_false_positive"] = t.get("false_positive")
            m["a_tax_builds"] = t.get("builds")
            m["a_stale100"] = t.get("stale_api_per_100_builds")
            cc = t.get("caught_share_count") or {}
            if t.get("total_classified_failures"):
                m["a_caught_share"] = cc
                m["a_late_share"] = (cc.get("harness") or 0) + (cc.get("runtime_manual") or 0)
            else:
                m["a_caught_share"] = {}
                m["a_late_share"] = 0.0
            m["a_tax_total_minutes"] = t.get("total_minutes")
        for row in ds.get("rows", []):
            if row["stack"] == s:
                d = row["diff"]
                m["p2_phase"] = row["phase"]
                m["p2_added"], m["p2_removed"], m["p2_files"] = d.get("added"), d.get("removed"), d.get("files")
                m["p2_lines"] = add(d.get("added"), d.get("removed"))
                m["p2_ttg"] = row.get("time_to_green_wall_s")
                m["p2_failed_builds"] = row.get("failed_builds")
                m["p2_builds"] = row.get("builds")
        rv = load(cx.p("review", s + ".json"))
        if rv:
            sc = rv.get("scores") or {}
            for k, v in sc.items():
                m["rev_" + k] = v
            m["rev_mean"] = mean(list(sc.values()))
            m["rev_notable"] = rv.get("notable")


def extract_all(cx):
    M = {s: {} for s in STACKS}
    for s in STACKS:
        extract_runtime(cx, s, M[s])
        extract_buildloop(cx, s, M[s])
    extract_agent(cx, STACKS, M)
    for st, key, text in KNOWN_ISSUES.get((cx.run, cx.machine), []):
        if M.get(st, {}).get(key) is not None:
            cx.notes[(st, key)] = text
            cx.excluded.setdefault(st, set()).add(key)
    if M["go-zig-flutter"].get("a_p3_wall") is not None:
        cx.note("go-zig-flutter", "a_p3_wall", "P3 only")
    return M


# ----------------------------------------------------------------------------- formatting
def f_bytes(v):
    if v is None:
        return "n/a"
    return "%.2f MB" % (v / 1e6) if v >= 1e6 else "%.0f KB" % (v / 1e3)


def f_num(dec=1, unit=""):
    def f(v):
        return "n/a" if v is None else ("%." + str(dec) + "f%s") % (v, unit)
    return f


def f_int(v):
    return "n/a" if v is None else "%d" % round(v)


def f_pct(v):
    return "n/a" if v is None else "%.0f%%" % (100 * v)


def f_dur(v):
    if v is None:
        return "n/a"
    if v < 60:
        return "%.1f s" % v
    if v < 3600:
        return "%.1f min" % (v / 60)
    return "%.2f h" % (v / 3600)


def f_s(v):
    return "n/a" if v is None else ("%.2f s" % v if v < 100 else "%.0f s" % v)


def f_ms(v):
    if v is None:
        return "n/a"
    return "%.3f ms" % v if v < 1 else ("%.1f ms" % v if v < 1000 else "%.0f ms" % v)


def f_usd(v):
    return "n/a" if v is None else "$%.2f" % v


def f_mb(v):
    return "n/a" if v is None else ("%.0f MB" % v if v >= 100 else "%.1f MB" % v)


def f_rps(v):
    return "n/a" if v is None else "%.0f" % v


def f_score(v):
    return "n/a" if v is None else "%.3f" % v


class Col:
    def __init__(self, key, header, fmt, direction=None):
        self.key, self.header, self.fmt, self.direction = key, header, fmt, direction


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" if i == 0 else "---:" for i in range(len(headers))) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def best_value(vals, direction):
    xs = [v for v in vals if isinstance(v, (int, float)) and v > 0]
    if not xs or direction is None:
        return None
    return min(xs) if direction == "low" else max(xs)


def metric_table(cx, M, cols, footnotes=None):
    """one row per stack; best value per column bold; footnotes collects note texts"""
    best = {c.key: best_value([M[s].get(c.key) for s in STACKS if c.key not in cx.excluded.get(s, ())], c.direction) for c in cols}
    rows = []
    for s in STACKS:
        row = [s]
        for c in cols:
            v = M[s].get(c.key)
            txt = c.fmt(v)
            if v is not None and best[c.key] is not None and v == best[c.key] and c.key not in cx.excluded.get(s, ()) and sum(1 for x in STACKS if M[x].get(c.key) is not None) > 1:
                txt = "**%s**" % txt
            n = cx.notes.get((s, c.key))
            if n and footnotes is not None:
                if n not in footnotes:
                    footnotes.append(n)
                txt += " [%d]" % (footnotes.index(n) + 1)
            row.append(txt)
        rows.append(row)
    return md_table(["stack"] + [c.header for c in cols], rows)


def foot(footnotes):
    return "\n".join("[%d] %s" % (i + 1, t) for i, t in enumerate(footnotes))


# ----------------------------------------------------------------------------- scoring
# metric registry: key -> (direction, eps)
SCORING = {
    "bin_cli": ("low", 0), "bin_server": ("low", 0), "bin_desktop_bundle": ("low", 0), "bin_engine_lib": ("low", 0), "web_transferred_br": ("low", 0),
    **{"cold_" + t: ("low", 0) for t in COLD_TARGETS},
    "leaf_check": ("low", 0), "leaf_dev": ("low", 0), "struct_check": ("low", 0), "struct_dev": ("low", 0),
    "noop_check": ("low", 0), "noop_dev": ("low", 0), "a_buildwait_frac": ("low", 0.01),
    "d_startup": ("low", 0), "d_drag_p50": ("low", 0), "d_drag_p99": ("low", 0), "d_render_p50": ("low", 0), "d_drag_rss": ("low", 0),
    "c50_fs": ("low", 0), "c200_fs": ("low", 0), "c200_rss": ("low", 0),
    "w_tti": ("low", 0), "w_drag_p50": ("low", 0), "w_render_p50": ("low", 0), "w_drag_p99": ("low", 0),
    "s_rps": ("high", 0), "s_p99": ("low", 0), "s_cpu1000": ("low", 0), "s_peak_rss": ("low", 0), "s_idle_rss": ("low", 0), "s_sweep200_wall": ("low", 0),
    "l_engine": ("low", 50), "l_ui": ("low", 50), "l_server": ("low", 50), "l_glue": ("low", 50),
    "a_ttg": ("low", 0), "a_turns": ("low", 0), "a_failed_builds": ("low", 1), "a_cost": ("low", 0), "a_interventions": ("low", 1),
    "a_stale100": ("low", 1), "a_late_share": ("low", 0.05),
    "p2_lines": ("low", 0), "p2_files": ("low", 0), "p2_ttg": ("low", 0), "p2_failed_builds": ("low", 1),
    **{"rev_" + k: ("high", 0) for k in ("structure", "naming", "errors", "boundary", "tests", "change_resilience")},
}

REV_KEYS = ["rev_" + k for k in ("structure", "naming", "errors", "boundary", "tests", "change_resilience")]

# category -> list of groups -> metric keys
CATEGORIES = {
    "Build loop": [["cold_cli", "cold_server", "cold_desktop", "cold_web", "cold_dev",
                    "leaf_check", "leaf_dev", "struct_check", "struct_dev", "noop_check", "noop_dev", "a_buildwait_frac"]],
    "Agent handling": [["a_ttg", "a_turns", "a_failed_builds", "a_cost", "a_interventions", "a_stale100", "a_late_share"]],
    "Maintainability": [["p2_lines", "p2_files", "p2_ttg", "p2_failed_builds"], REV_KEYS],
    "Desktop": [["d_startup", "d_drag_p50", "d_drag_p99", "d_render_p50", "d_drag_rss", "c50_fs", "c200_fs", "c200_rss"]],
    "Web": [["w_tti", "w_drag_p50", "w_drag_p99", "w_render_p50"]],
    "Server": [["s_rps", "s_p99", "s_cpu1000", "s_peak_rss", "s_idle_rss", "s_sweep200_wall"]],
    "Binary size": [["bin_cli", "bin_server", "bin_desktop_bundle", "bin_engine_lib", "web_transferred_br"]],
    "Code size": [["l_engine", "l_ui", "l_server", "l_glue"]],
}
HUMAN_GROUPS = {
    "Binary size": ["bin_cli", "bin_server", "bin_desktop_bundle", "bin_engine_lib", "web_transferred_br"],
    "Cold build": ["cold_cli", "cold_server", "cold_desktop", "cold_web", "cold_dev"],
    "Warm build": ["leaf_check", "leaf_dev", "struct_check", "struct_dev", "noop_check", "noop_dev"],
    "In-app performance": ["d_startup", "d_drag_p50", "d_drag_p99", "d_render_p50", "w_tti", "w_drag_p50", "w_drag_p99", "w_render_p50"],
    "Resources": ["s_cpu1000", "s_peak_rss", "s_idle_rss", "d_drag_rss"],
}
# stacks excluded from a metric because the measurement is a different task (P3 only)
NOT_COMPARABLE = {
    "go-zig-flutter": {"a_ttg", "a_turns", "a_failed_builds", "a_cost", "a_interventions", "a_stale100", "a_late_share", "a_buildwait_frac",
                       "p2_lines", "p2_files", "p2_ttg", "p2_failed_builds"},
}


def normalise(M, key, excluded=None):
    excluded = excluded or {}
    d, eps = SCORING[key]
    vals = {}
    for s in STACKS:
        v = M[s].get(key)
        if not isinstance(v, (int, float)) or key in NOT_COMPARABLE.get(s, ()) or key in excluded.get(s, ()):
            continue
        if v > 0 or (eps > 0 and v >= 0):
            vals[s] = v
    if not vals:
        return {}
    if d == "low":
        best = min(vals.values())
        return {s: (best + eps) / (v + eps) for s, v in vals.items()}
    best = max(vals.values())
    return {s: (v + eps) / (best + eps) for s, v in vals.items()}


def score_group(N, s, keys):
    xs = [N[k][s] for k in keys if k in N and s in N[k]]
    return (mean(xs), len(xs)) if xs else (None, 0)


def compute_scores(M, excluded=None):
    N = {k: normalise(M, k, excluded) for k in SCORING}
    cat = {s: {} for s in STACKS}
    cat_n = {s: {} for s in STACKS}
    for c, groups in CATEGORIES.items():
        for s in STACKS:
            gs, n = [], 0
            for keys in groups:
                v, k = score_group(N, s, keys)
                if v is not None:
                    gs.append(v)
                    n += k
            cat[s][c] = mean(gs)
            cat_n[s][c] = n
    overall, overall_noagent = {}, {}
    for s in STACKS:
        for out, skip in ((overall, ()), (overall_noagent, ("Agent handling",))):
            num = den = 0.0
            for c, w in WEIGHTS.items():
                if c in skip or cat[s][c] is None:
                    continue
                num += w * cat[s][c]
                den += w
            out[s] = num / den if den else None
    human_cat = {s: {gname: score_group(N, s, keys)[0] for gname, keys in HUMAN_GROUPS.items()} for s in STACKS}
    human = {s: mean([v for v in human_cat[s].values() if v is not None]) for s in STACKS}
    return N, cat, cat_n, overall, overall_noagent, human_cat, human


# ----------------------------------------------------------------------------- SUMMARY.md
def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def bold_max(vals, s, fmt):
    xs = [v for v in vals.values() if v is not None]
    v = vals[s]
    return ("**%s**" % fmt(v)) if (v is not None and xs and v == max(xs)) else fmt(v)


def build_summary(cx, M, scores):
    N, cat, cat_n, overall, overall_noagent, human_cat, human = scores
    L = []
    w = L.append
    w("# Frame2D bake-off: %s on %s" % (cx.run, cx.machine))
    w("")
    w("Generated by `python harness/report.py %s %s`. Every number below is also in `summary.json`." % (cx.run, cx.machine))
    w("")
    w("## Caveats (read first)")
    w("")
    w("- **Emulation.** Flutter (Dart SDK, engine, the desktop app and its engine DLL) and the Playwright Chromium run **x64-emulated** on this ARM64 Windows laptop; the pure stacks (rust, zig, go) are native arm64. Flutter-vs-pure numbers are not a like-for-like language comparison here. Compare Flutter stacks with each other, and pure stacks with each other.")
    w("- **Reduced protocol (human-approved).** Runtime benches 3 runs (SPEC: 5); edit builds hyperfine 3 runs + 1 warmup (SPEC: 10 + 1); **cold builds 2 runs** (SPEC: 3, so the cold p50 is the mean of two); hot reload / engine edit 3 reps; oha 30 s as in SPEC. zig-flutter `cli`/`desktop` have 5 runs. Medians are the headline; SPEC p95/p99 of builds are not meaningful at n=3.")
    w("- **Trimmed scope.** Measured: binary size, code size, CLI/desktop/web/server runtime, cold builds, edit builds, no-op, hot reload (Flutter), engine-edit-to-app (Flutter). **Not measured:** cross-compile (8.7), under-the-hood (8.8), alternate web builds, cache footprint (9.4), build breakdown (9.5), tuned variants / Zig incremental (9.3), contention (9.6), whole-run accounting (9.7). Machine cost is Linux-only (SPEC 15.4) and is not scored. zig-flutter's extra hood/xcompile/web_alt data is ignored.")
    w("- **Agent runs overlapped** (up to 3 at once, SPEC 2.10 deviation), so agent wall times and build waits are indicative only. Agent cost is an assumed Sonnet-class list-price estimate (harness/agentlog README). One fresh classifier labelled the failures of all stacks.")
    w("- **Windows accounting.** Build `cpu_s` and peak memory come from psutil sampling (50 ms) and under-count short-lived children; server CPU-seconds have ~15.6 ms resolution.")
    w("- **Web.** Headless Chromium uses SwiftShader (software GL), same flags for all. Web build flavor differs by stack: " +
      ", ".join("%s = %s" % (s, M[s].get("web_flavor") or "n/a") for s in STACKS) + ".")
    w("- **go-zig-flutter** is a P3 variant of go-flutter (Zig engine, Go server). It has no P1/P2 agent run of its own, so it has no Agent-handling or P2 change-request scores (its P3 numbers are shown separately). Its first edits pass was invalid and was rerun; only the rerun is in the results.")
    w("- **Scores are indicative.** One run, one machine, small n, concurrent agents. Toolchain versions are frozen in `results/%s/versions.md`." % cx.run)
    w("")

    fn = []
    w("## Headline (one row per stack)")
    w("")
    w("Four tables with the same row order. Best value per column is **bold**. `[n]` marks a footnote under the table.")
    w("")
    w("### A. Binary size")
    w("")
    w(metric_table(cx, M, [
        Col("bin_cli", "CLI", f_bytes, "low"), Col("bin_server", "server", f_bytes, "low"),
        Col("bin_desktop_bundle", "desktop bundle", f_bytes, "low"), Col("bin_engine_lib", "engine lib", f_bytes, "low"),
        Col("web_transferred_br", "web transferred (br)", f_bytes, "low"), Col("bin_web_dir_br", "web dist total (br)", f_bytes, "low"),
    ], footnotes=fn))
    w("")
    w(foot(fn))
    w("")
    w("### B. Build loop (p50 of 2 cold runs / 3 edit runs)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("cold_cli", "cold CLI", f_s, "low"), Col("cold_server", "cold server", f_s, "low"), Col("cold_desktop", "cold desktop", f_s, "low"),
        Col("cold_web", "cold web", f_s, "low"), Col("cold_dev", "cold dev", f_s, "low"),
        Col("leaf_check", "leaf build_check", f_s, "low"), Col("leaf_dev", "leaf build_dev", f_s, "low"),
        Col("mean_check", "mean-of-edits build_check", f_s, "low"), Col("mean_dev", "mean-of-edits build_dev", f_s, "low"),
        Col("noop_dev", "no-op dev", f_s, "low"), Col("hot_reload", "hot reload (ui)", f_s, "low"), Col("engine_e2e", "engine edit to app", f_s, "low"),
    ], footnotes=fn))
    w("")
    w("mean-of-edits = mean of the p50 over the four edits (leaf, struct, server, ui). Hot reload and engine-edit-to-app exist only for Flutter stacks; hot reload only where the stack defines `hot_reload_probe` (n/a elsewhere).")
    w("")
    w(foot(fn))
    w("")
    w("### C. Desktop and web")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("d_drag_p50", "desktop drag p50", f_ms, "low"), Col("d_render_p50", "desktop render p50", f_ms, "low"),
        Col("d_startup", "desktop startup", f_ms, "low"), Col("d_drag_rss", "desktop drag RSS (tree)", f_mb, "low"),
        Col("w_tti", "web TTI", f_ms, "low"), Col("w_drag_p50", "web drag p50", f_ms, "low"), Col("w_render_p50", "web render p50", f_ms, "low"),
    ], footnotes=fn))
    w("")
    w(foot(fn))
    w("")
    w("### D. CLI and server")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("c50_fs", "CLI 50x50 factor+solve", f_ms, "low"), Col("c200_fs", "CLI 200x200 factor+solve", f_ms, "low"), Col("c200_rss", "CLI 200x200 peak RSS", f_mb, "low"),
        Col("s_rps", "server req/s", f_rps, "high"), Col("s_p99", "server p99", f_ms, "low"), Col("s_cpu1000", "CPU-s / 1000 req", f_num(1), "low"),
        Col("s_peak_rss", "server peak RSS", f_mb, "low"), Col("s_idle_rss", "server idle RSS", f_mb, "low"), Col("s_sweep200_wall", "sweep 200x50x50 wall", f_s, "low"),
    ], footnotes=fn))
    w("")
    w(foot(fn))
    w("")

    w("## Per-category tables")
    w("")
    w("### Binary size (SPEC 8.6)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("bin_cli", "CLI", f_bytes, "low"), Col("bin_server", "server", f_bytes, "low"), Col("bin_desktop_bundle", "desktop bundle", f_bytes, "low"),
        Col("bin_engine_lib", "engine lib", f_bytes, "low"), Col("web_transferred_br", "web transferred br", f_bytes, "low"),
        Col("web_uncompressed", "web uncompressed (loaded)", f_bytes, "low"), Col("bin_web_dir_br", "web dist total br", f_bytes, "low"),
        Col("bin_web_wasm_br", "engine .wasm br", f_bytes, "low")], footnotes=fn))
    w("")
    w(foot(fn))
    w("")
    w("Pure stacks: the desktop \"bundle\" is the single exe, the \"engine lib\" is the CLI binary (proxy), and the web app is the wasm. Flutter bundles are dominated by `flutter_windows.dll` (~21 MB), so the engine lib column is the meaningful comparison there. Release binaries are not necessarily stripped (see `binsize.json` flags).")
    w("")
    w("### Build loop (SPEC 9.1, 9.2), seconds")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("cold_cli", "cold CLI", f_s, "low"), Col("cold_server", "cold server", f_s, "low"), Col("cold_desktop", "cold desktop", f_s, "low"),
        Col("cold_web", "cold web", f_s, "low"), Col("cold_dev", "cold dev", f_s, "low")], footnotes=fn))
    w("")
    w(metric_table(cx, M, [
        Col("leaf_check", "leaf check", f_s, "low"), Col("leaf_dev", "leaf dev", f_s, "low"),
        Col("struct_check", "struct check", f_s, "low"), Col("struct_dev", "struct dev", f_s, "low"),
        Col("server_check", "server check", f_s, "low"), Col("server_dev", "server dev", f_s, "low"),
        Col("ui_check", "ui check", f_s, "low"), Col("ui_dev", "ui dev", f_s, "low"),
        Col("noop_check", "no-op check", f_s, "low"), Col("noop_dev", "no-op dev", f_s, "low")], footnotes=fn))
    w("")
    w("Per-edit CPU (SPEC 9.4; psutil p50 `cpu_s`, wall in brackets) and peak memory of the leaf dev build:")
    w("")
    rows = []
    for s in STACKS:
        m = M[s]
        rows.append([s] + ["%s (%s)" % (f_s(m.get(k + "_cpu")), f_s(m.get(k))) for k in ("leaf_check", "leaf_dev", "struct_dev")] + [f_mb(m.get("leaf_dev_mem"))])
    w(md_table(["stack", "leaf check cpu_s (wall)", "leaf dev cpu_s (wall)", "struct dev cpu_s (wall)", "leaf dev peak mem"], rows))
    w("")
    w("Build `cpu_s` is psutil-sampled and clearly under-counts toolchains that spawn short-lived children (e.g. go and zig-flutter `build_dev` show cpu_s below wall); treat it as a lower bound, not a SPEC 9.4 cgroup number.")
    w("")
    w("Flutter extras (3 reps, median): hot reload = file write to reloaded event (`ui` edit; the first rep includes warm-up); engine edit to app = `leaf` edit, `build_dev`, launch the debug app to first frame.")
    w("")
    rows = []
    for s in STACKS:
        m = M[s]
        if s in FLUTTER:
            reps = m.get("hot_reload_reps") or []
            rows.append([s, f_s(m.get("hot_reload")), ", ".join("%.2f" % x for x in reps if x is not None) or "n/a", f_s(m.get("engine_build")),
                         f_s(m.get("engine_launch")), f_s(m.get("engine_e2e"))])
    w(md_table(["stack", "hot reload", "reps (s)", "engine build_dev", "launch to first frame", "engine edit to app"], rows))
    w("")
    w(foot(fn))
    w("")
    w("### Desktop performance (SPEC 8.3)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("d_startup", "startup", f_ms, "low"), Col("d_drag_p50", "drag p50", f_ms, "low"), Col("d_drag_p99", "drag p99", f_ms, "low"),
        Col("d_render_p50", "render p50", f_ms, "low"), Col("d_drag_rss", "drag RSS", f_mb, "low"), Col("d_render_rss", "render RSS", f_mb, "low")], footnotes=fn))
    w("")
    w("CLI (`frame2d bench`, median of reps; time = factor + solve):")
    w("")
    w(metric_table(cx, M, [
        Col("c10_fs", "10x10", f_ms, "low"), Col("c50_fs", "50x50", f_ms, "low"), Col("c100_fs", "100x100", f_ms, "low"), Col("c200_fs", "200x200", f_ms, "low"),
        Col("c50_rss", "50x50 RSS", f_mb, "low"), Col("c200_rss", "200x200 RSS", f_mb, "low")], footnotes=fn))
    w("")
    w(foot(fn))
    w("")
    w("Renderer lines the apps print: " + "; ".join("%s: %s" % (s, M[s].get("d_renderer") or "(none reported)") for s in STACKS))
    w("")
    w("### Web performance (SPEC 8.4)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("w_tti", "TTI", f_ms, "low"), Col("w_drag_p50", "drag p50", f_ms, "low"), Col("w_drag_p99", "drag p99", f_ms, "low"),
        Col("w_render_p50", "render p50", f_ms, "low"), Col("w_solve_p50", "50x50 wasm solve p50 (drag)", f_ms, "low")], footnotes=fn))
    w("")
    w("TTI of each run (ms): " + "; ".join("%s: %s" % (s, ", ".join("%.0f" % x for x in M[s].get("w_tti_runs", [])) or "n/a") for s in STACKS))
    w("")
    w(foot(fn))
    w("")
    w("### Server performance (SPEC 8.5)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("s_rps", "req/s", f_rps, "high"), Col("s_p50", "p50", f_ms, "low"), Col("s_p99", "p99", f_ms, "low"), Col("s_cpu1000", "CPU-s/1000 req", f_num(1), "low"),
        Col("s_peak_rss", "peak RSS", f_mb, "low"), Col("s_idle_rss", "idle RSS", f_mb, "low"), Col("s_threads", "peak threads", f_int, "low"),
        Col("s_sweep200_wall", "sweep 200x50x50", f_s, "low"), Col("s_sweep200_cores", "cores busy (sweep)", f_num(1), "high"),
        Col("s_sweep1000_wall", "sweep 1000x10x10", f_s, "low")], footnotes=fn))
    w("")
    w(foot(fn))
    w("")
    w("### Code size (SPEC 8.2, lines of code, generated excluded)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("l_engine", "engine (incl. CLI)", f_int, "low"), Col("l_ui", "ui", f_int, "low"), Col("l_server", "server", f_int, "low"),
        Col("l_glue", "glue", f_int, "low"), Col("l_tests", "tests", f_int), Col("l_total", "total", f_int, "low"), Col("l_generated", "generated (not in totals)", f_int)], footnotes=fn))
    w("")
    w(foot(fn))
    w("")

    w("## Agent handling (SPEC 8.1)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("a_p1_wall", "P1 time to green", f_dur, "low"), Col("a_p2_wall", "P2 time to green", f_dur, "low"), Col("a_turns", "turns P1+P2", f_int, "low"),
        Col("a_builds", "build/check calls", f_int), Col("a_failed_builds", "failed builds", f_int, "low"), Col("a_cost", "est. cost P1+P2", f_usd, "low"),
        Col("a_interventions", "interventions", f_int, "low"), Col("a_buildwait_frac", "build-wait share of P1 (pure)", f_pct, "low")], footnotes=fn))
    w("")
    gz = M["go-zig-flutter"]
    w("go-zig-flutter P3 (not comparable; Zig engine swap on top of go-flutter): " +
      ("wall %s (stall-corrected, a %s stall removed), %s turns, %s build/check calls, %s failed, est. cost %s, %s interventions." % (
          f_dur(gz.get("a_p3_wall")), f_dur(gz.get("a_p3_stall")), f_int(gz.get("a_p3_turns")), f_int(gz.get("a_p3_builds")),
          f_int(gz.get("a_p3_failed_builds")), f_usd(gz.get("a_p3_cost")), f_int(gz.get("a_p3_interventions"))) if gz.get("a_p3_wall") is not None else "n/a"))
    w("")
    w(foot(fn))
    w("")
    w("### Failure taxonomy (every classified failed build, check, test or conformance run)")
    w("")
    cats = ["type", "ownership", "concurrency_types", "comptime_sema", "strictness", "stale_api", "ffi", "link", "build_config", "runtime_crash", "wrong_result"]
    used = [c for c in cats if any((M[s].get("a_tax_count") or {}).get(c) for s in STACKS)]
    rows = []
    for s in STACKS:
        m = M[s]
        cnt = m.get("a_tax_count")
        if cnt is None:
            rows.append([s] + ["n/a"] * (len(used) + 2))
            continue
        mins = m.get("a_tax_minutes") or {}
        rows.append([s] + ["%d (%.1f min)" % (cnt.get(c, 0), mins.get(c, 0)) if cnt.get(c) else "0" for c in used] +
                    [str(m.get("a_failures_classified")), f_num(1)(m.get("a_tax_total_minutes"))])
    w(md_table(["stack"] + used + ["total classified", "minutes lost"], rows))
    w("")
    w("Categories with no failures anywhere are omitted. go-zig-flutter is P3 only; others are P1+P2. Minutes = time from the first failure to the next success of that kind.")
    w("")
    w("### Where bugs were caught, and stale_api rate")
    w("")
    rows = []
    for s in STACKS:
        m = M[s]
        cs = m.get("a_caught_share")
        if m.get("a_tax_count") is None:
            rows.append([s, "n/a", "n/a", "n/a", "n/a", "n/a", "n/a"])
        elif not cs:
            rows.append([s, "0 failures", "-", "-", "-", f_int(m.get("a_tax_builds")), f_num(1)(m.get("a_stale100"))])
        else:
            rows.append([s, f_pct(cs.get("compile")), f_pct(cs.get("own_tests")), f_pct(cs.get("harness")), f_pct(cs.get("runtime_manual")),
                         f_int(m.get("a_tax_builds")), f_num(1)(m.get("a_stale100"))])
    w(md_table(["stack", "compile/check", "own tests", "harness (conformance/goldens)", "runtime/manual", "builds (denominator)", "stale_api / 100 builds"], rows))
    w("")
    w("Shares are by count of classified failures. \"Late\" = harness + runtime/manual; that sum feeds the scorecard. Small counts (go 0, go-zig-flutter 2, rust 6) make the shares very noisy.")
    w("")

    w("## Maintainability")
    w("")
    w("### Change request (SPEC 10.1: P2 diff against the P1 tag; the go-zig-flutter row is the P3 diff)")
    w("")
    rows = []
    for s in STACKS:
        m = M[s]
        rows.append([s, m.get("p2_phase") or "n/a", f_int(m.get("p2_added")), f_int(m.get("p2_removed")), f_int(m.get("p2_files")), f_dur(m.get("p2_ttg")),
                     f_int(m.get("p2_failed_builds")), f_int(m.get("p2_builds"))])
    w(md_table(["stack", "phase", "lines added", "lines removed", "files touched", "time to green", "failed builds", "builds"], rows))
    w("")
    w("### Review (SPEC 10.2, 1-5, fresh agent)")
    w("")
    fn = []
    w(metric_table(cx, M, [
        Col("rev_structure", "structure", f_int, "high"), Col("rev_naming", "naming", f_int, "high"), Col("rev_errors", "errors", f_int, "high"),
        Col("rev_boundary", "boundary", f_int, "high"), Col("rev_tests", "tests", f_int, "high"), Col("rev_change_resilience", "change resilience", f_int, "high"),
        Col("rev_mean", "mean", f_num(2), "high")], footnotes=fn))
    w("")
    w("### Reviewer-notable findings")
    w("")
    for s in STACKS:
        nt = M[s].get("rev_notable")
        if nt:
            w("- **%s**" % s)
            for x in nt:
                w("  - " + x)
    w("")

    sc_names = list(WEIGHTS)
    w("## Scorecard (SPEC 11)")
    w("")
    w("Method: each metric is normalised to the best stack (best = 1.0; lower-is-better = best/value, higher-is-better = value/best; counts and rates that can be 0 use additive smoothing, eps in brackets). A category is the mean of its metrics (Maintainability: mean of the P2-change-request half and the review half); a stack missing a metric is left out of that average. The overall score uses the SPEC 11 weights renormalised over the measured categories (Machine cost, weight 10, omitted): " +
      ", ".join("%s %d" % (c, wt) for c, wt in WEIGHTS.items()) + ".")
    w("")
    w("Metrics feeding each category:")
    w("")
    for c, groups in CATEGORIES.items():
        desc = [", ".join("`%s`%s" % (k, " (eps %g)" % SCORING[k][1] if SCORING[k][1] else "") for k in keys) for keys in groups]
        w("- **%s**: %s" % (c, "  /  *half 2:*  ".join(desc)))
    w("")
    w("Key: `cold_*` cold builds (2 runs); `leaf_/struct_` check/dev = edit medians; `noop_*` = rebuild with no change; `a_buildwait_frac` = share of P1 wall spent blocked on builds; `a_ttg` = P1+P2 stall-corrected time to green; `a_late_share` = harness + runtime/manual share of failures; `d_*` desktop app; `c50_fs`/`c200_fs`/`c200_rss` = CLI factor+solve and peak RSS; `w_*` web; `s_*` server; `p2_*` = P2 change request; `rev_*` = review scores (value/best on the 1-5 scale); `l_*` = lines of code (tests excluded). go-zig-flutter has no value for the agent-handling, build-wait and P2 metrics (P3-only) and is scored on the rest.")
    w("")
    w("### SPEC-weight scorecard (higher is better, max 1.0)")
    w("")
    rows = []
    for s in STACKS:
        rows.append([s] + [f_score(cat[s][c]) for c in sc_names] + [bold_max(overall, s, f_score), f_score(overall_noagent[s])])
    w(md_table(["stack"] + ["%s (%d)" % (c, WEIGHTS[c]) for c in sc_names] + ["**overall**", "overall excl. Agent handling"], rows))
    w("")
    w("`overall excl. Agent handling` drops that category for every stack; it is the only total that is like-for-like for go-zig-flutter (whose `overall` is re-weighted over fewer categories, so it is not comparable with the others). Number of metrics behind each category score: " +
      "; ".join("%s: %s" % (s, ", ".join("%d" % cat_n[s][c] for c in sc_names)) for s in STACKS) + " (order as the columns).")
    w("")
    w("### Human-priority scorecard (binary size, cold build, warm build, in-app performance, resources; equal weights)")
    w("")
    w("Groups: " + "; ".join("**%s**: %s" % (gname, ", ".join("`%s`" % k for k in keys)) for gname, keys in HUMAN_GROUPS.items()) +
      ". Normalisation as above, each group is the mean of its metrics, the five groups weighted equally. \"Resources\" = server CPU-s per 1000 req, server peak and idle RSS, desktop drag RSS.")
    w("")
    rows = []
    for s in STACKS:
        rows.append([s] + [f_score(human_cat[s][gname]) for gname in HUMAN_GROUPS] + [bold_max(human, s, f_score)])
    w(md_table(["stack"] + list(HUMAN_GROUPS) + ["**human-priority score**"], rows))
    w("")
    w("Both scores are shown on purpose. The gap between them shows how much the SPEC weights (agent handling, maintainability, code size) matter to the ranking.")
    w("")

    w("## How to read this")
    w("")
    w("- **Flutter vs pure** is confounded by x64 emulation of Flutter and Chromium on this ARM64 machine (desktop startup, frame times, web numbers, Flutter build times). Compare Flutter stacks with each other; the engine-bound CLI and server numbers are the cleanest cross-stack comparison.")
    w("- **Web flavor differs** (see caveats): TTI and transferred bytes include the dart2js/CanvasKit vs `--wasm`/skwasm choice, not only the engine language.")
    w("- **Zig render p50 mostly measures draw-command building**; a very low render p50 does not mean the solve is fast. Look at drag p50 and the CLI numbers for the engine.")
    w("- **go-zig-flutter dev loop:** its `build_check`/`build_dev` redo every step regardless of input, so no-op ~ edit (CAMPAIGN_LOG). Its numbers are the real per-call cost, not a measure of incremental compilation.")
    w("- **Cold builds** use 2 runs (p50 = mean of two) and can include first-run cache effects. Treat differences under ~30% as noise.")
    w("- **Flutter desktop drag/render p50** is partly frame pacing (vsync-like 16-30 ms) and the emulated compositor; `solve_p50` inside is the engine part.")
    w("- **Server** runs through each stack's own `run_server`; for go and go-zig-flutter that builds a dev-profile binary (unstripped Go server, ReleaseSafe Zig lib). That is what is measured. Go servers show GB-scale peak RSS under 64 connections of a 50x50 solve.")
    w("- **Agent-handling** numbers come from concurrent runs; P2 times of 1-3 minutes are a handful of tool calls, so P2 deltas are small-n.")
    w("")
    if cx.global_notes:
        w("## Data notes")
        w("")
        for n in cx.global_notes:
            w("- " + n)
        w("")
    return "\n".join(L) + "\n"


# ----------------------------------------------------------------------------- main
def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if len(args) != 2:
        print("usage: python harness/report.py <run> <machine>   e.g. run1 win-arm64", file=sys.stderr)
        return 2
    run, machine = args
    cx = Ctx(run, machine)
    if not os.path.isdir(cx.base):
        print("no such results dir: " + cx.base, file=sys.stderr)
        return 1
    M = extract_all(cx)
    for s in STACKS:
        if not M[s]:
            cx.global_notes.append("%s: no data found" % s)
        else:
            for k in ("cold_cli", "leaf_check", "d_drag_p50", "w_tti", "s_rps", "bin_cli"):
                if M[s].get(k) is None:
                    cx.global_notes.append("%s: `%s` missing (shown as n/a)" % (s, k))
    for st, key, text in KNOWN_ISSUES.get((run, machine), []):
        if key in cx.excluded.get(st, ()):
            cx.global_notes.append("%s `%s`: %s" % (st, key, text))
    scores = compute_scores(M, cx.excluded)
    N, cat, cat_n, overall, overall_noagent, human_cat, human = scores

    md = build_summary(cx, M, scores)
    with open(os.path.join(cx.base, "SUMMARY.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write(md)

    js = {
        "run": run, "machine": machine,
        "metrics": M,
        "notes": {"%s|%s" % k: v for k, v in cx.notes.items()},
        "scoring": {
            "weights_spec": WEIGHTS, "metric_direction_eps": {k: list(v) for k, v in SCORING.items()},
            "categories": CATEGORIES, "human_groups": HUMAN_GROUPS,
            "not_comparable": {k: sorted(v) for k, v in NOT_COMPARABLE.items()},
            "excluded_known_issues": {k: sorted(v) for k, v in cx.excluded.items()},
            "normalised": N, "category_scores": cat, "category_metric_counts": cat_n,
            "overall_spec_weights": overall, "overall_excl_agent_handling": overall_noagent,
            "human_priority_groups": human_cat, "human_priority_score": human,
        },
        "data_notes": cx.global_notes,
    }
    with open(os.path.join(cx.base, "summary.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(js, f, indent=1)
    print("wrote %s and summary.json" % os.path.join(cx.base, "SUMMARY.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main())

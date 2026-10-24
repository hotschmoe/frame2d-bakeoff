#!/usr/bin/env python3
"""SPEC 8.1 agent-handling metrics from session transcripts.

usage: python harness/agentlog/metrics.py [--run run1] [--machine win-arm64] [--price-file prices.json]
Writes results/<run>/<machine>/agent/metrics.json and metrics.md.  See README.md for heuristics.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

STACK_ORDER = ["rust", "zig", "go", "rust-flutter", "zig-flutter", "go-flutter", "go-zig-flutter"]


def agent_log_interventions(stack):
    p = os.path.join(C.ROOT, "stacks", stack, "AGENT_LOG.md")
    if not os.path.exists(p):
        return None
    txt = open(p, encoding="utf-8", errors="replace").read()
    m = re.search(r"^##\s*Human interventions[^\n]*\n(.*?)(?=^##\s|\Z)", txt, re.S | re.M)
    return m.group(1).strip()[:1500] if m else None


def hms(sec):
    sec = int(round(sec))
    return "%d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def analyse(stack, phase, path, prices):
    s = C.parse_session(path)
    wall_raw = (s.t_last - s.t_first).total_seconds()
    stall = sum(x["seconds"] for x in s.stalls)
    cmds = [c for c in s.calls if c.kinds and c.ran]

    def kind(k):
        return [c for c in cmds if k in c.kinds]

    builds = [c for c in cmds if "build" in c.kinds or "check" in c.kinds]
    tests = kind("test")
    conf = kind("conformance")
    pure = [c for c in builds if set(c.kinds) <= {"build", "check"} and C.is_pure_build(c.cmd)]
    wait_pure = sum(max(0.0, c.block_dur - C.overlap_stall(s, c.t0, c.t_res)) for c in pure)
    wait = sum(max(0.0, c.dur - C.overlap_stall(s, c.t0, c.t1)) for c in builds)
    tok = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0, "cache_write_5m": 0, "cache_write_1h": 0}
    for u in s.usage.values():
        tok["input"] += u.get("input_tokens", 0) or 0
        tok["output"] += u.get("output_tokens", 0) or 0
        tok["cache_read"] += u.get("cache_read_input_tokens", 0) or 0
        cc = u.get("cache_creation_input_tokens", 0) or 0
        tok["cache_creation"] += cc
        split = u.get("cache_creation") or {}
        w5 = split.get("ephemeral_5m_input_tokens", 0) or 0
        w1 = split.get("ephemeral_1h_input_tokens", 0) or 0
        if w5 + w1 == 0:
            w5 = cc
        tok["cache_write_5m"] += w5
        tok["cache_write_1h"] += w1
    interventions = []
    for n, (i, t, k, text) in enumerate(s.users):
        if n == 0:
            continue  # kickoff
        if C.is_orchestrator_text(k, text):
            interventions.append({"ts": C.iso(t), "kind": k, "text": text[:300]})
    corr = wall_raw - stall
    return {
        "stack": stack, "phase": phase, "file": os.path.basename(path),
        "start": C.iso(s.t_first), "end": C.iso(s.t_last),
        "wall_raw_s": wall_raw, "stall_s": stall, "wall_corrected_s": corr,
        "stalls": [{"start": C.iso(x["start"]), "end": C.iso(x["end"]), "seconds": x["seconds"]} for x in s.stalls],
        "turns": len(s.usage),
        "tool_calls": len(s.calls), "tool_calls_by_tool": dict(sorted(s.tool_counts.items())),
        "build_invocations": len(builds),
        "build_invocations_by_kind": {"build": len(kind("build")), "check": len(kind("check"))},
        "failed_builds": sum(1 for c in builds if c.kind_failed),
        "build_wait_s": wait,
        "build_wait_fraction_of_corrected_wall": wait / corr if corr > 0 else None,
        "pure_build_invocations": len(pure),
        "pure_build_wait_s": wait_pure,
        "pure_build_wait_fraction_of_corrected_wall": wait_pure / corr if corr > 0 else None,
        "test_runs": len(tests), "failed_test_runs": sum(1 for c in tests if c.kind_failed),
        "conformance_runs": len(conf), "failed_conformance_runs": sum(1 for c in conf if c.kind_failed),
        "failures_total": sum(1 for c in cmds if c.failed),
        "runtime_crash_markers": sum(1 for c in cmds if c.failed and not c.kind_failed),
        "background_commands": sum(1 for c in cmds if c.bg),
        "interventions": len(interventions), "intervention_detail": interventions,
        "agent_log_human_interventions_section": agent_log_interventions(stack),
        "tokens": tok, "est_cost_usd": C.cost(tok, prices),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="run1")
    ap.add_argument("--machine", default="win-arm64")
    ap.add_argument("--price-file")
    a = ap.parse_args()
    prices = dict(C.PRICES_PER_MTOK)
    if a.price_file:
        prices.update(json.load(open(a.price_file)))
    rd = os.path.join(C.ROOT, "results", a.run, a.machine)
    out = os.path.join(rd, "agent")
    os.makedirs(out, exist_ok=True)
    recs = [analyse(st, ph, p, prices) for st, ph, p in C.transcript_files(rd)]
    recs.sort(key=lambda r: (STACK_ORDER.index(r["stack"]) if r["stack"] in STACK_ORDER else 99, r["phase"]))
    json.dump({"run": a.run, "machine": a.machine, "prices_usd_per_mtok": prices,
               "price_note": "ASSUMED Sonnet-class list prices; claude-sonnet-5-5 prices not verified. Advisor (Opus) tokens not in transcripts.",
               "stall_threshold_s": C.STALL_S, "records": recs}, open(os.path.join(out, "metrics.json"), "w"), indent=1)
    L = ["# Agent handling metrics (SPEC 8.1)", "",
         "Run `%s`, machine `%s`. Generated by `harness/agentlog/metrics.py`; do not edit." % (a.run, a.machine), "",
         "Price table (USD per Mtok, ASSUMED, unverified for sonnet-5-5): " + ", ".join("%s=%s" % kv for kv in prices.items()), "",
         "Wall = first to last transcript timestamp. Corrected = minus gaps > %d min. Builds = build+check commands; wait = their tool_use->result time (stall-clipped). 'All' includes composite commands (build + bench/test in one shell call), so it is an upper bound; 'pure' counts only commands that are build/check plus trivial glue, and only the time the agent was blocked (background completion excluded). Heuristics: see README." % (C.STALL_S // 60), "",
         "| stack | phase | wall raw | wall corr | turns | tool calls | builds (b/c) | failed builds | build wait (all) | wait/wall | pure builds | pure wait | pure/wall | tests | failed | conf runs | failed | interv. | in tok | out tok | cache read | cache write | est $ |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in recs:
        t = r["tokens"]
        bk = r["build_invocations_by_kind"]
        frac = r["build_wait_fraction_of_corrected_wall"]
        L.append("| %s | %s | %s | %s | %d | %d | %d (%d/%d) | %d | %s | %s | %d | %s | %s | %d | %d | %d | %d | %d | %d | %d | %d | %d | %.2f |" % (
            r["stack"], r["phase"], hms(r["wall_raw_s"]), hms(r["wall_corrected_s"]), r["turns"], r["tool_calls"],
            r["build_invocations"], bk["build"], bk["check"], r["failed_builds"], hms(r["build_wait_s"]),
            ("%.0f%%" % (100 * frac)) if frac is not None else "-", r["pure_build_invocations"], hms(r["pure_build_wait_s"]),
            ("%.0f%%" % (100 * r["pure_build_wait_fraction_of_corrected_wall"])) if r["pure_build_wait_fraction_of_corrected_wall"] is not None else "-", r["test_runs"], r["failed_test_runs"],
            r["conformance_runs"], r["failed_conformance_runs"], r["interventions"], t["input"], t["output"],
            t["cache_read"], t["cache_creation"], r["est_cost_usd"]))
    L += ["", "## Tool calls by tool", "", "| stack | phase | tools |", "|---|---|---|"]
    for r in recs:
        L.append("| %s | %s | %s |" % (r["stack"], r["phase"], ", ".join("%s %d" % kv for kv in r["tool_calls_by_tool"].items())))
    L += ["", "## Stalls (gaps > %d min between consecutive events)" % (C.STALL_S // 60), ""]
    any_stall = False
    for r in recs:
        for x in r["stalls"]:
            any_stall = True
            L.append("- %s %s: %s -> %s (%s)" % (r["stack"], r["phase"], x["start"], x["end"], hms(x["seconds"])))
    if not any_stall:
        L.append("- none")
    L += ["", "## Interventions (non-kickoff user/orchestrator messages in the transcript)", ""]
    n_int = 0
    for r in recs:
        for x in r["intervention_detail"]:
            n_int += 1
            L.append("- %s %s %s [%s]: %s" % (r["stack"], r["phase"], x["ts"], x["kind"], x["text"].replace("\n", " ")[:200]))
    if not n_int:
        L.append("- none")
    L += ["", "AGENT_LOG.md `Human interventions` sections (cross-check; one per stack, covers all phases):", ""]
    seen = set()
    for r in recs:
        if r["stack"] in seen:
            continue
        seen.add(r["stack"])
        sec = r["agent_log_human_interventions_section"]
        L.append("- %s: %s" % (r["stack"], (sec or "(no section)").replace("\n", " ")[:300]))
    open(os.path.join(out, "metrics.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("wrote", os.path.join(out, "metrics.json"))


if __name__ == "__main__":
    main()

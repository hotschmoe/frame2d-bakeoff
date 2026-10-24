#!/usr/bin/env python3
"""SPEC 10.1 change-request metrics: P2 diff (p1-done-<stack>..p2-done-<stack>) restricted to stacks/<stack>/,
generated code excluded (stack LOC_EXCLUDE + generic generated-file patterns).  P3 diff for go-zig-flutter
(fork-go-zig-flutter..p3-done-go-zig-flutter) is reported alongside.

usage: python harness/agentlog/diffstat.py [--run run1] [--machine win-arm64]
Writes results/<run>/<machine>/agent/diffstat.json and diffstat.md (needs metrics.json from metrics.py).
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

STACKS = ["rust", "zig", "go", "rust-flutter", "zig-flutter", "go-flutter", "go-zig-flutter"]
# generic generated / non-code files, matched against the path relative to the stack dir
GENERIC_GENERATED = ["*frb_generated*", "*.g.dart", "*.freezed.dart", "*engine_bindings*.dart", "*/generated/*", "generated/*",
                     "*.lock", "go.sum", "pubspec.lock", "Cargo.lock", "*/ffigen/*", "ffigen/*", ".tools/*", "*.png", "*.ico", "*.jpg"]
NOTES = ["AGENT_LOG.md"]  # agent's own notes: neither code nor generated, excluded from the counts


def git(*args):
    return subprocess.run(["git", "-C", C.ROOT] + list(args), capture_output=True, text=True, encoding="utf-8").stdout


def loc_exclude(stack):
    p = os.path.join(C.ROOT, "stacks", stack, "LOC_EXCLUDE")
    out = []
    if os.path.exists(p):
        for l in open(p, encoding="utf-8"):
            l = l.strip()
            if l and not l.startswith("#"):
                out.append(l)
    return out


def excluded(rel, patterns):
    for pat in patterns:
        q = pat.rstrip("/")
        if rel == q or rel.startswith(q + "/") or fnmatch.fnmatch(rel, pat):
            return True
    return False


def diff(stack, a, b):
    if not git("rev-parse", "--verify", "-q", a).strip() or not git("rev-parse", "--verify", "-q", b).strip():
        return None
    pats = loc_exclude(stack)
    res = {"from": a, "to": b, "added": 0, "removed": 0, "files": 0, "added_all": 0, "removed_all": 0, "files_all": 0,
           "excluded_files": [], "notes_files": [], "touched": []}
    for line in git("diff", "--numstat", a, b, "--", "stacks/" + stack).splitlines():
        ad, rm, path = line.split("\t", 2)
        rel = path[len("stacks/%s/" % stack):]
        ad = 0 if ad == "-" else int(ad)
        rm = 0 if rm == "-" else int(rm)
        res["added_all"] += ad
        res["removed_all"] += rm
        res["files_all"] += 1
        if rel in NOTES:
            res["notes_files"].append(rel)
            continue
        if excluded(rel, pats) or excluded(rel, GENERIC_GENERATED):
            res["excluded_files"].append({"path": rel, "added": ad, "removed": rm})
            continue
        res["added"] += ad
        res["removed"] += rm
        res["files"] += 1
        res["touched"].append({"path": rel, "added": ad, "removed": rm})
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="run1")
    ap.add_argument("--machine", default="win-arm64")
    a = ap.parse_args()
    out = os.path.join(C.ROOT, "results", a.run, a.machine, "agent")
    mpath = os.path.join(out, "metrics.json")
    metrics = {}
    if os.path.exists(mpath):
        for r in json.load(open(mpath))["records"]:
            metrics[(r["stack"], r["phase"])] = r
    rows = []
    for st in STACKS:
        row = {"stack": st}
        ph = "P3" if st == "go-zig-flutter" else "P2"
        row["phase"] = ph
        if st == "go-zig-flutter":
            row["diff"] = diff(st, "fork-go-zig-flutter", "p3-done-go-zig-flutter")
            row["note"] = "P3 diff = fork..p3-done (a different change than the P2 spring-support CR; not comparable with the P2 rows)"
        else:
            row["diff"] = diff(st, "p1-done-" + st, "p2-done-" + st)
        m = metrics.get((st, ph))
        if m:
            row["time_to_green_wall_s"] = m["wall_corrected_s"]
            row["time_to_green_raw_s"] = m["wall_raw_s"]
            row["failed_builds"] = m["failed_builds"]
            row["builds"] = m["build_invocations"]
            row["failed_tests"] = m["failed_test_runs"]
            row["failed_conformance"] = m["failed_conformance_runs"]
        rows.append(row)
    json.dump({"run": a.run, "machine": a.machine, "rows": rows}, open(os.path.join(out, "diffstat.json"), "w"), indent=1)
    L = ["# Change request metrics (SPEC 10.1)", "",
         "P2 = diff `p1-done-<stack>..p2-done-<stack>` restricted to `stacks/<stack>/`; go-zig-flutter row is P3 (`fork-go-zig-flutter..p3-done-go-zig-flutter`).",
         "Excluded from counts: the stack's `LOC_EXCLUDE`, generic generated patterns (%s), and `AGENT_LOG.md`. Raw git numstat totals are shown in the last columns." % ", ".join(GENERIC_GENERATED),
         "Time to green = agent transcript wall time, stall-corrected (raw in brackets). Failed builds = failed build/check commands in that phase (metrics.py heuristics).", "",
         "| stack | phase | lines added | lines removed | files touched | time to green | failed builds / builds | failed tests | failed conformance | excluded files | raw +/- (all files) |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        d = r["diff"]
        if not d:
            L.append("| %s | %s | (tag missing) |" % (r["stack"], r["phase"]))
            continue
        ttg = r.get("time_to_green_wall_s")
        raw = r.get("time_to_green_raw_s")
        L.append("| %s | %s | %d | %d | %d | %s | %s | %s | %s | %d | +%d/-%d (%d files) |" % (
            r["stack"], r["phase"], d["added"], d["removed"], d["files"],
            ("%.1f min (raw %.1f)" % (ttg / 60, raw / 60)) if ttg is not None else "-",
            ("%d / %d" % (r["failed_builds"], r["builds"])) if "failed_builds" in r else "-",
            r.get("failed_tests", "-"), r.get("failed_conformance", "-"), len(d["excluded_files"]), d["added_all"], d["removed_all"], d["files_all"]))
    L += ["", "## Files touched", ""]
    for r in rows:
        d = r["diff"]
        if not d:
            continue
        L.append("- **%s %s**: %s" % (r["stack"], r["phase"], ", ".join("%s (+%d/-%d)" % (t["path"], t["added"], t["removed"]) for t in d["touched"][:60])))
        if d["excluded_files"]:
            L.append("  - excluded as generated/non-code: %s" % ", ".join("%s (+%d/-%d)" % (t["path"], t["added"], t["removed"]) for t in d["excluded_files"][:30]))
    open(os.path.join(out, "diffstat.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("wrote diffstat.json / diffstat.md")


if __name__ == "__main__":
    main()

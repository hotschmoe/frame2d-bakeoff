#!/usr/bin/env python3
"""Aggregate classifier output into the SPEC 8.1 failure-taxonomy tables.

usage: python harness/agentlog/aggregate.py [--run run1] [--machine win-arm64] [--agent-dir DIR]
Reads   <agent-dir>/classified/<stack>-<phase>.json   (written by the classifier agents)
        <agent-dir>/digests/<stack>-<phase>.json      (failure ids, timing; from digest.py)
        <agent-dir>/metrics.json                      (build counts; from metrics.py)
Writes  <agent-dir>/taxonomy.json and taxonomy.md.  Missing classified files are reported as coverage gaps.
"""
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

CATEGORIES = ["type", "ownership", "concurrency_types", "comptime_sema", "strictness", "stale_api", "ffi", "link",
              "build_config", "runtime_crash", "wrong_result"]
EXTRA = ["false_positive"]  # not counted anywhere except the coverage report
CAUGHT = ["compile", "own_tests", "harness", "runtime_manual"]
STACK_ORDER = ["rust", "zig", "go", "rust-flutter", "zig-flutter", "go-flutter", "go-zig-flutter"]


def load_json(p):
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="run1")
    ap.add_argument("--machine", default="win-arm64")
    ap.add_argument("--agent-dir")
    a = ap.parse_args()
    ad = a.agent_dir or os.path.join(C.ROOT, "results", a.run, a.machine, "agent")
    metrics = {}
    mp = os.path.join(ad, "metrics.json")
    if os.path.exists(mp):
        for r in load_json(mp)["records"]:
            metrics[(r["stack"], r["phase"])] = r
    digests = {}
    for f in sorted(glob.glob(os.path.join(ad, "digests", "*.json"))):
        d = load_json(f)
        digests[(d["stack"], d["phase"])] = d
    problems = []
    stacks = {}  # stack -> aggregate
    coverage = []
    for (st, ph), d in sorted(digests.items()):
        cp = os.path.join(ad, "classified", "%s-%s.json" % (st, ph))
        by_id = {x["id"]: x for x in d["failures"]}
        agg = stacks.setdefault(st, {"stack": st, "phases": [], "builds": 0, "failures": 0, "classified": 0, "false_positive": 0,
                                     "count": {c: 0 for c in CATEGORIES}, "minutes": {c: 0.0 for c in CATEGORIES},
                                     "caught_count": {c: 0 for c in CAUGHT}, "caught_minutes": {c: 0.0 for c in CAUGHT},
                                     "unscored_minutes_fallback": 0})
        agg["phases"].append(ph)
        m = metrics.get((st, ph))
        if m:
            agg["builds"] += m["build_invocations"]
        agg["failures"] += d["n_failures"]
        if not os.path.exists(cp):
            coverage.append({"stack": st, "phase": ph, "failures": d["n_failures"], "classified": None,
                             "status": "no classified file" if d["n_failures"] else "nothing to classify"})
            continue
        items = load_json(cp)
        seen = set()
        n_ok = 0
        for it in items:
            iid = it.get("id")
            if iid not in by_id:
                problems.append("%s-%s: unknown failure id %r" % (st, ph, iid))
                continue
            if iid in seen:
                problems.append("%s-%s: duplicate id %s" % (st, ph, iid))
                continue
            seen.add(iid)
            cat = it.get("category")
            if cat == "false_positive":
                agg["false_positive"] += 1
                n_ok += 1
                continue
            if cat not in CATEGORIES:
                problems.append("%s-%s %s: bad category %r" % (st, ph, iid, cat))
                continue
            ca = it.get("caught_at")
            if ca not in CAUGHT:
                problems.append("%s-%s %s: bad caught_at %r" % (st, ph, iid, ca))
                continue
            mins = it.get("minutes_to_fix")
            if not isinstance(mins, (int, float)):
                ns = by_id[iid].get("next_success")
                mins = ns["minutes_after_failure"] if ns else 0.0
                agg["unscored_minutes_fallback"] += 1
            agg["count"][cat] += 1
            agg["minutes"][cat] += mins
            agg["caught_count"][ca] += 1
            agg["caught_minutes"][ca] += mins
            agg["classified"] += 1
            n_ok += 1
        missing = sorted(set(by_id) - seen)
        coverage.append({"stack": st, "phase": ph, "failures": d["n_failures"], "classified": n_ok,
                         "status": "complete" if not missing else "missing ids: " + ", ".join(missing)})
    rows = []
    for st in sorted(stacks, key=lambda s: STACK_ORDER.index(s) if s in STACK_ORDER else 99):
        g = stacks[st]
        n = sum(g["count"].values())
        tot_m = sum(g["minutes"].values())
        g["total_classified_failures"] = n
        g["total_minutes"] = tot_m
        g["caught_share_count"] = {k: (v / n if n else None) for k, v in g["caught_count"].items()}
        g["caught_share_minutes"] = {k: (v / tot_m if tot_m else None) for k, v in g["caught_minutes"].items()}
        g["stale_api_per_100_builds"] = (100.0 * g["count"]["stale_api"] / g["builds"]) if g["builds"] else None
        rows.append(g)
    out = {"run": a.run, "machine": a.machine, "categories": CATEGORIES, "stacks": rows, "coverage": coverage, "problems": problems}
    json.dump(out, open(os.path.join(ad, "taxonomy.json"), "w"), indent=1)

    L = ["# Failure taxonomy (SPEC 8.1)", "",
         "Generated by `harness/agentlog/aggregate.py` from `classified/*.json`. Minutes = classifier's `minutes_to_fix` (time from first failure to next success of that kind; falls back to the digest value when absent).", "",
         "## Count per category (P1 + P2 [+ P3], per stack)", "",
         "| stack | phases | builds | " + " | ".join(CATEGORIES) + " | total | false pos. |",
         "|---|---|---|" + "---|" * (len(CATEGORIES) + 2)]
    for g in rows:
        L.append("| %s | %s | %d | %s | %d | %d |" % (g["stack"], "+".join(g["phases"]), g["builds"],
                                                       " | ".join(str(g["count"][c]) for c in CATEGORIES), g["total_classified_failures"], g["false_positive"]))
    L += ["", "## Minutes per category", "",
          "| stack | " + " | ".join(CATEGORIES) + " | total |", "|---|" + "---|" * (len(CATEGORIES) + 1)]
    for g in rows:
        L.append("| %s | %s | %.1f |" % (g["stack"], " | ".join("%.1f" % g["minutes"][c] for c in CATEGORIES), g["total_minutes"]))
    L += ["", "## Where bugs were caught", "",
          "| stack | compile (n / share / min) | own_tests | harness | runtime_manual |", "|---|---|---|---|---|"]
    for g in rows:
        cells = []
        for k in CAUGHT:
            sh = g["caught_share_count"][k]
            cells.append("%d / %s / %.1f" % (g["caught_count"][k], ("%.0f%%" % (100 * sh)) if sh is not None else "-", g["caught_minutes"][k]))
        L.append("| %s | %s |" % (g["stack"], " | ".join(cells)))
    L += ["", "## stale_api rate", "", "| stack | stale_api failures | builds | per 100 builds |", "|---|---|---|---|"]
    for g in rows:
        r = g["stale_api_per_100_builds"]
        L.append("| %s | %d | %d | %s |" % (g["stack"], g["count"]["stale_api"], g["builds"], ("%.1f" % r) if r is not None else "-"))
    L += ["", "## Coverage", "", "| stack | phase | flagged failures | classified | status |", "|---|---|---|---|---|"]
    for c in coverage:
        L.append("| %s | %s | %d | %s | %s |" % (c["stack"], c["phase"], c["failures"], "-" if c["classified"] is None else c["classified"], c["status"]))
    if problems:
        L += ["", "## Problems in classified files", ""] + ["- " + p for p in problems]
    open(os.path.join(ad, "taxonomy.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("wrote", os.path.join(ad, "taxonomy.json"), "(%d stacks, %d problems)" % (len(rows), len(problems)))


if __name__ == "__main__":
    main()

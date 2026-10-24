#!/usr/bin/env python3
"""SPEC 8.2 code size: `scc --by-file` honoring LOC_EXCLUDE, bucketed engine/ui/server/glue/tests (+cli rolled into engine),
generated reported separately and never in totals. Writes loc.json."""
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import f2d

a = f2d.cli_args("code size")
stack, out = a.stack, a.outp
conf, common = f2d.cfg(stack), f2d.cfg()["common"]
sd = f2d.stack_dir(stack)

scc = f2d.find_tool("scc")
if not scc:
    f2d.jwrite(out / "loc.json", {"stack": stack, "error": "scc not found"})
    sys.exit("scc not found")

p = subprocess.run([scc, "--by-file", "--format", "json", "--no-cocomo", "--no-complexity", "."], cwd=sd, capture_output=True, text=True)
data = json.loads(p.stdout)

# LOC_EXCLUDE: one path or directory per line, '#' comments (SPEC 2.6, 8.2)
excl = []
le = sd / "LOC_EXCLUDE"
if le.exists():
    for line in le.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            excl.append(line.replace("\\", "/").strip("/") if line.endswith("/") else line.replace("\\", "/"))
hard = [re.compile(r) for r in common["loc_hard_excludes"]]
gen_re = re.compile(common["generated_regex"])
ignore_langs = set(common["loc_ignore_languages"])
buckets = [("glue", re.compile(r"^stack\.sh$"))] + [(b, re.compile(r)) for b, r in conf["loc_buckets"]]


def excluded_by_file(rel):
    for e in excl:
        if rel == e or rel.startswith(e.rstrip("/") + "/"):
            return e
    return None


tot = defaultdict(lambda: {"files": 0, "code": 0, "comment": 0, "blank": 0})
lang = defaultdict(lambda: defaultdict(int))
files = []
ignored_hard = ignored_lang = 0
excluded = {"files": 0, "code": 0, "by_entry": defaultdict(int)}
for l in data:
    for f in l.get("Files", []):
        rel = f["Location"].replace("\\", "/").removeprefix("./")
        if any(h.search(rel) for h in hard):
            ignored_hard += 1
            continue
        if f["Language"] in ignore_langs:
            ignored_lang += 1
            continue
        e = excluded_by_file(rel)
        is_gen = bool(gen_re.search(rel))
        if e is not None or is_gen:
            if is_gen:
                bucket = "generated"
            else:
                excluded["files"] += 1
                excluded["code"] += f["Code"]
                excluded["by_entry"][e] += f["Code"]
                continue
        else:
            bucket = next((b for b, r in buckets if r.search(rel)), "other")
        t = tot[bucket]
        t["files"] += 1
        t["code"] += f["Code"]
        t["comment"] += f["Comment"]
        t["blank"] += f["Blank"]
        if bucket != "generated":
            lang[f["Language"]]["code"] += f["Code"]
            lang[f["Language"]]["files"] += 1
        files.append({"path": rel, "language": f["Language"], "bucket": bucket, "code": f["Code"], "comment": f["Comment"], "blank": f["Blank"]})

b = {k: tot[k] for k in ("engine", "ui", "server", "glue", "tests", "cli", "other", "generated") if k in tot}
for k in ("engine", "ui", "server", "glue", "tests", "generated"):
    b.setdefault(k, {"files": 0, "code": 0, "comment": 0, "blank": 0})
cli = tot["cli"]["code"] if "cli" in tot else 0
engine_incl_cli = b["engine"]["code"] + cli
totals = {"engine": engine_incl_cli, "ui": b["ui"]["code"], "server": b["server"]["code"], "glue": b["glue"]["code"],
          "tests": b["tests"]["code"], "other": b.get("other", {}).get("code", 0)}
totals["total_excluding_generated"] = sum(totals.values())
rec = {
    "stack": stack, "tool": "scc " + subprocess.run([scc, "--version"], capture_output=True, text=True).stdout.strip(),
    "metric": "code lines (not blank, not comment)",
    "totals_code": totals,
    "engine_of_which_cli": cli,
    "buckets": b,
    "generated_code_not_in_totals": b["generated"]["code"],
    "loc_exclude_entries": excl,
    "loc_exclude_dropped": {"files": excluded["files"], "code": excluded["code"], "by_entry": dict(excluded["by_entry"])},
    "ignored": {"hard_excluded_files": ignored_hard, "data_or_doc_language_files": ignored_lang, "languages": sorted(ignore_langs)},
    "by_language_code": {k: dict(v) for k, v in sorted(lang.items(), key=lambda kv: -kv[1]["code"])},
    "unbucketed_files": [f["path"] for f in files if f["bucket"] == "other"],
    "notes": "cli is part of engine in totals_code. tests bucket is path-based only; inline #[cfg(test)]/test blocks stay in their source bucket.",
    "files": files,
}
f2d.jwrite(out / "loc.json", rec)
print(f"[{stack}] loc: " + ", ".join(f"{k}={v}" for k, v in totals.items()) + f", generated={b['generated']['code']}")

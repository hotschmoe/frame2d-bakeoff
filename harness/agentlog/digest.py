#!/usr/bin/env python3
"""Compact failure digests for the SPEC 8.1 failure taxonomy (extraction only, no classification).

usage: python harness/agentlog/digest.py [--run run1] [--machine win-arm64] [--max-kb 55]
Writes results/<run>/<machine>/agent/digests/<stack>-<phase>.md and .json
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

ERR_RE = re.compile(
    r"error|Error|ERROR|FAIL|panic|undefined|cannot|can't|could not|couldn't|not found|no such|unresolved|mismatch|expected|"
    r"unused|declared and not used|imported and not used|invalid|failed|fatal|exception|Traceback|segfault|overflow|"
    r"borrow|lifetime|does not live|trait|not satisfied|missing|unknown|undeclared|unreachable|assert|abort|"
    r"^\s*-->|^\s*\d+\s*\||^\s*=\s*(note|help)|^\s*\^|Build Summary|steps succeeded|\.(go|zig|rs|dart|c|h|py):\d+",
    re.M)
NOISE_RE = re.compile(r"^\s*(Compiling |Downloading |Downloaded |Fresh |Updating |Locking |Adding |Blocking |Waiting for |"
                      r"Resolving |Got |Building |Running |warning: unused manifest|go: downloading |remote: |\[\d+/\d+\])")


def unspace(line):
    # UTF-16 output decoded as bytes shows up as "W i n d o w s"
    if len(line) > 8 and line[1::2].strip() == "" and line[::2].strip():
        return line[::2]
    return line


def short_cmd(cmd, limit=700):
    def repl(m):
        body = m.group(0)
        n = body.count("\n")
        return body.split("\n")[0] + "\n<heredoc body, %d lines elided>" % n
    cmd = C._HEREDOC.sub(repl, cmd)
    cmd = re.sub(r"/c/Users/HOTSCH~1/AppData/Local/Temp/claude/[^\s\"']*scratchpad", "$SCRATCH", cmd)
    cmd = re.sub(r"C:\\Users\\HOTSCH~1\\AppData\\Local\\Temp\\claude\\[^\s\"']*scratchpad", "$SCRATCH", cmd)
    cmd = cmd.replace("/c/Users/hotschmoe/Documents/GitHub/frame2d-bakeoff", "$REPO")
    cmd = re.sub(r"[ \t]+", " ", cmd).strip()
    if len(cmd) > limit:
        cmd = cmd[:limit // 2] + " ... " + cmd[-limit // 2:]
    return cmd


def relevant_lines(text, n):
    raw = [unspace(l.rstrip()) for l in text.replace("\x00", "").splitlines()]
    raw = [l for l in raw if l.strip()]
    keep = []
    after = 0
    for i, l in enumerate(raw):
        if NOISE_RE.match(l):
            continue
        if ERR_RE.search(l):
            keep.append(i)
            after = 2
        elif after > 0:
            keep.append(i)
            after -= 1
    seen, out = set(), []
    for i in keep:
        l = raw[i][:180]
        key = re.sub(r"\d+", "N", l)
        if key in seen:
            continue
        seen.add(key)
        out.append(l)
    if len(out) > n:  # keep head and tail (first errors usually matter most, final summary next)
        h = n * 3 // 4
        out = out[:h] + ["... (%d lines elided)" % (len(out) - n)] + out[-(n - h):]
    if not out:
        out = [l[:180] for l in raw[-min(n, 12):]]
    return out


def primary_kind(c):
    if not c.kind_failed:
        return "run"
    if len(c.kinds) == 1:
        return c.kinds[0]
    for k in c.kinds:
        if C.detect_failure([k], c.text, False, None):
            return k
    return c.kinds[0]


def signature(lines):
    for l in lines:
        if ERR_RE.search(l):
            return re.sub(r"\d+", "N", re.sub(r"[\w./\\:~-]+\.(go|zig|rs|dart|py|c|h)", "FILE", l))[:100]
    return lines[0][:100] if lines else ""


def ctx_text(s, idx, before=True):
    """The agent's own text immediately before (previous assistant text) or after (next one)."""
    if before:
        cands = [t for t in s.texts if t[0] < idx]
        t = cands[-1] if cands else None
        if t and idx - t[0] > 12:
            t = None
    else:
        cands = [t for t in s.texts if t[0] > idx]
        t = cands[0] if cands else None
        if t and t[0] - idx > 12:
            t = None
    if not t:
        return None
    return t[2].strip().replace("\n", " ")[:300]


def build_digest(stack, phase, path, n_lines, repeat_after=3):
    s = C.parse_session(path)
    cmds = [c for c in s.calls if c.kinds and c.ran]
    fails = [c for c in cmds if c.failed]
    n_builds = sum(1 for c in cmds if "build" in c.kinds or "check" in c.kinds)
    recs, sigcount = [], {}
    for n, c in enumerate(fails, 1):
        pk = primary_kind(c)
        t_fail = c.t1 or c.t0
        nxt = None
        for c2 in cmds:
            if c2.t0 and t_fail and c2 is not c and pk in c2.kinds and not c2.failed and c2.i0 > c.i0 and (c2.t1 or c2.t0) >= t_fail:
                nxt = c2
                break
        lines = relevant_lines(c.text, n_lines)
        sig = signature(lines)
        sigcount[sig] = sigcount.get(sig, 0) + 1
        rec = {
            "id": "F%d" % n, "ts": C.iso(c.t0), "minutes_since_phase_start": round((c.t0 - s.t_first).total_seconds() / 60, 1),
            "kinds": c.kinds, "primary_kind": pk, "duration_s": round(c.dur, 1), "background": c.bg,
            "reasons": c.reasons, "command": short_cmd(c.cmd), "signature": sig, "repeat_index": sigcount[sig],
            "output": lines,
            "agent_before": ctx_text(s, c.i0, True), "agent_after": ctx_text(s, c.i1 if c.i1 is not None else c.i0, False),
            "next_success": None,
        }
        if nxt is not None:
            stall = C.overlap_stall(s, t_fail, nxt.t1 or nxt.t0)
            rec["next_success"] = {
                "ts": C.iso(nxt.t1 or nxt.t0), "command": short_cmd(nxt.cmd, 300), "kinds": nxt.kinds,
                "minutes_after_failure": round(max(0.0, ((nxt.t1 or nxt.t0) - t_fail).total_seconds() - stall) / 60, 1)}
        recs.append(rec)
    return s, recs, n_builds, len(cmds)


def render(stack, phase, s, recs, n_builds, n_cmds, repeat_after=3):
    wall = (s.t_last - s.t_first).total_seconds() - sum(x["seconds"] for x in s.stalls)
    L = ["# Failure digest: %s %s" % (stack, phase), "",
         "Phase start %s, active wall %.1f min (stalls removed), %d build/check commands, %d build/check/test/conformance commands, %d flagged failures." % (
             C.iso(s.t_first), wall / 60, n_builds, n_cmds, len(recs)), "",
         "Failures are extracted heuristically (see harness/agentlog/README.md). A `reasons` entry starting with `inferred:` means the exit code was 0 "
         "(pipes such as `| tail` hide it) and the failure was inferred from output text; such items can be false positives. "
         "If an item is not a real failure of the kind named, classify it `false_positive`.", ""]
    if recs:
        L += ["| id | min | kind | next success (min) | signature |", "|---|---|---|---|---|"]
        for r in recs:
            ns = r["next_success"]
            L.append("| %s | %.1f | %s | %s | %s |" % (r["id"], r["minutes_since_phase_start"], r["primary_kind"],
                                                     ("%.1f" % ns["minutes_after_failure"]) if ns else "none", r["signature"].replace("|", "/")))
        L.append("")
    else:
        L += ["No failed build/check/test/conformance command was detected.", ""]
    for r in recs:
        L.append("## %s  %s  (+%.1f min)  kind=%s" % (r["id"], r["ts"], r["minutes_since_phase_start"], "/".join(r["kinds"])))
        L.append("- primary kind: %s; duration %.0f s%s; reasons: %s" % (
            r["primary_kind"], r["duration_s"], " (background)" if r["background"] else "", "; ".join(r["reasons"])))
        L.append("- command: `%s`" % r["command"].replace("`", "'"))
        if r["repeat_index"] > repeat_after and r["output"] and len(r["output"]) > 6:
            L.append("- output: (repeat #%d of signature `%s`; first lines only)" % (r["repeat_index"], r["signature"]))
            L.append("```")
            L += r["output"][:6]
            L.append("```")
        else:
            L.append("- output:")
            L.append("```")
            L += r["output"]
            L.append("```")
        if r["agent_before"]:
            L.append("- agent before: %s" % r["agent_before"])
        if r["agent_after"]:
            L.append("- agent after: %s" % r["agent_after"])
        ns = r["next_success"]
        if ns:
            L.append("- next success of same kind (%s): %s, %.1f min after the failure: `%s`" % (r["primary_kind"], ns["ts"], ns["minutes_after_failure"], ns["command"].replace("`", "'")))
        else:
            L.append("- next success of same kind (%s): none in this transcript" % r["primary_kind"])
        L.append("")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="run1")
    ap.add_argument("--machine", default="win-arm64")
    ap.add_argument("--max-kb", type=float, default=55)
    a = ap.parse_args()
    rd = os.path.join(C.ROOT, "results", a.run, a.machine)
    out = os.path.join(rd, "agent", "digests")
    os.makedirs(out, exist_ok=True)
    summary = []
    for st, ph, p in C.transcript_files(rd):
        for n_lines in (40, 25, 15, 8, 4):
            s, recs, nb, nc = build_digest(st, ph, p, n_lines)
            md = render(st, ph, s, recs, nb, nc, repeat_after=3 if n_lines >= 25 else 1)
            if len(md.encode("utf-8")) <= a.max_kb * 1024:
                break
        name = "%s-%s" % (st, ph)
        open(os.path.join(out, name + ".md"), "w", encoding="utf-8").write(md)
        json.dump({"stack": st, "phase": ph, "build_check_commands": nb, "n_failures": len(recs),
                   "failures": [{k: r[k] for k in ("id", "ts", "minutes_since_phase_start", "kinds", "primary_kind", "reasons", "signature", "next_success")} for r in recs]},
                  open(os.path.join(out, name + ".json"), "w"), indent=1)
        summary.append((name, len(md.encode("utf-8")), len(recs), n_lines))
    for name, size, nf, nl in summary:
        print("%-24s %6.1f KB  %2d failures  (%d output lines/failure)" % (name, size / 1024, nf, nl))


if __name__ == "__main__":
    main()

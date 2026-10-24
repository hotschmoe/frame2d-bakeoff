"""Shared helpers for the agent-log tooling (SPEC 8.1 / 10.1). Python 3 stdlib only.

Reads Claude Code subagent transcripts (JSONL, optionally .xz) directly; nothing is written to disk
in decompressed form.  See README.md for the heuristics.
"""
import json
import lzma
import os
import re
import shlex
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STALL_S = 30 * 60  # any single gap between consecutive transcript events above this is a "stall"

# ---------------------------------------------------------------- pricing (CONFIG, edit here)
# USD per 1,000,000 tokens.  ASSUMPTION: Sonnet-class list prices (3 / 15, cache read 0.1x input,
# 5-minute cache write 1.25x, 1-hour cache write 2x).  The real list prices of claude-sonnet-5-5
# were NOT verified when this file was written; treat the dollar figures as estimates and override
# with `--price-file prices.json` ({"input":..,"output":..,"cache_read":..,"cache_write_5m":..,"cache_write_1h":..})
# or by editing this table.  Advisor-model (Opus) tokens, if any, are not present in the transcripts
# and are therefore not costed.
PRICES_PER_MTOK = {
    "input": 3.00,
    "output": 15.00,
    "cache_read": 0.30,
    "cache_write_5m": 3.75,
    "cache_write_1h": 6.00,
}


def parse_ts(s):
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def load_events(path):
    op = lzma.open if path.endswith(".xz") else open
    out = []
    with op(path, "rt", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict):
                if b.get("type") == "text":
                    parts.append(b.get("text", ""))
                elif b.get("type") == "image":
                    parts.append("[image]")
                else:
                    parts.append(json.dumps(b)[:200])
            else:
                parts.append(str(b))
        return "\n".join(parts)
    return str(content)


# ---------------------------------------------------------------- command classification
_HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.S)
_SPLIT = re.compile(r"&&|\|\||;|\||\n")
_LEAD = {"do", "then", "if", "elif", "else", "!", "{", "(", "while", "until", "time", "nohup", "exec",
         "command", "builtin", "sudo"}


def strip_heredocs(cmd):
    return _HEREDOC.sub("<<HEREDOC", cmd)


def split_commands(cmd):
    """Split on && || ; | and newlines that are outside quotes/parentheses-free text."""
    out, cur, q, i, n = [], [], None, 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if q:
            cur.append(ch)
            if ch == "\\" and q == '"' and i + 1 < n:
                cur.append(cmd[i + 1]); i += 1
            elif ch == q:
                q = None
        elif ch in "'\"":
            q = ch; cur.append(ch)
        elif ch == "\\" and i + 1 < n:
            cur.append(ch); cur.append(cmd[i + 1]); i += 1
        elif cmd.startswith("&&", i) or cmd.startswith("||", i):
            out.append("".join(cur)); cur = []; i += 1
        elif ch in ";|\n":
            out.append("".join(cur)); cur = []
        else:
            cur.append(ch)
        i += 1
    out.append("".join(cur))
    return out


def _toks(seg):
    seg = seg.strip().lstrip("&").strip().strip("()").strip()
    if not seg:
        return []
    try:
        t = shlex.split(seg, posix=True)
    except ValueError:
        t = seg.split()
    return t


def _base(tok):
    b = re.split(r"[\\/]", tok)[-1].lower()
    return b[:-4] if b.endswith(".exe") else b


def _classify_tokens(t):
    """Return list of kinds for one simple command given as tokens."""
    while t and (t[0] in _LEAD or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0]) or t[0] in ("timeout", "env")):
        if t[0] == "timeout" and len(t) > 1:
            t = t[2:] if re.match(r"^[0-9.]+[smh]?$", t[1]) else t[1:]
        else:
            t = t[1:]
    if not t:
        return []
    prog = _base(t[0])
    rest = t[1:]
    args = [a for a in rest if not a.startswith("-")]
    low = [a.lower() for a in rest]
    if prog == "measure.sh":
        # measure.sh <stack> <label> -- <command...>
        if "--" in rest:
            return _classify_tokens(rest[rest.index("--") + 1:])
        return []
    if prog in ("bash", "sh", "zsh") and rest and _base(rest[0]) == "measure.sh":
        return _classify_tokens(rest)
    if prog in ("bash", "sh", "zsh") or t[0].upper().endswith("BASH") or t[0] == "$BASH" or t[0] == '"$BASH"':
        if "-c" in rest:
            i = rest.index("-c")
            return classify_text(rest[i + 1]) if i + 1 < len(rest) else []
        for a in rest:
            if a.endswith("server_conformance.sh"):
                return ["conformance"]
        return []
    if prog.endswith("server_conformance.sh") or prog == "server_conformance.sh":
        return ["conformance"]
    if prog in ("python", "python3", "py"):
        for a in rest:
            if a.endswith("server_conformance.py") or a.endswith("conformance.py"):
                return ["conformance"]
        if "pytest" in rest or "unittest" in rest:
            return ["test"]
        return []
    if prog == "cargo":
        a = [x for x in rest if not x.startswith("-") and not x.startswith("+")]
        sub = a[0] if a else ""
        return {"build": ["build"], "b": ["build"], "check": ["check"], "clippy": ["check"], "test": ["test"],
                "t": ["test"], "nextest": ["test"], "install": [], "run": []}.get(sub, [])
    if prog == "go":
        sub = args[0] if args else ""
        return {"build": ["build"], "vet": ["check"], "test": ["test"]}.get(sub, [])
    if prog == "zig":
        sub = args[0] if args else ""
        if sub == "build":
            return ["test"] if any(x in ("test", "unit-test", "unit_test") for x in args[1:]) else ["build"]
        if sub == "test":
            return ["test"]
        if sub in ("build-exe", "build-lib", "build-obj"):
            return ["build"]
        return []
    if prog == "flutter":
        sub = args[0] if args else ""
        return {"build": ["build"], "analyze": ["check"], "test": ["test"]}.get(sub, [])
    if prog == "dart":
        sub = args[0] if args else ""
        if sub == "analyze":
            return ["check"]
        if sub == "test":
            return ["test"]
        if sub == "compile":
            return ["build"]
        if sub == "run" and any("ffigen" in x or "build_runner" in x for x in args[1:]):
            return ["build"]
        return []
    if prog in ("flutter_rust_bridge_codegen", "wasm-bindgen", "wasm-pack", "cmake", "msbuild", "ninja", "make"):
        return ["build"]
    if prog == "npm" and args[:1] == ["test"]:
        return ["test"]
    if prog == "source" or prog == ".":
        return []
    # stack.sh functions (called after `source stack.sh`)
    if prog == "build_check":
        return ["check"]
    if prog == "test_all" or re.match(r"^test_\w+$", prog):
        return ["test"]
    if prog == "codegen" or re.match(r"^build_\w+$", prog):
        return ["build"]
    return []


_TRIVIAL = {"cd", "sed", "cat", "echo", "gofmt", "cp", "mkdir", "ls", "grep", "rg", "head", "tail", "rm", "mv", "date",
            "export", "source", ".", "true", "false", "which", "printf", "tee", "wc", "time", "pwd", "touch", "test", "[",
            "[[", "cut", "sort", "uniq", "tr", "awk", "set", "unset", "cygpath", "env", "git", "find", "stat", "diff",
            "go", "cargo", "zig", "flutter", "dart", "wasm-bindgen", "flutter_rust_bridge_codegen", "wasm-opt", "bash", "sh",
            "measure.sh", "timeout", "python", "python3", "py", "do", "done", "for", "if", "fi", "then", "else", "bounded",
            "deps_report", "taskkill"}


def is_pure_build(cmd):
    """True if every segment is a build/check call or trivial glue (so the command duration is ~build time)."""
    cmd = strip_heredocs(cmd)
    for seg in split_commands(cmd):
        t = _toks(seg)
        while t and (t[0] in _LEAD or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0])):
            t = t[1:]
        if not t:
            continue
        k = _classify_tokens(t)
        if k and set(k) <= {"build", "check"}:
            continue
        p = _base(t[0])
        if p in _TRIVIAL or re.match(r"^(build_\w+|test_\w+|codegen)$", p):
            if p in ("python", "python3", "py") and any(a.endswith("conformance.py") for a in t):
                return False
            if k and not set(k) <= {"build", "check"}:
                return False
            continue
        return False
    return True


def classify_text(cmd):
    """Ordered unique list of kinds in {build, check, test, conformance} that a shell command invokes."""
    cmd = strip_heredocs(cmd)
    kinds = []
    for seg in split_commands(cmd):
        for k in _classify_tokens(_toks(seg)):
            if k not in kinds:
                kinds.append(k)
    return kinds


# ---------------------------------------------------------------- failure detection
RC_RE = re.compile(r"(?:^|[\s;(])(?:rc|RC|EXIT|exit|ec|EC|status)=([1-9][0-9]*)\b")
BUILD_MARKERS = [
    (re.compile(r"^\s*error(\[\w+\])?:", re.M), "error: line"),
    (re.compile(r"^\s*(Error|ERROR)(?::| )", re.M), "Error: line"),
    (re.compile(r"^(?:\./|\S*[\\/])?[^\s:]+\.(?:go|zig|rs|dart|c|cc|cpp|h|js|mjs|ts):\d+(?::\d+)?: (?!note|warning)", re.M), "file:line diagnostic"),
    (re.compile(r"^#\s+[\w./-]+\s*$", re.M), "go build package header"),
    (re.compile(r"\.dart:\d+:\d+: Error", re.M), "dart Error"),
    (re.compile(r"^\s*error •", re.M), "dart analyze error"),
    (re.compile(r"Compilation failed|could not compile|Build failed|build failed|FAILURE: Build|Target \w+ failed|Build process failed", re.I), "build failed text"),
    (re.compile(r"Build Summary: .*\(\d+ failed\)|steps succeeded \(\d+ failed\)|transitive failure|exited with code [1-9]", re.I), "zig build failed"),
    (re.compile(r"undefined reference|unresolved external|LNK\d{4}|lld-link: error|ld\.lld: error|linker command failed|duplicate symbol", re.I), "linker error"),
    (re.compile(r"\b\w+ failed:?\s*$", re.M), "'<function> failed' line"),
    (re.compile(r"No such file or directory|command not found|is not recognized as", re.I), "missing tool/file"),
]
TEST_MARKERS = [
    (re.compile(r"^--- FAIL", re.M), "--- FAIL"),
    (re.compile(r"^FAIL\b", re.M), "FAIL line"),
    (re.compile(r"test result: FAILED|^\s*failures:\s*$|\bpanicked at\b|thread '.*' panicked", re.M), "rust test failure"),
    (re.compile(r"\d+ failed;|\b[1-9]\d* failed\b|Some tests failed|\[FAIL\]|\+\d+ -[1-9]\d*:", re.M), "failed count"),
    (re.compile(r"segmentation fault|illegal instruction|signal: \d+|exited with code [1-9]", re.I), "crash"),
    (re.compile(r"^\s*error(\[\w+\])?:|\.go:\d+:\d+: |\.zig:\d+:\d+: error|Build Summary: .*\(\d+ failed\)|transitive failure", re.M), "compile error in test build"),
]
CONF_MARKERS = [
    (re.compile(r"^FAIL\b", re.M), "FAIL line"),
    (re.compile(r"^(\d+)/(\d+) passed", re.M), None),  # handled specially
    (re.compile(r"^FAILED \(\d+ failures\)|all passed \([1-9]\d* failures\)", re.M), "server FAILED"),
    (re.compile(r"Traceback \(most recent call last\)", re.M), "python traceback"),
    (re.compile(r"\w+ failed:\s*$", re.M), "'<function> failed' line"),
    (re.compile(r"FileNotFoundError|No such file or directory|command not found", re.I), "missing binary"),
]


def _nospace(s):
    return re.sub(r"[\s\x00]+", "", s).lower()


RUN_CRASH_RE = re.compile(r"^panic: |panicked at|Unhandled exception|Segmentation fault|STATUS_ACCESS_VIOLATION|"
                          r"exit(?:ed)? (?:with )?code:? ?0x[cC]\w+|Illegal instruction|fatal error: |SIGSEGV|stack overflow", re.M)
_READONLY = {"cat", "sed", "grep", "rg", "head", "tail", "ls", "find", "wc", "echo", "sleep", "git", "awk", "diff", "type"}


def detect_run_crash(cmd, text):
    """Runtime crash printed by a program the agent ran (not a build/test/conformance command)."""
    if not text or text.lstrip().startswith("<tool_use_error>"):
        return False
    runs_something = False
    for seg in split_commands(strip_heredocs(cmd)):
        t = _toks(seg)
        while t and (t[0] in _LEAD or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t[0])):
            t = t[1:]
        if t and _base(t[0]) not in _READONLY | {"cd", "export", "true", "mkdir", "rm", "cp", "mv", "date", "sed", "source"}:
            runs_something = True
    return runs_something and bool(RUN_CRASH_RE.search(text))


def detect_failure(kinds, text, is_error, status=None):
    """Return list of reason strings (empty = success).  `inferred` reasons come from output markers
    because pipes (`| tail`) and `;` chains hide non-zero exits."""
    reasons = []
    if text and text.lstrip().startswith("<tool_use_error>"):
        return []  # the tool call itself was rejected/blocked: the command never ran
    if is_error:
        m = re.match(r"\s*(?:Error: )?Exit code (\d+)", text or "")
        reasons.append("exit code %s" % (m.group(1) if m else "?"))
    if status == "failed":
        reasons.append("background task status=failed")
    if not text:
        return reasons
    text = chr(10).join(l for l in text.splitlines() if "BENCH-EDIT" not in l)
    if RC_RE.search(text):
        reasons.append("inferred: rc=%s printed" % RC_RE.search(text).group(1))
    flat = _nospace(text)
    if "noinstalleddistributions" in flat:
        reasons.append("inferred: WSL bash stub (no distribution)")
    seen = set()

    def run(markers):
        for rx, label in markers:
            m = rx.search(text)
            if not m:
                continue
            if label is None:  # N/M passed
                for mm in rx.finditer(text):
                    if int(mm.group(1)) < int(mm.group(2)):
                        reasons.append("inferred: %s/%s passed" % (mm.group(1), mm.group(2)))
                        break
                continue
            if label not in seen:
                seen.add(label)
                reasons.append("inferred: " + label)

    if "conformance" in kinds:
        run(CONF_MARKERS)
    if "test" in kinds:
        run(TEST_MARKERS)
    if "build" in kinds or "check" in kinds:
        run(BUILD_MARKERS)
    # collapse: if only weak inferred markers and success banner is present, treat as success
    if reasons and all(r.startswith("inferred:") for r in reasons):
        ok_banner = re.search(r"^\d+/\d+ passed|all passed \(0 failures\)|test result: ok|All tests passed|No issues found|Finished (?:`|dev|release)", text, re.M)
        weak = {"inferred: missing tool/file", "inferred: go build package header", "inferred: file:line diagnostic",
                "inferred: error: line", "inferred: failed count"}
        if ok_banner and all(r in weak for r in reasons):
            return []
    return reasons


# ---------------------------------------------------------------- session model
CRASH_REASON = "inferred: runtime crash marker in program output"


class Call:
    __slots__ = ("id", "name", "input", "cmd", "t0", "t1", "end_src", "is_error", "text", "bg", "status",
                 "kinds", "reasons", "i0", "i1", "task_id", "bg_summary", "turn", "ran", "t_res")

    def __init__(self):
        self.t1 = None
        self.t_res = None
        self.end_src = None
        self.is_error = False
        self.text = ""
        self.bg = False
        self.status = None
        self.kinds = []
        self.reasons = []
        self.i1 = None
        self.task_id = None
        self.bg_summary = None
        self.ran = True

    @property
    def failed(self):
        return bool(self.reasons)

    @property
    def kind_failed(self):
        """Failed as a build/check/test/conformance command (not merely a crash printed by a program it ran)."""
        return any(r != CRASH_REASON for r in self.reasons)

    @property
    def block_dur(self):
        """Seconds the agent was actually blocked on this call (initial result, not background completion)."""
        if self.t0 and self.t_res:
            return max(0.0, (self.t_res - self.t0).total_seconds())
        return 0.0

    @property
    def dur(self):
        if self.t0 and self.t1:
            return max(0.0, (self.t1 - self.t0).total_seconds())
        return 0.0


class Session:
    pass


def parse_session(path, stack=None, phase=None):
    ev = load_events(path)
    s = Session()
    s.path = path
    s.events = ev
    s.calls = []
    calls = {}
    texts = []   # (event index, ts, text) assistant text blocks
    users = []   # non-tool-result user messages / queued prompts (event index, ts, kind, text)
    by_msg = {}  # message id -> usage (last wins)
    msg_first = {}
    tool_counts = {}
    stamps = []
    task_end = {}  # tool_use_id -> (ts, status, summary, task_id)
    task_out = {}  # task id -> output text read later

    first_user_done = False
    for i, x in enumerate(ev):
        t = parse_ts(x.get("timestamp"))
        if t:
            stamps.append((t, i))
        ty = x.get("type")
        if ty == "assistant":
            m = x.get("message", {})
            mid = m.get("id")
            if mid:
                if mid not in msg_first:
                    msg_first[mid] = (i, t)
                if m.get("usage"):
                    by_msg[mid] = m["usage"]
            for b in m.get("content", []) or []:
                if b.get("type") == "text" and b.get("text", "").strip():
                    texts.append((i, t, b["text"]))
                elif b.get("type") == "tool_use":
                    c = Call()
                    c.id = b["id"]
                    c.name = b["name"]
                    c.input = b.get("input", {})
                    c.cmd = c.input.get("command", "") if isinstance(c.input, dict) else ""
                    c.t0 = t
                    c.i0 = i
                    c.turn = mid
                    calls[c.id] = c
                    s.calls.append(c)
                    tool_counts[c.name] = tool_counts.get(c.name, 0) + 1
        elif ty == "user":
            c = x.get("message", {}).get("content")
            if isinstance(c, list):
                texts_u = []
                for b in c:
                    if b.get("type") == "tool_result":
                        call = calls.get(b.get("tool_use_id"))
                        if call is not None and call.i1 is None:
                            call.t1 = t
                            call.t_res = t
                            call.i1 = i
                            call.end_src = "result"
                            call.is_error = bool(b.get("is_error"))
                            call.text = result_text(b.get("content"))
                            mm = re.search(r"moved to the background \(ID: (\w+)\)|running in background with ID: (\w+)", call.text)
                            if mm:
                                call.bg = True
                                call.task_id = mm.group(1) or mm.group(2)
                            elif call.input.get("run_in_background"):
                                call.bg = True
                    elif b.get("type") == "text":
                        texts_u.append(b.get("text", ""))
                if texts_u:
                    users.append((i, t, "user", "\n".join(texts_u)))
            elif isinstance(c, str):
                users.append((i, t, "user", c))
        elif ty == "attachment":
            a = x.get("attachment", {})
            if a.get("type") == "queued_command":
                p = a.get("prompt", "")
                mk = (a.get("origin") or {}).get("kind") or a.get("commandMode")
                tu = re.search(r"<tool-use-id>(\S+?)</tool-use-id>", p)
                st = re.search(r"<status>(\w+)</status>", p)
                sm = re.search(r"<summary>(.*?)</summary>", p, re.S)
                tk = re.search(r"<task-id>(\w+)</task-id>", p)
                if mk == "task-notification" or "<task-notification>" in p:
                    if tu and st:
                        task_end[tu.group(1)] = (t, st.group(1), sm.group(1) if sm else "", tk.group(1) if tk else None)
                else:
                    users.append((i, t, "queued", p))
    # background completion
    for cid, (t, st, sm, tk) in task_end.items():
        c = calls.get(cid)
        if c is not None:
            c.bg = True
            c.t1 = t
            c.end_src = "notification"
            c.status = st
            c.bg_summary = sm
            c.task_id = c.task_id or tk
    # background output read later (by task id in a later command / Read path)
    idx_by_task = {}
    for c in s.calls:
        if c.bg and c.task_id:
            idx_by_task[c.task_id] = c
    for c2 in s.calls:
        blob = c2.cmd or json.dumps(c2.input)
        for tid, c in idx_by_task.items():
            if tid in blob and c2 is not c and c2.i0 > c.i0 and c2.text and tid + ".output" in blob:
                prev = task_out.get(tid)
                if prev is None:
                    task_out[tid] = c2.text
    for tid, c in idx_by_task.items():
        if tid in task_out:
            c.text = c.text + "\n[background output, read later]\n" + task_out[tid]
    # classify and detect failures
    for c in s.calls:
        if c.name in ("Bash", "PowerShell"):
            c.kinds = classify_text(c.cmd)
            if not c.kinds and detect_run_crash(c.cmd, c.text):
                c.kinds = ["run"]
                c.reasons = [CRASH_REASON]
                continue
            if c.kinds:
                txt = c.text
                is_err = c.is_error
                if c.bg and c.end_src == "notification":
                    # initial result only says "running in background": status is authoritative
                    is_err = False
                c.reasons = detect_failure(c.kinds, txt, is_err, c.status)
                if not c.reasons and detect_run_crash(c.cmd, txt):
                    c.reasons = [CRASH_REASON]
                if txt.lstrip().startswith("<tool_use_error>"):
                    c.ran = False
                # a still-unfinished background call without any output cannot be judged
    # stalls
    stamps.sort()
    s.t_first = stamps[0][0] if stamps else None
    s.t_last = stamps[-1][0] if stamps else None
    s.stalls = []
    for (a, ia), (b, ib) in zip(stamps, stamps[1:]):
        if (b - a).total_seconds() > STALL_S:
            s.stalls.append({"start": a, "end": b, "seconds": (b - a).total_seconds(), "event_before": ia, "event_after": ib})
    s.texts = texts
    s.users = users
    s.usage = by_msg
    s.msg_first = msg_first
    s.tool_counts = tool_counts
    return s


def overlap_stall(s, t0, t1):
    """Seconds of [t0, t1] that fall inside detected stalls."""
    tot = 0.0
    if not (t0 and t1):
        return 0.0
    for st in s.stalls:
        a = max(t0, st["start"])
        b = min(t1, st["end"])
        if b > a:
            tot += (b - a).total_seconds()
    return tot


def is_orchestrator_text(kind, text):
    """True if a user/queued message is a human or orchestrator intervention (not kickoff, not a system event)."""
    t = text.lstrip()
    if t.startswith("[SYSTEM NOTIFICATION") or t.startswith("<task-notification>") or t.startswith("<system-reminder>"):
        return False
    return True


def transcript_files(run_dir):
    d = os.path.join(run_dir, "transcripts")
    out = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".jsonl.xz") or f.endswith(".jsonl"):
            name = re.sub(r"\.jsonl(\.xz)?$", "", f)
            m = re.match(r"^(.*)-(P\d)$", name)
            if m:
                out.append((m.group(1), m.group(2), os.path.join(d, f)))
            else:
                out.append((name, "smoke", os.path.join(d, f)))
    return out


def cost(tokens, prices=None):
    p = prices or PRICES_PER_MTOK
    return (tokens["input"] * p["input"] + tokens["output"] * p["output"] + tokens["cache_read"] * p["cache_read"]
            + tokens.get("cache_write_5m", 0) * p["cache_write_5m"] + tokens.get("cache_write_1h", 0) * p["cache_write_1h"]) / 1e6

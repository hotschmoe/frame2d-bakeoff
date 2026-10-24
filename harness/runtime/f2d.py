#!/usr/bin/env python3
"""Shared helpers for the runtime/size harness (SPEC 8.2-8.8, 15). Python 3 stdlib + psutil.

Everything here works on Linux and under Git bash on Windows (native Windows Python, so MSYS-style
paths such as /c/Users/x are converted with npath()).
"""
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

try:
    import psutil
except ImportError:  # recorded in meta.json; samplers degrade to None fields
    psutil = None

IS_WIN = os.name == "nt"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK_ROOT = HERE / ".work"
NCPU = os.cpu_count() or 1


# ----------------------------------------------------------------------------------------------- paths
def npath(p):
    """MSYS (/c/Users/..) -> native (C:/Users/..) on Windows; identity elsewhere."""
    p = str(p).strip()
    if IS_WIN:
        m = re.match(r"^/([a-zA-Z])(/.*)?$", p)
        if m:
            return m.group(1).upper() + ":" + (m.group(2) or "/")
    return p


def which(name):
    return shutil.which(name)


def find_tool(*names, extra_dirs=()):
    for n in names:
        w = shutil.which(n)
        if w:
            return w
    for d in extra_dirs:
        for n in names:
            for ext in ("", ".exe"):
                c = Path(d) / (n + ext)
                if c.exists():
                    return str(c)
    return None


def machine_id():
    m = os.environ.get("F2D_MACHINE_ID")
    if m:
        return m
    import platform
    arch = platform.machine().lower()
    arch = {"amd64": "x64", "x86_64": "x64", "arm64": "arm64", "aarch64": "aarch64"}.get(arch, arch)
    if IS_WIN:
        return "win-" + ("arm64" if arch in ("arm64", "aarch64") else arch)
    if sys.platform == "darwin":
        return "mac-" + arch
    return "linux-" + ("aarch64" if arch in ("arm64", "aarch64") else arch)


def run_id():
    return os.environ.get("F2D_RUN", "run1")


def out_dir(stack, quick=False):
    sub = os.environ.get("F2D_RESULTS_SUBDIR") or ("runtime-smoke" if quick else "runtime")
    d = ROOT / "results" / run_id() / machine_id() / sub / stack
    d.mkdir(parents=True, exist_ok=True)
    (d / "logs").mkdir(exist_ok=True)
    return d


def work_dir(stack):
    d = WORK_ROOT / stack
    d.mkdir(parents=True, exist_ok=True)
    gi = WORK_ROOT / ".gitignore"
    if not gi.exists():
        gi.write_text("*\n")
    return d


def cfg(stack=None):
    c = json.loads((HERE / "stacks.json").read_text())
    return c if stack is None else c["stacks"][stack]


def stack_dir(stack):
    return ROOT / "stacks" / stack


# ---------------------------------------------------------------------------------------------- misc
def median(xs):
    xs = [x for x in xs if isinstance(x, (int, float)) and not isinstance(x, bool)]
    return statistics.median(xs) if xs else None


def median_fields(dicts):
    """Median of every numeric field present in at least one dict."""
    keys = []
    for d in dicts:
        for k, v in d.items():
            if isinstance(v, (int, float)) and not isinstance(v, bool) and k not in keys:
                keys.append(k)
    return {k: median([d.get(k) for d in dicts]) for k in keys}


def jwrite(path, obj):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(obj, indent=2, sort_keys=False) + "\n")


def jread(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def mb(n):
    return None if n is None else round(n / 2**20, 3)


def parse_bench_lines(text):
    out = []
    for line in text.splitlines():
        i = line.find("BENCH {")
        if i < 0:
            continue
        try:
            out.append(json.loads(line[i + 6:]))
        except Exception:
            pass
    return out


def tail(text, n=15):
    return "\n".join(text.strip().splitlines()[-n:])


# ------------------------------------------------------------------------------------- bash / stack.sh
def bash_exe():
    b = os.environ.get("F2D_BASH")
    if b:
        return npath(b)
    if IS_WIN:
        for c in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files\Git\usr\bin\bash.exe"):
            if os.path.exists(c):
                return c
        git = shutil.which("git")
        if git:
            c = Path(git).resolve().parent.parent / "bin" / "bash.exe"
            if c.exists():
                return str(c)
    return "bash"


def stack_fn(stack, fn, env=None, log=None, timeout=None, pre="", sdir=None):
    """Run `source stack.sh && <fn>` in a fresh bash. stdout is returned, stderr goes to `log`.
    Returns dict(rc, stdout, wall_s, last_line)."""
    sd = Path(sdir) if sdir else stack_dir(stack)
    e = os.environ.copy()
    e.update({k: str(v) for k, v in (env or {}).items()})
    script = f"source ./stack.sh >&2 || exit 99; {pre}{fn}"
    t0 = time.time()
    lf = open(log, "ab") if log else subprocess.DEVNULL
    if log:
        lf.write(f"\n==== {now_iso()} :: {stack} :: {pre}{fn} (env {env or {}})\n".encode())
        lf.flush()
    try:
        p = subprocess.run([bash_exe(), "-c", script], cwd=sd, env=e, stdout=subprocess.PIPE, stderr=lf, timeout=timeout)
        rc, so = p.returncode, p.stdout.decode(errors="replace")
    except subprocess.TimeoutExpired as ex:
        rc, so = 124, (ex.stdout or b"").decode(errors="replace")
    finally:
        if log:
            lf.close()
    lines = [l.rstrip("\r") for l in so.splitlines() if l.strip()]
    return {"rc": rc, "stdout": so, "wall_s": round(time.time() - t0, 3), "lines": lines,
            "last_line": lines[-1] if lines else None}


# ----------------------------------------------------------------------------------- process metering
if IS_WIN:
    import ctypes
    from ctypes import wintypes

    class _PMC(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]

    def _win_handle_stats(handle):
        """Peak working set (bytes) and CPU seconds from a process handle (valid after exit)."""
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        ps = ctypes.WinDLL("psapi", use_last_error=True)
        ps.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PMC), wintypes.DWORD]
        c = _PMC()
        c.cb = ctypes.sizeof(c)
        peak = None
        if ps.GetProcessMemoryInfo(wintypes.HANDLE(int(handle)), ctypes.byref(c), c.cb):
            peak = c.PeakWorkingSetSize
        ft = [wintypes.FILETIME() for _ in range(4)]
        cpu = None
        k32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        if k32.GetProcessTimes(wintypes.HANDLE(int(handle)), *[ctypes.byref(f) for f in ft]):
            q = lambda f: (f.dwHighDateTime << 32) | f.dwLowDateTime
            cpu = (q(ft[2]) + q(ft[3])) / 1e7
        return peak, cpu


def run_measured(cmd, cwd=None, env=None, timeout=900, stdin_bytes=None, text_limit=2_000_000):
    """Run a command once and return exact peak RSS + CPU of that process (not its children).

    Linux: wait4() rusage (ru_maxrss = what `/usr/bin/time -v` prints as Maximum resident set size).
    Windows: PeakWorkingSetSize / GetProcessTimes read from the process handle after exit.
    stdout/stderr go through temp files (no pipe deadlocks)."""
    e = os.environ.copy()
    e.update({k: str(v) for k, v in (env or {}).items()})
    fo, fe = tempfile.TemporaryFile(), tempfile.TemporaryFile()
    fi = None
    if stdin_bytes is not None:
        fi = tempfile.TemporaryFile()
        fi.write(stdin_bytes)
        fi.seek(0)
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=cwd, env=e, stdout=fo, stderr=fe, stdin=fi if fi else subprocess.DEVNULL)
    peak = cpu = None
    timed_out = False
    if IS_WIN:
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            kill_tree(p.pid)
            p.wait()
        rc = p.returncode
        peak, cpu = _win_handle_stats(p._handle)
        method = "win_PeakWorkingSetSize"
    else:
        import resource  # noqa: F401
        deadline = time.time() + timeout
        ru = None
        while True:
            pid, status, ru = os.wait4(p.pid, os.WNOHANG)
            if pid:
                break
            if time.time() > deadline:
                timed_out = True
                kill_tree(p.pid)
                pid, status, ru = os.wait4(p.pid, 0)
                break
            time.sleep(0.005)
        p.returncode = os.waitstatus_to_exitcode(status)
        rc = p.returncode
        peak = ru.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
        cpu = ru.ru_utime + ru.ru_stime
        method = "wait4_ru_maxrss"
    wall = time.perf_counter() - t0
    fo.seek(0), fe.seek(0)
    so, se = fo.read(text_limit).decode(errors="replace"), fe.read(text_limit).decode(errors="replace")
    fo.close(), fe.close()
    return {"rc": rc, "wall_s": round(wall, 4), "peak_rss_mb": mb(peak), "cpu_s": None if cpu is None else round(cpu, 4),
            "rss_method": method, "stdout": so, "stderr": se, "timed_out": timed_out}


def kill_tree(pid):
    """Kill a process and its descendants by PID (never by image name)."""
    if psutil is None:
        try:
            os.kill(pid, 9)
        except Exception:
            pass
        return
    try:
        root = psutil.Process(pid)
        procs = root.children(recursive=True) + [root]
    except psutil.Error:
        return
    for pr in procs:
        try:
            pr.kill()
        except psutil.Error:
            pass
    psutil.wait_procs(procs, timeout=5)


def os_peak_rss(proc):
    """OS-maintained peak RSS (bytes) of a live psutil.Process, or None."""
    try:
        if IS_WIN:
            return proc.memory_info().peak_wset
        with open(f"/proc/{proc.pid}/status") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1]) * 1024
        return proc.memory_info().rss
    except Exception:
        return None


class Sampler(threading.Thread):
    """Samples one process (and optionally its tree) every `interval` s: RSS, OS peak RSS, threads, CPU."""

    def __init__(self, pid, interval=0.1, tree=False):
        super().__init__(daemon=True)
        self.pid, self.interval, self.tree = pid, interval, tree
        self._halt = threading.Event()
        self.peak_rss = 0          # max over samples of summed RSS
        self.pid_peak = {}         # pid -> max OS peak RSS observed
        self.peak_threads = 0
        self.peak_procs = 0
        self.cpu = {}              # pid -> last seen cpu seconds (so exited children still count)
        self.samples = 0

    def run(self):
        if psutil is None:
            return
        try:
            root = psutil.Process(self.pid)
        except psutil.Error:
            return
        while not self._halt.is_set():
            self.sample(root)
            self._halt.wait(self.interval)

    def sample(self, root):
        try:
            procs = [root] + (root.children(recursive=True) if self.tree else [])
        except psutil.Error:
            return
        rss = thr = 0
        n = 0
        for pr in procs:
            try:
                rss += pr.memory_info().rss
                thr += pr.num_threads()
                t = pr.cpu_times()
                self.cpu[pr.pid] = t.user + t.system
                pk = os_peak_rss(pr)
                if pk:
                    self.pid_peak[pr.pid] = max(self.pid_peak.get(pr.pid, 0), pk)
                n += 1
            except psutil.Error:
                continue
        self.samples += 1
        self.peak_rss = max(self.peak_rss, rss)
        self.peak_threads = max(self.peak_threads, thr)
        self.peak_procs = max(self.peak_procs, n)

    def stop(self):
        self._halt.set()
        self.join(timeout=2)
        return self.result()

    def result(self):
        peak = max(self.peak_rss, sum(self.pid_peak.values()))
        return {"peak_rss_mb": mb(peak) if peak else None, "peak_threads": self.peak_threads or None,
                "peak_procs": self.peak_procs or None, "cpu_s": round(sum(self.cpu.values()), 3) if self.cpu else None,
                "samples": self.samples}


def listener_pid(port):
    """PID listening on 127.0.0.1:<port> (TCP), or None."""
    if psutil is None:
        return None
    try:
        for c in psutil.net_connections(kind="tcp"):
            if c.status == psutil.CONN_LISTEN and c.laddr and c.laddr.port == port and c.pid:
                return c.pid
    except (psutil.Error, OSError):
        return None
    return None


def port_in_use(port):
    import socket
    s = socket.socket()
    s.settimeout(0.3)
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def sha256_file(p, n=1 << 20):
    import hashlib
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while True:
            b = f.read(n)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def file_size(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return None


def dir_size(p):
    tot = 0
    for r, _, fs in os.walk(p):
        for f in fs:
            try:
                tot += os.path.getsize(os.path.join(r, f))
            except OSError:
                pass
    return tot


def load_artifacts(stack, out):
    a = jread(Path(out) / "artifacts.json")
    if not a:
        sys.exit(f"[{stack}] no artifacts.json in {out}: run the `build` section first (run.sh {stack} build)")
    return a


def cli_args(desc, extra=None):
    import argparse
    ap = argparse.ArgumentParser(description=desc)
    ap.add_argument("stack")
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--out", default=None)
    if extra:
        extra(ap)
    a = ap.parse_args()
    a.outp = Path(a.out) if a.out else out_dir(a.stack, a.quick)
    a.outp.mkdir(parents=True, exist_ok=True)
    (a.outp / "logs").mkdir(exist_ok=True)
    return a


# ------------------------------------------------------------------------------------------ desktop app
RENDERER_RE = re.compile(r"impeller|opengl|d3d|direct3d|vulkan|angle|swiftshader|software|renderer|adapter|wgpu|\bgl[_ ]|skia|metal", re.I)


def run_app(exe, mode, env=None, timeout=600, grace=15, extra_args=()):
    """Run a desktop app with --bench=<mode>; wait for its BENCH line (mode match), then for exit (kill by PID after grace).
    Returns dict(bench, rc, wall_s, peak_rss_mb (tree, sampled), renderer_lines, stderr_tail, timed_out)."""
    e = os.environ.copy()
    e.update({k: str(v) for k, v in (env or {}).items()})
    fo, fe = tempfile.NamedTemporaryFile(delete=False), tempfile.NamedTemporaryFile(delete=False)
    t0 = time.perf_counter()
    p = subprocess.Popen([exe, f"--bench={mode}", *extra_args], cwd=str(Path(exe).parent), env=e, stdout=fo, stderr=fe,
                         stdin=subprocess.DEVNULL)
    smp = Sampler(p.pid, 0.1, tree=True)
    smp.start()
    bench = None
    timed_out = False
    seen_at = None
    while True:
        rc = p.poll()
        try:
            txt = Path(fo.name).read_text(errors="replace")
        except OSError:
            txt = ""
        if bench is None:
            for b in parse_bench_lines(txt):
                if b.get("mode") == mode:
                    bench, seen_at = b, time.perf_counter()
        if rc is not None:
            break
        now = time.perf_counter()
        if seen_at and now - seen_at > grace:
            kill_tree(p.pid)
            break
        if now - t0 > timeout:
            timed_out = True
            kill_tree(p.pid)
            break
        time.sleep(0.1)
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        kill_tree(p.pid)
    res = smp.stop()
    fo.close(), fe.close()
    so = Path(fo.name).read_text(errors="replace")
    se = Path(fe.name).read_text(errors="replace")
    for n in (fo.name, fe.name):
        try:
            os.unlink(n)
        except OSError:
            pass
    if bench is None:
        for b in parse_bench_lines(so + "\n" + se):
            if b.get("mode") == mode:
                bench = b
    rl = [l.strip()[:200] for l in (so + "\n" + se).splitlines() if l.strip() and "BENCH {" not in l and RENDERER_RE.search(l)][:10]
    return {"bench": bench, "rc": p.returncode, "wall_s": round(time.perf_counter() - t0, 3),
            "peak_rss_mb_tree": res["peak_rss_mb"], "peak_procs": res["peak_procs"], "renderer_lines": rl,
            "stdout_other_head": [l[:200] for l in so.splitlines() if "BENCH {" not in l][:5],
            "stderr_tail": tail(se, 6), "timed_out": timed_out, "gc_stderr": se}

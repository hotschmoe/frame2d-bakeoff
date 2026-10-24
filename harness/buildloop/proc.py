"""Small process helpers shared by the interactive drivers (engine.py, hotreload.py, zigwatch.py)."""
import os
import queue
import subprocess
import threading
import time

try:
    import psutil
except ImportError:
    psutil = None


def spawn(cmd, **kw):
    """Start cmd with stdout+stderr merged; a reader thread feeds p.lines (queue of (t, text); text None = EOF)."""
    flags = {}
    if os.name == "nt":
        flags["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        flags["start_new_session"] = True
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.PIPE,
                         text=True, encoding="utf-8", errors="replace", bufsize=1, **flags, **kw)
    p.lines = queue.Queue()
    p.log = []

    def pump():
        for line in p.stdout:
            line = line.rstrip("\r\n")
            p.log.append(line)
            p.lines.put((time.perf_counter(), line))
        p.lines.put((time.perf_counter(), None))
    threading.Thread(target=pump, daemon=True).start()
    return p


def wait_line(p, pred, timeout):
    """Return (t, line) for the first line where pred(line) is true; ('eof'|'timeout', None) otherwise."""
    end = time.perf_counter() + timeout
    while True:
        left = end - time.perf_counter()
        if left <= 0:
            return "timeout", None
        try:
            t, line = p.lines.get(timeout=min(left, 1.0))
        except queue.Empty:
            continue
        if line is None:
            return "eof", None
        if pred(line):
            return t, line


def kill_tree(p):
    """Kill the process we started and its descendants, by PID only (never by image name)."""
    if psutil:
        pids = [p.pid]
        try:
            pids += [c.pid for c in psutil.Process(p.pid).children(recursive=True)]
        except psutil.Error:
            pass
        for pid in reversed(pids):
            try:
                psutil.Process(pid).kill()
            except psutil.Error:
                pass
    elif os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
    else:
        try:
            os.killpg(p.pid, 9)
        except OSError:
            pass
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass

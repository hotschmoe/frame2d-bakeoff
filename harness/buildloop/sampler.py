#!/usr/bin/env python3
"""1 Hz time-series sampler (SPEC 9.7) and wake-up latency probe (SPEC 9.6). LINUX ONLY (/proc, cgroup v2, PSI).

  sampler.py series --out FILE.csv [--cgroup PATH|self|system] [--interval 1.0]
  sampler.py latency --out FILE.json [--interval-ms 10]

Both run until SIGTERM/SIGINT, then flush and exit 0.
CSV columns: t, cpu_usage_delta_s, memory_current_mb, procs, psi_cpu_avg10, psi_mem_avg10, psi_io_avg10   (SPEC 9.7)
             then, always machine-wide: mem_used_mb, pswpin, pswpout   (SPEC 9.6; pswpin/out are cumulative page counts)
--cgroup system (default): cpu/mem/procs are machine-wide, PSI is /proc/pressure/*.
--cgroup <dir>|self:        cpu/mem/procs are that cgroup's (cpu.stat usage_usec, memory.current, cgroup.procs), PSI is its *.pressure.
"""
import json
import os
import signal
import sys
import time

stop = False


def on_term(*_):
    global stop
    stop = True


signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)


def rd(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def psi(path):
    for line in rd(path).splitlines():
        if line.startswith("some"):
            for tok in line.split():
                if tok.startswith("avg10="):
                    return float(tok[6:])
    return float("nan")


def vmstat():
    d = {}
    for line in rd("/proc/vmstat").splitlines():
        k, _, v = line.partition(" ")
        d[k] = int(v)
    return d


def meminfo():
    d = {}
    for line in rd("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        d[k] = int(v.split()[0])   # kB
    return d


def cgroup_dir(arg):
    if arg == "system":
        return None
    if arg == "self":
        rel = rd("/proc/self/cgroup").strip().split(":", 2)[-1]
        return "/sys/fs/cgroup" + rel
    return arg


def series(out, cg_arg, interval):
    cg = cgroup_dir(cg_arg)
    t0 = time.time()
    prev_cpu = None
    f = open(out, "w")
    f.write("t,cpu_usage_delta_s,memory_current_mb,procs,psi_cpu_avg10,psi_mem_avg10,psi_io_avg10,mem_used_mb,pswpin,pswpout\n")
    tick = os.sysconf("SC_CLK_TCK")
    while not stop:
        if cg:
            cpu = next((int(l.split()[1]) / 1e6 for l in rd(cg + "/cpu.stat").splitlines() if l.startswith("usage_usec")), 0.0)
            mem = int(rd(cg + "/memory.current") or 0) / 2**20
            procs = len(rd(cg + "/cgroup.procs").split())
            p = [psi(cg + "/cpu.pressure"), psi(cg + "/memory.pressure"), psi(cg + "/io.pressure")]
        else:
            fields = rd("/proc/stat").splitlines()[0].split()[1:]
            busy = sum(int(x) for i, x in enumerate(fields[:8]) if i not in (3, 4))   # all but idle, iowait
            cpu = busy / tick
            mi = meminfo()
            mem = (mi["MemTotal"] - mi["MemAvailable"]) / 1024
            procs = sum(1 for e in os.listdir("/proc") if e.isdigit())
            p = [psi("/proc/pressure/cpu"), psi("/proc/pressure/memory"), psi("/proc/pressure/io")]
        mi = meminfo()
        vm = vmstat()
        delta = 0.0 if prev_cpu is None else cpu - prev_cpu
        prev_cpu = cpu
        f.write("%.1f,%.3f,%.1f,%d,%s,%s,%s,%.1f,%d,%d\n" % (
            time.time() - t0, delta, mem, procs, p[0], p[1], p[2],
            (mi["MemTotal"] - mi["MemAvailable"]) / 1024, vm.get("pswpin", 0), vm.get("pswpout", 0)))
        f.flush()
        time.sleep(interval)
    f.close()


def latency(out, interval_ms):
    late = []
    want = interval_ms / 1000.0
    while not stop:
        t = time.perf_counter()
        time.sleep(want)
        late.append((time.perf_counter() - t - want) * 1000.0)
    late.sort()

    def pc(p):
        return late[min(len(late) - 1, int(len(late) * p / 100.0))] if late else None
    json.dump({"samples": len(late), "interval_ms": interval_ms, "p50": pc(50), "p99": pc(99), "max": late[-1] if late else None},
              open(out, "w"))


if __name__ == "__main__":
    if sys.platform != "linux":
        sys.exit("sampler.py: skipped: Linux-only (SPEC 15.4)")
    a = sys.argv[1:]
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a else d
    if a and a[0] == "series":
        series(opt("--out"), opt("--cgroup", "system"), float(opt("--interval", 1.0)))
    elif a and a[0] == "latency":
        latency(opt("--out"), float(opt("--interval-ms", 10)))
    else:
        sys.exit(__doc__)

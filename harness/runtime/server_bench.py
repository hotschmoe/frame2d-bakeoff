#!/usr/bin/env python3
"""SPEC 8.5 server benchmarks. The server is started through the stack's own `run_server` with FRAME2D_ADDR on the stack's port
(18080 + offset, as in harness/server_conformance.sh) and stopped by PID. Three fresh server processes, so every peak is
clean: (A) idle RSS then `oha -z 30s -c 64 -m POST -D gen_50_50.json /solve`; (B) /sweep 1000 variants on gen 10 10;
(C) /sweep 200 variants on gen 50 50. Per phase: wall, CPU-seconds, peak RSS, peak OS threads (sampled 100 ms), core utilization.
CPU-seconds come from psutil cpu_times of the server process (user+system); cgroup accounting is not used (see README)."""
import http.client
import json
import subprocess
import sys
import time
from pathlib import Path

import f2d

psutil = f2d.psutil


def extra(ap):
    ap.add_argument("--duration", default=None)
    ap.add_argument("--conns", type=int, default=64)
    ap.add_argument("--direct", action="store_true", help="run the build_server_release binary directly instead of run_server")


a = f2d.cli_args("server bench", extra)
stack, out = a.stack, a.outp
conf = f2d.cfg(stack)
art = f2d.load_artifacts(stack, out)
cli, serverbin = art.get("cli"), art.get("server")
oha = f2d.find_tool("oha")
if not cli:
    sys.exit("no cli artifact (needed for `gen`)")
if psutil is None:
    sys.exit("psutil is required for the server bench")
port = int(f2d.os.environ.get("F2D_PORT") or 18080 + conf["port_offset"])
duration = a.duration or ("5s" if a.quick else "30s")
sweeps = [("sweep_1000_gen10x10", 10, 100 if a.quick else 1000), ("sweep_200_gen50x50", 50, 20 if a.quick else 200)]
wd = f2d.work_dir(stack)
log = out / "logs" / "server.log"
res = {"stack": stack, "port": port, "cores_logical": f2d.NCPU, "quick": a.quick, "started_via": "direct binary" if a.direct else "run_server",
       "oha": None, "tools": {"oha": oha}}


def gen(n, path):
    r = f2d.run_measured([cli, "gen", str(n), str(n), "-o", str(path)])
    if r["rc"] != 0 or not Path(path).exists():
        sys.exit(f"gen {n} {n} failed: {r['stderr'][-300:]}")


gen50, gen10 = wd / "gen_50_50.json", wd / "gen_10_10.json"
gen(50, gen50)
gen(10, gen10)


def http_json(method, path, body=None, timeout=3600):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        c.request(method, path, body=body, headers={"Content-Type": "application/json"})
        r = c.getresponse()
        data = r.read()
        return r.status, data
    finally:
        c.close()


class Server:
    def __init__(self):
        if f2d.port_in_use(port):
            sys.exit(f"port {port} is already in use: refusing to start (will not kill foreign processes)")
        env = f2d.os.environ.copy()
        env["FRAME2D_ADDR"] = f"127.0.0.1:{port}"
        self.lf = open(log, "ab")
        self.lf.write(f"\n==== {f2d.now_iso()} start server on {port}\n".encode())
        if a.direct:
            cmd = [serverbin]
        else:
            cmd = [f2d.bash_exe(), "-c", "source ./stack.sh >&2 && run_server"]
        kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if f2d.IS_WIN else {"start_new_session": True}
        self.p = subprocess.Popen(cmd, cwd=str(f2d.stack_dir(stack)), env=env, stdout=self.lf, stderr=self.lf, **kw)
        t0 = time.time()
        ok = False
        while time.time() - t0 < 1500:
            if self.p.poll() is not None:
                break
            try:
                st, body = http_json("GET", "/health", timeout=2)
                if st == 200:
                    ok = True
                    break
            except OSError:
                pass
            time.sleep(0.25)
        self.startup_s = round(time.time() - t0, 2)
        if not ok:
            self.stop()
            sys.exit(f"server did not become healthy (see {log})")
        lp = f2d.listener_pid(port)
        self.wrapper = self.p.pid
        self.pid = lp or self.wrapper
        self.proc = psutil.Process(self.pid)
        self.proc_name = self.proc.name()

    def cpu(self):
        t = self.proc.cpu_times()
        return t.user + t.system

    def stop(self):
        pids = {self.p.pid}
        try:
            pids.add(self.pid)
        except AttributeError:
            pass
        for pid in list(pids):
            f2d.kill_tree(pid)
        try:
            self.p.wait(timeout=10)
        except Exception:  # noqa: BLE001
            pass
        self.lf.close()
        for _ in range(50):
            if not f2d.port_in_use(port):
                break
            time.sleep(0.1)


def measure(srv, fn):
    """Run fn() while sampling the server; return phase metrics."""
    smp = f2d.Sampler(srv.pid, 0.1, tree=False)
    c0, t0 = srv.cpu(), time.perf_counter()
    smp.start()
    r = fn()
    wall = time.perf_counter() - t0
    c1 = srv.cpu()
    s = smp.stop()
    peak = f2d.os_peak_rss(srv.proc)
    cpu = c1 - c0
    return r, {"wall_s": round(wall, 3), "cpu_s": round(cpu, 3), "core_utilization": round(cpu / (wall * f2d.NCPU), 4) if wall else None,
               "avg_cores_busy": round(cpu / wall, 2) if wall else None,
               "peak_rss_mb": f2d.mb(max(peak or 0, (s["peak_rss_mb"] or 0) * 2**20)), "peak_threads": s["peak_threads"],
               "rss_end_mb": f2d.mb(srv.proc.memory_info().rss)}


# ---- phase A: idle + oha ---------------------------------------------------------------------------------
srv = Server()
try:
    time.sleep(1 if a.quick else 3)
    res["server_process"] = {"pid_measured": srv.pid, "name": srv.proc_name, "startup_to_healthy_s": srv.startup_s,
                             "note": "startup includes the build step run_server performs" if not a.direct else ""}
    res["idle_rss_mb"] = f2d.mb(srv.proc.memory_info().rss)
    res["idle_threads"] = srv.proc.num_threads()
    if oha:
        cmd = [oha, "-z", duration, "-c", str(a.conns), "-m", "POST", "-D", str(gen50), "-H", "Content-Type: application/json",
               "--output-format", "json", "--no-tui", f"http://127.0.0.1:{port}/solve"]

        def run_oha():
            p = subprocess.run(cmd, capture_output=True, text=True)
            return p

        p, m = measure(srv, run_oha)
        try:
            j = json.loads(p.stdout)
        except Exception:  # noqa: BLE001
            j = {}
        sm, lp = j.get("summary", {}), j.get("latencyPercentiles", {})
        codes = j.get("statusCodeDistribution", {})
        total = sum(codes.values()) if codes else 0
        ms = lambda x: None if x is None else round(x * 1000, 3)
        res["oha"] = {"cmd": " ".join(cmd), "duration": duration, "connections": a.conns, "rps": sm.get("requestsPerSec"),
                      "success_rate": sm.get("successRate"), "p50_ms": ms(lp.get("p50")), "p95_ms": ms(lp.get("p95")), "p99_ms": ms(lp.get("p99")),
                      "latency_avg_ms": ms(sm.get("average")), "slowest_ms": ms(sm.get("slowest")),
                      "status_codes": codes, "errors": j.get("errorDistribution"), "total_responses": total,
                      "response_bytes_per_req": sm.get("sizePerRequest"),
                      "cpu_s_per_1000_req": round(m["cpu_s"] / total * 1000, 4) if total else None, **m,
                      "oha_rc": p.returncode, "oha_stderr_tail": f2d.tail(p.stderr, 3)}
        print(f"[{stack}] oha: rps={res['oha']['rps']} p50={res['oha']['p50_ms']}ms p99={res['oha']['p99_ms']}ms rss={m['peak_rss_mb']}MB "
              f"cpu_s={m['cpu_s']} threads={m['peak_threads']} util={m['core_utilization']}", flush=True)
    else:
        res["oha"] = {"error": "oha not found"}
finally:
    srv.stop()

# ---- phases B/C: sweeps ------------------------------------------------------------------------------------
for name, n, variants in sweeps:
    model = json.loads((gen10 if n == 10 else gen50).read_text())
    body = json.dumps({"model": model, "variants": variants, "beam_I_scale": [0.5, 2.0]}).encode()
    srv = Server()
    try:
        time.sleep(1)
        idle = f2d.mb(srv.proc.memory_info().rss)

        def go():
            st, data = http_json("POST", "/sweep", body)
            return st, data

        (st, data), m = measure(srv, go)
        info = {"variants": variants, "model": f"gen {n} {n}", "http_status": st, "idle_rss_mb": idle, **m}
        try:
            j = json.loads(data)
            info["variants_returned"] = len(j.get("variants", []))
            info["envelope"] = j.get("envelope")
            info["ok"] = st == 200 and info["variants_returned"] == variants
        except Exception as e:  # noqa: BLE001
            info["ok"] = False
            info["error"] = f"bad response: {e}; {data[:200]!r}"
        res[name] = info
        print(f"[{stack}] {name}: ok={info['ok']} wall={m['wall_s']}s cpu_s={m['cpu_s']} util={m['core_utilization']} (cores busy {m['avg_cores_busy']}/{f2d.NCPU}) "
              f"rss={m['peak_rss_mb']}MB threads={m['peak_threads']}", flush=True)
    finally:
        srv.stop()

res["notes"] = ("Each phase is a fresh server process (run_server rebuilds if needed; that time is excluded from the metrics). "
                "peak_rss_mb = OS-maintained peak (Windows PeakWorkingSetSize / Linux VmHWM) of the listening server process; "
                "cpu_s = psutil user+system of that process delta over the phase; core_utilization = cpu_s / (wall * logical cores); "
                "cpu_s_per_1000_req = cpu_s / responses * 1000. Client and server share this machine.")
f2d.jwrite(out / "server.json", res)

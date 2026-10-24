#!/usr/bin/env python3
"""SPEC 9.2 Flutter hot reload: drive `flutter run --machine` (the command comes from the stack's hot_reload_probe)
and time from the file write (ui edit) to the app.progress "Reloaded" event.

usage: hotreload.py <bash> <stack-dir> <probe-command> <edit.sh> <out.jsonl> <reps> <warmup> [startup-timeout-s]
Records, one JSON object per line:
  {"kind":"startup","flutter_run_to_started_s":..}
  {"kind":"rep","edit":"ui","rep":i,"file_write_to_reloaded_s":..,"file_write_to_response_s":..,"message":".."}   (measured reps only)
  {"kind":"error",...}
The ui edit is toggled warmup+reps times; the caller restores it (edit.sh --restore counts these toggles).
"""
import json
import subprocess
import sys
import time

import proc

bash, sd, probe, edit_sh, out, reps, warm = sys.argv[1:8]
reps, warm = int(reps), int(warm)
startup_to = float(sys.argv[8]) if len(sys.argv) > 8 else 900.0
rec = open(out, "w", encoding="utf-8")


def emit(d):
    rec.write(json.dumps(d) + "\n")
    rec.flush()


def event(line):
    line = line.strip()
    if not (line.startswith("[") and line.endswith("]")):
        return None
    try:
        return json.loads(line)[0]
    except (ValueError, IndexError):
        return None


app = {}


def started(line):
    e = event(line)
    if e and e.get("event") == "app.started":
        app["id"] = e["params"]["appId"]
        return True
    return False


t0 = time.perf_counter()
p = proc.spawn([bash, "-c", probe])
rc = 0
try:
    t, _ = proc.wait_line(p, started, startup_to)
    if isinstance(t, str):
        emit({"kind": "error", "error": f"flutter run did not reach app.started ({t})", "tail": p.log[-15:]})
        rc = 1
    else:
        emit({"kind": "startup", "flutter_run_to_started_s": t - t0})
        time.sleep(2.0)   # let the first frame settle
        rid = 100
        for i in range(warm + reps):
            subprocess.run([bash, edit_sh, sd, "ui"], check=True)
            tw = time.perf_counter()
            rid += 1
            req = [{"id": rid, "method": "app.restart",
                    "params": {"appId": app["id"], "fullRestart": False, "reason": "manual", "pause": False}}]
            p.stdin.write(json.dumps(req) + "\n")
            p.stdin.flush()
            reloaded = {}
            seen = []

            def done(line, rid=rid):
                e = event(line)
                if not e:
                    return False
                prm = e.get("params") or {}
                if e.get("event"):
                    seen.append({"dt": round(time.perf_counter() - tw, 3), "event": e["event"], "id": prm.get("id") or prm.get("progressId"),
                                 "finished": prm.get("finished"), "message": prm.get("message")})
                # the hot-reload progress event: id/progressId "hot.reload", finished=true (message is often empty on finish)
                if e.get("event") == "app.progress" and prm.get("finished") and "hot" in str(prm.get("progressId") or prm.get("id") or ""):
                    reloaded.setdefault("t", time.perf_counter())
                    reloaded["msg"] = prm.get("message")
                return e.get("id") == rid
            t, line = proc.wait_line(p, done, 300)
            if isinstance(t, str):
                emit({"kind": "error", "rep": i, "error": f"no response to app.restart ({t})", "tail": p.log[-15:]})
                rc = 1
                break
            resp = event(line)
            if i >= warm:
                emit({"kind": "rep", "edit": "ui", "rep": i - warm,
                      "file_write_to_reloaded_s": (reloaded["t"] - tw) if "t" in reloaded else None,
                      "file_write_to_response_s": t - tw, "message": reloaded.get("msg"),
                      "result": resp.get("result", resp.get("error")), "events": seen[:12]})
            time.sleep(1.0)
        try:
            p.stdin.write(json.dumps([{"id": 999, "method": "app.stop", "params": {"appId": app["id"]}}]) + "\n")
            p.stdin.flush()
            proc.wait_line(p, lambda l: (event(l) or {}).get("id") == 999, 20)
        except OSError:
            pass
finally:
    proc.kill_tree(p)
    rec.close()
sys.exit(rc)

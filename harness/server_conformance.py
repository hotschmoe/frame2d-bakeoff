#!/usr/bin/env python3
"""Server conformance (SPEC 5.4, 6.4). usage: server_conformance.py <base-url>

Checks /health, /solve against fixtures, 422 per error fixture, a /models round trip, /models/{id}/solve,
and /sweep (shape, envelope, and variants 0 and N-1 against the reference solver; the full golden
fixtures/golden/sweep_10_10.json is also compared when it exists).
"""
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))
sys.path.insert(0, str(ROOT / "harness" / "reference"))
import conformance as C  # noqa: E402
import ref  # noqa: E402

base = sys.argv[1].rstrip("/")
fails = 0


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def check(name, ok, detail=""):
    global fails
    print(f"{'ok  ' if ok else 'FAIL'} {name}{'  ' + str(detail) if detail and not ok else ''}")
    fails += not ok


def fixture(fid):
    p = next((ROOT / "fixtures").glob(f"p*/{fid}.json"))
    fx = json.loads(p.read_text())
    return fx, fx.pop("expect")


def wait_ready():
    for _ in range(100):
        try:
            if call("GET", "/health")[0] == 200:
                return True
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        time.sleep(0.3)
    return False


def verify(model, expect, name):
    st, res = call("POST", "/solve", model)
    for e in expect:
        if "error" in e:
            check(f"{name} -> 422 {e['error']}", st == 422 and res.get("error") == e["error"], (st, res))
            continue
        try:
            got = C.resolve(C.normalize(res), e["path"])
            if "len" in e:
                ok = len(got) == e["len"]
            elif isinstance(e["value"], str):
                ok = got == e["value"]
            else:
                ok = C.close(got, e["value"], C.REL, C.ABS)
        except (KeyError, IndexError, TypeError):
            ok, got = False, None
        check(f"{name} {e['path']}", st == 200 and ok, got)


def sweep_checks():
    model = ref.gen(10, 10)
    n, lo, hi = 1000, 0.5, 2.0
    st, sw = call("POST", "/sweep", {"model": model, "variants": n, "beam_I_scale": [lo, hi]})
    check("POST /sweep status", st == 200, st)
    if st != 200:
        return
    v = sw["variants"]
    check("sweep variant count", len(v) == n, len(v))
    check("sweep envelope consistent",
          C.close(sw["envelope"]["max_abs_M"], max(x["max_abs_M"] for x in v), 1e-9, 1e-9)
          and C.close(sw["envelope"]["max_roof_drift_W"], max(x["roof_drift_W"] for x in v), 1e-9, 1e-12))
    top_left = 10 * 11 + 1
    for k in (0, n - 1):
        scale = lo + (hi - lo) * k / (n - 1)
        mm = json.loads(json.dumps(model))
        for s in mm["sections"]:
            if s["id"] == "BM":
                s["I"] *= scale
        r = ref.solve(mm)
        drift = next(d["ux"] for d in r["load_cases"][2]["displacements"] if d["node"] == top_left)
        maxm = max(abs(s["M"]) for lc in r["load_cases"] for mem in lc["members"] for s in mem["stations"])
        got = v[k]
        ok = (C.close(got["scale"], scale, 1e-9, 1e-12) and C.close(got["roof_drift_W"], drift, 1e-8, 1e-10)
              and C.close(got["max_abs_M"], maxm, 1e-8, 1e-6))
        check(f"sweep variant {k} vs reference", ok, (got, drift, maxm))
    gold = ROOT / "fixtures" / "golden" / "sweep_10_10.json"
    if gold.exists():
        check("sweep vs golden", not list(C.diff_golden(sw, json.loads(gold.read_text()))))


def main():
    global fails
    if not wait_ready():
        sys.exit("server did not become ready")
    st, body = call("GET", "/health")
    check("GET /health", st == 200 and body == {"ok": True}, body)

    for fid in ["F01", "F03", "F05", "F10", "F13", "F14", "F15"]:
        m, ex = fixture(fid)
        verify(m, ex, f"POST /solve {fid}")

    m, ex = fixture("F05")
    st, res = call("POST", "/models", m)
    mid = res.get("id") if isinstance(res, dict) else None
    check("POST /models", st in (200, 201) and isinstance(mid, str), (st, res))
    if mid:
        st, back = call("GET", f"/models/{mid}")
        check("GET /models/{id} round trip", st == 200 and C.normalize(back) == C.normalize(m), st)
        st, res = call("POST", f"/models/{mid}/solve")
        got = C.resolve(C.normalize(res), "/load_cases/0/displacements/1/uy") if st == 200 else None
        check("POST /models/{id}/solve", st == 200 and C.close(got, ex[0]["value"], C.REL, C.ABS), (st, got))

    sweep_checks()
    print(f"\n{'FAILED' if fails else 'all passed'} ({fails} failures)")
    sys.exit(1 if fails else 0)


main()

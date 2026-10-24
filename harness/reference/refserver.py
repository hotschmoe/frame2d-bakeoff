#!/usr/bin/env python3
"""Tiny reference HTTP server (SPEC 5.4) used only to test harness/server_conformance.py.

usage: refserver.py [port]   (default 18081)
/sweep here solves only variants 0 and N-1 exactly and fills the rest with placeholders, so it
passes the conformance spot-checks; it is not a real sweep implementation.
"""
import http.server
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ref  # noqa: E402

store = {}


def sweep_variant(model, scale):
    mm = json.loads(json.dumps(model))
    for s in mm["sections"]:
        if s["id"] == "BM":
            s["I"] *= scale
    r = ref.solve(mm)
    top_left = min(n["id"] for n in model["nodes"] if n["y"] == max(p["y"] for p in model["nodes"]))
    drift = next(d["ux"] for d in r["load_cases"][2]["displacements"] if d["node"] == top_left)
    maxm = max(abs(s["M"]) for lc in r["load_cases"] for me in lc["members"] for s in me["stations"])
    return {"scale": scale, "roof_drift_W": drift, "max_abs_M": maxm}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            return self.send(200, {"ok": True})
        if self.path.startswith("/models/"):
            m = store.get(self.path.split("/")[2])
            return self.send(200 if m else 404, m)
        return self.send(404, None)

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(length) or b"null")
        try:
            if self.path == "/solve":
                return self.send(200, ref.solve(body))
            if self.path == "/models":
                store["1"] = body
                return self.send(201, {"id": "1"})
            if self.path.endswith("/solve"):
                return self.send(200, ref.solve(store[self.path.split("/")[2]]))
            if self.path == "/sweep":
                n, (lo, hi) = body["variants"], body["beam_I_scale"]
                out = []
                for k in range(n):
                    sc = lo + (hi - lo) * k / (n - 1)
                    out.append(sweep_variant(body["model"], sc) if k in (0, n - 1)
                               else {"scale": sc, "roof_drift_W": 0.0, "max_abs_M": 0.0})
                return self.send(200, {"variants": out, "envelope": {
                    "max_roof_drift_W": max(v["roof_drift_W"] for v in out),
                    "max_abs_M": max(v["max_abs_M"] for v in out)}})
        except ref.ModelError as e:
            return self.send(422, {"error": e.code, "detail": e.detail})
        return self.send(404, None)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18081
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

#!/usr/bin/env python3
"""SPEC 8.6 binary size: CLI, server, desktop (bundle and engine library alone), web (total brotli q11 + engine .wasm alone).
Flags and 'stripped' come from stacks.json (mirrors stack.sh; check stack_sh_sha256 in meta.json for drift). Writes binsize.json."""
import fnmatch
import json
import subprocess
import sys
from pathlib import Path

import f2d

a = f2d.cli_args("binary sizes")
stack, out = a.stack, a.outp
conf = f2d.cfg(stack)
art = f2d.load_artifacts(stack, out)
node = f2d.find_tool("node")
res = {"stack": stack, "flags": conf["flags"], "stripped": conf["stripped"], "release_profile": conf["flags"].get("profile"), "unit": "bytes"}


def fsz(p):
    return f2d.file_size(p) if p else None


res["cli"] = {"path": art.get("cli"), "bytes": fsz(art.get("cli"))}
res["server"] = {"path": art.get("server"), "bytes": fsz(art.get("server"))}

exe = art.get("desktop_exe")
d = {"exe": exe, "exe_bytes": fsz(exe)}
bd = art.get("desktop_bundle_dir")
if bd:
    d["bundle_dir"] = bd
    d["bundle_bytes"] = f2d.dir_size(bd)
    libs = []
    for p in Path(bd).iterdir():
        if p.is_file() and any(fnmatch.fnmatch(p.name, g) for g in conf["engine_lib_globs"]):
            libs.append({"name": p.name, "bytes": p.stat().st_size})
    d["engine_lib"] = libs or None
    d["engine_lib_bytes"] = sum(l["bytes"] for l in libs) if libs else None
    # largest bundle members (Flutter's engine dominates: SPEC 8.6)
    files = sorted(((p.stat().st_size, str(p.relative_to(bd)).replace("\\", "/")) for p in Path(bd).rglob("*") if p.is_file()), reverse=True)[:6]
    d["largest_bundle_files"] = [{"path": n, "bytes": s} for s, n in files]
else:
    d["bundle_bytes"] = d["exe_bytes"]
    d["engine_lib"] = None
    d["engine_lib_bytes"] = None
    d["engine_lib_note"] = conf.get("engine_lib_note")
    d["engine_alone_proxy"] = {"what": "frame2d CLI binary (engine, no UI/server)", "bytes": res["cli"]["bytes"]}
res["desktop"] = d


def web_sizes(dist):
    if not node or not dist:
        return {"error": "node or web dist missing"}
    p = subprocess.run([node, str(f2d.HERE / "static_server.mjs"), "--root", dist, "--manifest", "--cache", str(f2d.HERE / ".work" / "brotli-cache")],
                       capture_output=True, text=True)
    try:
        m = json.loads(p.stdout)
    except Exception:  # noqa: BLE001
        return {"error": "manifest failed: " + f2d.tail(p.stderr, 5)}
    by = {f["path"]: f for f in m["files"]}

    def pick(globs):
        got = [f for f in m["files"] if any(fnmatch.fnmatch(f["path"], g) for g in globs)]
        return [{"path": f["path"], "raw": f["raw"], "br": f["br"]} for f in got]

    eng = pick(conf["web_engine_globs"])
    app = pick(conf.get("web_app_globs", []))
    top = sorted(m["files"], key=lambda f: -f["br"])[:8]
    return {"dist": dist, "files": len(m["files"]), "total_br_bytes": m["total_br"], "total_raw_bytes": m["total_raw"],
            "engine_wasm": eng, "engine_wasm_br_bytes": sum(e["br"] for e in eng) or None, "engine_wasm_raw_bytes": sum(e["raw"] for e in eng) or None,
            "engine_note": conf.get("web_engine_note"), "flutter_app_code": app or None,
            "largest_by_br": [{"path": f["path"], "raw": f["raw"], "br": f["br"]} for f in top], "brotli": m.get("brotli"),
            "note": "total = every file in the static dir (what a deploy ships), including files a given load never fetches"}


w = art.get("web")
res["web"] = {"label": "default", **web_sizes(w["dist"] if w else None)}
wa = art.get("web_alt")
if wa:
    res["web_alt"] = {"label": wa["label"], "what": wa.get("what"), **web_sizes(wa["dist"])}
f2d.jwrite(out / "binsize.json", res)
mbf = lambda x: None if x is None else round(x / 2**20, 2)
print(f"[{stack}] sizes MB: cli={mbf(res['cli']['bytes'])} server={mbf(res['server']['bytes'])} desktop_bundle={mbf(d['bundle_bytes'])} "
      f"engine_lib={mbf(d['engine_lib_bytes'])} web_br={mbf(res['web'].get('total_br_bytes'))} web_engine_br={mbf(res['web'].get('engine_wasm_br_bytes'))}")

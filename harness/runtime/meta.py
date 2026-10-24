#!/usr/bin/env python3
"""Write meta.json: identity, host, tool versions, stack.sh hash (so drift from stacks.json is detectable)."""
import platform
import subprocess
import sys

import f2d

a = f2d.cli_args("meta")
stack, out = a.stack, a.outp


def sh(cmd, **kw):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kw)
        return (p.stdout or p.stderr).strip().splitlines()[0][:200] if (p.stdout or p.stderr).strip() else None
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


tools = {}
for name, cmd in {"scc": ["scc", "--version"], "oha": ["oha", "--version"], "node": ["node", "--version"], "twiggy": ["twiggy", "--version"],
                  "hyperfine": ["hyperfine", "--version"]}.items():
    tools[name] = sh(cmd) if f2d.which(cmd[0]) else None
tools["bloaty"] = sh(["bloaty", "--version"]) if f2d.which("bloaty") else None
tools["python"] = sys.version.split()[0]
tools["psutil"] = f2d.psutil.__version__ if f2d.psutil else None
r = f2d.stack_fn(stack, 'for t in "rustc --version" "go version" "zig version" "flutter --version" "wasm-bindgen --version" "wasm-opt --version"; do echo "$t => $($t 2>&1 | head -1)"; done')
tv = {l.split(" => ")[0]: l.split(" => ", 1)[1] for l in r["lines"] if " => " in l}
gpu = None
if f2d.IS_WIN:
    gpu = sh(["powershell", "-NoProfile", "-Command", "(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + ' ' + $_.DriverVersion }) -join '; '"])
elif f2d.which("lspci"):
    gpu = sh(["sh", "-c", "lspci | grep -i -E 'vga|3d|display' | head -1"])
f2d.jwrite(out / "meta.json", {
    "run": f2d.run_id(), "machine": f2d.machine_id(), "stack": stack, "date": f2d.now_iso(), "quick": a.quick,
    "git_rev": sh(["git", "-C", str(f2d.ROOT), "rev-parse", "--short", "HEAD"]),
    "stack_sh_sha256": f2d.sha256_file(f2d.stack_dir(stack) / "stack.sh"),
    "stacks_json_sha256": f2d.sha256_file(f2d.HERE / "stacks.json"),
    "host": {"platform": platform.platform(), "machine": platform.machine(), "cpu": platform.processor(), "logical_cpus": f2d.NCPU,
             "ram_gb": round(f2d.psutil.virtual_memory().total / 2**30, 1) if f2d.psutil else None, "gpu": gpu,
             "env_md": f"results/{f2d.run_id()}/{f2d.machine_id()}/env.md (authoritative: GPU driver, power mode, disk)"},
    "tools": tools, "toolchains": tv, "versions_md": f"results/{f2d.run_id()}/versions.md",
    "note": "Run on a quiet machine, plugged in, performance power mode (SPEC 15.2). Other agents' builds distort every number.",
})

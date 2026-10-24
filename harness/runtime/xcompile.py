#!/usr/bin/env python3
"""SPEC 8.7 cross-compile: build the server and CLI for the other architecture from this host, with COLD caches, and record
success/failure honestly. Stacks are never modified: stack.sh gives the PATH/env (sourced) and the per-family commands below
mirror the stack's own release flags with a target added. Output goes to harness/runtime/.work/<stack>/x/.

Targets tried per host (the 'other arch' first, then linux/arm64 where it is a different thing):
  win-arm64 : windows/x86_64, linux/aarch64      win-x64 : windows/aarch64, linux/aarch64
  linux-x64 : linux/aarch64                      linux-aarch64 : linux/x86_64
Writes xcompile.json."""
import platform
import re
import shutil
import sys
from pathlib import Path

import f2d

a = f2d.cli_args("cross compile")
stack, out = a.stack, a.outp
conf = f2d.cfg(stack)
xc = conf["xcompile"]
log = out / "logs" / "xcompile.log"
wd = f2d.work_dir(stack) / "x"
arch = {"arm64": "arm64", "aarch64": "arm64", "amd64": "x64", "x86_64": "x64"}.get(platform.machine().lower(), platform.machine().lower())
host_os = "windows" if f2d.IS_WIN else ("macos" if sys.platform == "darwin" else "linux")
host = f"{host_os}-{arch}"
# label, os, arch, rust triple, go os, go arch, zig triple
T = {
    "windows-x64": ("windows", "x64", "x86_64-pc-windows-msvc", "windows", "amd64", "x86_64-windows-gnu"),
    "windows-arm64": ("windows", "arm64", "aarch64-pc-windows-msvc", "windows", "arm64", "aarch64-windows-gnu"),
    "linux-arm64": ("linux", "arm64", "aarch64-unknown-linux-gnu", "linux", "arm64", "aarch64-linux-gnu"),
    "linux-x64": ("linux", "x64", "x86_64-unknown-linux-gnu", "linux", "amd64", "x86_64-linux-gnu"),
}
plan = {"windows-arm64": ["windows-x64", "linux-arm64"], "windows-x64": ["windows-arm64", "linux-arm64"],
        "linux-x64": ["linux-arm64"], "linux-aarch64": ["linux-x64"], "linux-arm64": ["linux-x64"],
        "macos-arm64": ["macos-x64"], "macos-x64": ["macos-arm64"]}.get(host, ["linux-arm64"])
plan = [p for p in plan if p in T]
exe_of = lambda os_, n: n + (".exe" if os_ == "windows" else "")


def rm(p):
    if Path(p).exists():
        shutil.rmtree(p, ignore_errors=True)


def posix(p):
    return Path(p).as_posix()


def runnable(target_os, target_arch):
    if target_os != host_os:
        return False, f"{target_os} binary cannot run on a {host_os} host"
    if target_arch == arch:
        return True, "native arch"
    if host == "windows-arm64" and target_arch == "x64":
        return True, "x64 under Windows-on-ARM emulation"
    if host_os == "linux":
        q = f2d.find_tool("qemu-aarch64" if target_arch == "arm64" else "qemu-x86_64", "qemu-aarch64-static" if target_arch == "arm64" else "qemu-x86_64-static")
        return (True, f"via {q}") if q else (False, "no qemu-user installed")
    return False, "no emulator"


def run_check(binp, target_os, target_arch):
    ok, why = runnable(target_os, target_arch)
    if not ok:
        return {"ran": False, "reason": why}
    cmd = [binp, "gen", "2", "2"]
    if "qemu" in why:
        q = f2d.find_tool("qemu-aarch64" if target_arch == "arm64" else "qemu-x86_64", "qemu-aarch64-static" if target_arch == "arm64" else "qemu-x86_64-static")
        sysroot = "/usr/aarch64-linux-gnu" if target_arch == "arm64" else "/usr/x86_64-linux-gnu"
        cmd = [q] + (["-L", sysroot] if Path(sysroot).exists() else []) + cmd
    r = f2d.run_measured(cmd, timeout=60)
    good = r["rc"] == 0 and '"nodes"' in r["stdout"]
    return {"ran": True, "how": why, "ok": good, "rc": r["rc"], "stdout_head": r["stdout"][:120], "stderr_tail": f2d.tail(r["stderr"], 3)}


results = []
for label in plan:
    tos, tarch, rust_t, go_os, go_arch, zig_t = T[label]
    base = wd / label
    rm(base)
    base.mkdir(parents=True, exist_ok=True)
    kind = xc["kind"]
    log_off = log.stat().st_size if log.exists() else 0
    rec = {"target": label, "host": host, "kind": kind, "cold": True, "steps_beyond_native_build": [], "artifacts": {}}
    bins = {}
    if kind == "cargo":
        tdir = base / "target"
        cmd = f"cargo build --release --target {rust_t} {' '.join(xc['args'])}"
        rec.update(target_triple=rust_t, command=cmd, env={"CARGO_TARGET_DIR": posix(tdir)})
        r = f2d.stack_fn(stack, cmd, env={"CARGO_TARGET_DIR": posix(tdir)}, log=log, timeout=2400)
        for b in xc["bins"]:
            bins[b] = tdir / rust_t / "release" / exe_of(tos, b)
        rec["steps_beyond_native_build"] = ["rustup target add " + rust_t + " (not run by this harness: no installs)"] + (
            ["a cross linker / sysroot for " + rust_t + " (and a C cross-compiler for cc-crate builds, e.g. bundled SQLite)"] if tos != host_os else
            (["MSVC x64 build tools" ] if tos == "windows" else []))
        try:
            inst = f2d.run_measured(["rustup", "target", "list", "--installed"], timeout=30)["stdout"].split()
            rec["target_installed"] = rust_t in inst
        except Exception:  # noqa: BLE001
            rec["target_installed"] = None
    elif kind == "go":
        outd, gc = base / "out", base / "gocache"
        parts = [f"GOOS={go_os} GOARCH={go_arch} CGO_ENABLED=0 GOCACHE={posix(gc)} go build -trimpath -ldflags '-s -w' -o {posix(outd / exe_of(tos, n))} {pkg}"
                 for n, pkg in xc["pkgs"].items()]
        cmd = " && ".join(parts)
        rec.update(target_triple=f"{go_os}/{go_arch}", command=cmd, env={"GOCACHE": "fresh"})
        r = f2d.stack_fn(stack, cmd, log=log, timeout=2400)
        for n in xc["pkgs"]:
            bins[n] = outd / exe_of(tos, n)
        rec["steps_beyond_native_build"] = []
    elif kind == "gozig":
        # cgo + zig cc: work on a copy of the sources so build/libframe2d.a of the real stack is never touched.
        sroot = base / "src"
        sd = sroot / "stacks" / stack
        sd.mkdir(parents=True, exist_ok=True)
        (sroot / "harness").mkdir(parents=True, exist_ok=True)
        shutil.copy2(f2d.ROOT / "harness" / "machine-env.sh", sroot / "harness" / "machine-env.sh")
        for item in ("go.mod", "go.sum", "stack.sh", "cmd", "bridge", "zig", "engine"):
            s = f2d.stack_dir(stack) / item
            if s.is_dir():
                shutil.copytree(s, sd / item, ignore=shutil.ignore_patterns(".zig-cache", ".zig-global", "zig-out", "build"))
            elif s.exists():
                shutil.copy2(s, sd / item)
        outd = sd / "build"  # cgo LDFLAGS are -L${SRCDIR}/../../build, so the lib must land in the copy's build/
        cmd = (f"export GOFLAGS=-buildvcs=false GOOS={go_os} GOARCH={go_arch} GOCACHE={posix(base / 'gocache')}; ZIG_GO_TARGET={zig_t}; OUT={posix(outd)}; mkdir -p \"$OUT\"; "
               f"_build_static_lib release && " + " && ".join(
                   f"_go_build \"$OUT/{exe_of(tos, n)}\" {pkg} -trimpath -ldflags=\"$(_go_ldflags '-s -w ')\"" for n, pkg in xc["pkgs"].items()))
        rec.update(target_triple=f"{go_os}/{go_arch} + zig {zig_t}", command=cmd, env={"GOCACHE": "fresh", "ZIG caches": "fresh (copy of the stack sources)"})
        r = f2d.stack_fn(stack, cmd, log=log, timeout=2400, sdir=sd)
        for n in xc["pkgs"]:
            bins[n] = outd / exe_of(tos, n)
        rec["steps_beyond_native_build"] = ["stack.sh internals reused with ZIG_GO_TARGET/GOOS/GOARCH overridden (zig cc is the cgo compiler); sources copied so the stack's build/ is untouched; GOFLAGS=-buildvcs=false because the copy is not a git checkout"]
    elif kind == "zig":
        pre = base / "out"
        extra = " ".join(f"-D{k}={zig_t}" for k in xc.get("extra", []))
        steps = " ".join(xc["steps"])
        cmd = f"zig build {steps} -Dtarget={zig_t} -Doptimize=ReleaseFast {extra} --prefix {posix(pre)} --cache-dir {posix(base / 'zig-local-cache')}"
        rec.update(target_triple=zig_t, command=cmd, env={"ZIG_LOCAL_CACHE": "fresh", "ZIG_GLOBAL_CACHE_DIR": "stack's own (package sources kept; compiled std/compiler-rt for the new target are built into it)"})
        r = f2d.stack_fn(stack, cmd, log=log, timeout=2400)
        for n in xc["bins"]:
            bins[n] = pre / "bin" / exe_of(tos, n)
        rec["steps_beyond_native_build"] = []
    else:
        sys.exit("unknown xcompile kind " + kind)
    rec["rc"] = r["rc"]
    sect = log.read_bytes()[log_off:].decode(errors="replace") if log.exists() else ""
    rec["first_error_lines"] = [l.strip()[:300] for l in sect.splitlines() if re.search(r"error", l, re.I)][:3] if r["rc"] != 0 else None
    rec["cold_build_wall_s"] = r["wall_s"]
    lg = log.read_text(errors="replace") if log.exists() else ""
    rec["error_tail"] = f2d.tail(lg, 14) if r["rc"] != 0 else None
    for n, p in bins.items():
        sz = f2d.file_size(p)
        rec["artifacts"][n] = {"path": str(p), "bytes": sz}
    rec["success"] = r["rc"] == 0 and all(v["bytes"] for v in rec["artifacts"].values())
    if rec["success"]:
        first = next(iter(bins.values()))
        rec["runs"] = run_check(str(first), tos, tarch)
    results.append(rec)
    print(f"[{stack}] xcompile {label}: {'OK' if rec['success'] else 'FAILED'} in {rec['cold_build_wall_s']:.1f}s"
          + (f" ({rec['error_tail'].splitlines()[-1][:160]})" if not rec["success"] and rec.get("error_tail") else "")
          + (f" runs={rec['runs']}" if rec.get("runs") else ""), flush=True)
f2d.jwrite(out / "xcompile.json", {"stack": stack, "host": host, "attempts": results,
                                   "note": "cold = fresh target dir / GOCACHE / Zig local cache; downloaded sources (cargo registry, Go module cache, Zig packages) are kept. Failures are recorded as results, not retried with extra installs."})

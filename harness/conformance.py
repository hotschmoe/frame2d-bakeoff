#!/usr/bin/env python3
"""Run `frame2d solve` on the conformance fixtures and compare (SPEC section 6).

usage: conformance.py <stack> <p1|p2|all> [--bin PATH] [--no-golden]

The binary comes from --bin, or from `build_cli_release` in stacks/<stack>/stack.sh
(last stdout line is taken as the path).

Expect-block entries:
  {"path": "/json/pointer", "value": <number|string>}   numbers use the section 6.1 tolerance
  {"path": "/json/pointer", "len": N}                    array length
  {"error": "<code>"}                                    CLI must exit 2 with that error code
Pointers are resolved after sorting every array of objects by "id"/"node".
"""
import argparse
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL, ABS = 1e-9, 1e-12
G_REL, G_ABS = 1e-8, 1e-10
GOLDEN = ["gen_10_10", "gen_50_50"]
VOLATILE_STATS = {"assemble_ms", "factor_ms", "solve_ms", "alloc_count", "alloc_bytes", "peak_heap_bytes"}


def close(a, b, rel, floor):
    return abs(a - b) <= max(floor, rel * abs(b))


def normalize(x):
    """Sort arrays of objects keyed by id or node so pointers are stable."""
    if isinstance(x, dict):
        return {k: normalize(v) for k, v in x.items()}
    if isinstance(x, list):
        x = [normalize(v) for v in x]
        for key in ("id", "node"):
            if x and all(isinstance(v, dict) and key in v for v in x):
                return sorted(x, key=lambda v: v[key])
    return x


def resolve(doc, pointer):
    cur = doc
    for part in pointer.strip("/").split("/"):
        cur = cur[int(part)] if isinstance(cur, list) else cur[part]
    return cur


def find_bin(stack, override):
    if override:
        return override
    sh = ROOT / "stacks" / stack / "stack.sh"
    out = subprocess.run(["bash", "-c", f'cd "{sh.parent.as_posix()}" && source stack.sh && build_cli_release'],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"build_cli_release failed:\n{out.stdout}\n{out.stderr}")
    return out.stdout.strip().splitlines()[-1]


def run_solve(binary, model):
    with tempfile.TemporaryDirectory() as td:
        mp, rp = pathlib.Path(td, "model.json"), pathlib.Path(td, "results.json")
        mp.write_text(json.dumps(model))
        p = subprocess.run([binary, "solve", str(mp), "-o", str(rp)], capture_output=True, text=True, timeout=300)
        if p.returncode == 0:
            return 0, normalize(json.loads(rp.read_text()))
        try:
            return p.returncode, json.loads(p.stdout)
        except json.JSONDecodeError:
            return p.returncode, {"raw_stdout": p.stdout, "stderr": p.stderr}


def check_fixture(binary, path):
    fx = json.loads(path.read_text())
    expect = fx.pop("expect")
    code, res = run_solve(binary, fx)
    problems = []
    for e in expect:
        if "error" in e:
            if code != 2:
                problems.append(f"expected exit 2 ({e['error']}), got exit {code}")
            elif res.get("error") != e["error"]:
                problems.append(f"expected error {e['error']}, got {res.get('error')}")
            continue
        if code != 0:
            problems.append(f"{e['path']}: solve failed with exit {code}: {str(res)[:200]}")
            continue
        try:
            got = resolve(res, e["path"])
        except (KeyError, IndexError, ValueError) as ex:
            problems.append(f"{e['path']}: unresolved ({ex!r})")
            continue
        if "len" in e:
            if len(got) != e["len"]:
                problems.append(f"{e['path']}: len {len(got)} != {e['len']}")
        elif isinstance(e["value"], str):
            if got != e["value"]:
                problems.append(f"{e['path']}: {got!r} != {e['value']!r}")
        elif not close(got, e["value"], REL, ABS):
            problems.append(f"{e['path']}: got {got!r}, want {e['value']!r}")
    return problems


def diff_golden(got, want, path=""):
    """Recursive compare at golden tolerance; profile_* must match exactly, timing/alloc stats are ignored."""
    if isinstance(want, dict):
        for k, v in want.items():
            if k in VOLATILE_STATS:
                continue
            if k not in got:
                yield f"{path}/{k}: missing"
            else:
                yield from diff_golden(got[k], v, f"{path}/{k}")
    elif isinstance(want, list):
        if len(got) != len(want):
            yield f"{path}: len {len(got)} != {len(want)}"
        else:
            for i, (g, w) in enumerate(zip(got, want)):
                yield from diff_golden(g, w, f"{path}/{i}")
    elif isinstance(want, (int, float)) and not isinstance(want, bool):
        exact = path.rsplit("/", 1)[-1].startswith("profile_")
        if (got != want) if exact else not close(got, want, G_REL, G_ABS):
            yield f"{path}: got {got!r}, want {want!r}"
    elif got != want:
        yield f"{path}: {got!r} != {want!r}"


def check_golden(binary, name):
    gold = ROOT / "fixtures" / "golden" / f"{name}.results.json"
    if not gold.exists():
        return None
    _, b, s = name.split("_")
    with tempfile.TemporaryDirectory() as td:
        mp = pathlib.Path(td, "model.json")
        p = subprocess.run([binary, "gen", b, s, "-o", str(mp)], capture_output=True, text=True)
        if p.returncode != 0:
            return [f"gen failed: {p.stderr[:200]}"]
        code, res = run_solve(binary, json.loads(mp.read_text()))
    if code != 0:
        return [f"solve failed with exit {code}"]
    return list(diff_golden(res, normalize(json.loads(gold.read_text()))))[:20]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stack")
    ap.add_argument("phase", choices=["p1", "p2", "all"])
    ap.add_argument("--bin")
    ap.add_argument("--no-golden", action="store_true")
    a = ap.parse_args()

    binary = find_bin(a.stack, a.bin)
    phases = ["p1", "p2"] if a.phase == "all" else [a.phase]
    failed = total = 0
    for ph in phases:
        for path in sorted((ROOT / "fixtures" / ph).glob("F*.json")):
            total += 1
            problems = check_fixture(binary, path)
            print(f"{'FAIL' if problems else 'ok  '} {path.stem}")
            for pr in problems:
                print(f"       {pr}")
            failed += bool(problems)
    if not a.no_golden:
        for name in GOLDEN:
            problems = check_golden(binary, name)
            if problems is None:
                print(f"skip {name} (no golden file yet)")
                continue
            total += 1
            print(f"{'FAIL' if problems else 'ok  '} {name}")
            for pr in problems:
                print(f"       {pr}")
            failed += bool(problems)
    print(f"\n{total - failed}/{total} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

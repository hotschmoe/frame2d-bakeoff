#!/usr/bin/env python3
"""Flip the BENCH-EDIT:<name> line of a stack between two states (SPEC 9.2).

usage: toggle.py <stack> <name> <state-a> <state-b>
Exactly one line under stacks/<stack>/ must carry the marker. States may list alternates separated by '|' (paired by position). If it contains state-b it becomes state-a,
otherwise state-a becomes state-b, so repeated runs alternate and every run is a real change.
"""
import pathlib
import sys

SKIP = {"target", "zig-out", ".zig-cache", "build", ".dart_tool", "node_modules", "generated", ".git"}
stack, name, a, b = sys.argv[1:5]
root = pathlib.Path(__file__).resolve().parent.parent.parent / "stacks" / stack
marker = f"BENCH-EDIT:{name}"
hits = []
for p in root.rglob("*"):
    if p.is_file() and not (set(p.relative_to(root).parts) & SKIP):
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if marker in text:
            hits.append((p, text))
if len(hits) != 1 or sum(l.count(marker) for l in hits[0][1].splitlines()) != 1:
    sys.exit(f"toggle: expected exactly one {marker} line in {root}, found {[str(h[0]) for h in hits]}")
path, text = hits[0]
lines = text.split("\n")
for i, line in enumerate(lines):
    if marker in line:
        for sa, sb in zip(a.split("|"), b.split("|")):
            if sb in line:
                lines[i] = line.replace(sb, sa, 1)
                break
            if sa in line:
                lines[i] = line.replace(sa, sb, 1)
                break
        else:
            sys.exit(f"toggle: marker line has neither {a!r} nor {b!r}: {line.strip()}")
        print(f"{path.relative_to(root)}:{i + 1}: {lines[i].strip()}")
path.write_text("\n".join(lines), encoding="utf-8", newline="")

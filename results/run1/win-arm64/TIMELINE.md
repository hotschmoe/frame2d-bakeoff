# run1 / win-arm64 agent timeline

Orchestrator: Claude Opus 5.5 (`claude-opus-5-5`). Stack agents: Sonnet 5.5 (`claude-sonnet-5-5`), Claude Code Agent tool, background.

## Deviations

- **Concurrency (SPEC 2.10).** Up to 3 agents run at once to save time, so agent wall times and SPEC 8.1 build timings are **indicative only**. Overlaps are listed per row below.
- **No whole-run accounting (SPEC 9.7).** Windows has no per-run cgroups; `harness/measure.sh` uses its psutil fallback (`measure_fallback.py`), so Linux-only fields are null.
- **dvui smoke test occupies a slot.** The SPEC 15.6 smoke test runs as the start of the `zig` turn (queue position 2). While it runs, `rust` (position 3) takes the third slot. `zig` P1 starts only after the smoke test passes.
- **zig P1 prompt note.** The `zig` kickoff text says "Run the SPEC 15.6 smoke test first". Since the orchestrator already ran it, one orchestrator line was added after the verbatim kickoff, saying the smoke test passed and giving the pinned dvui commit, so the agent does not repeat it. No smoke-test code was handed over.
- **Harness `bash` on Windows (fixed mid-run, human-authorized 2026-10-23).** `conformance.py` (without `--bin`) and `measure_fallback.py` started plain `bash`; Windows resolves that to the System32 WSL stub (no distro), so `build_cli_release` failed and agents' `measure.sh` builds were not recorded. Agents worked around it (direct builds or `--bin`). The human authorized the orchestrator to patch both files to prefer `$F2D_BASH`, then Git for Windows bash, and to convert MSYS `/c/...` paths printed by `stack.sh`. Committed separately at 23:23. Consequence: SPEC 8.1 build-wait data from measure.sh is missing for builds before the fix (rust P1/P2, and early zig-flutter / zig P1).
- **Goldens on hold (rule 10, reported to human).** `rust` was first to pass P1. Its `gen 10 10` matches `fixtures/golden/reference/gen_10_10.results.json`: displacements to 1e-8 (0 diffs), profile exact (10221 / 7575, 330 free DOFs), residuals <= 3.4e-13 (50x50: <= 2.4e-11). But `diff_golden` reports 5 diffs: case D member 60 `end_forces[2]`, `end_forces[5]`, `stations[0,9,10].M` are roundoff-zero (rust 1.4e-10..1.8e-10 vs reference 2.9e-11..3.7e-11; abs floor 1e-10). Goldens NOT committed pending human decision.

## Timeline

Times are local (UTC-07:00). `overlapping` lists the other agents running at any point during the row's span.

| stack | phase | start | end | result | overlapping |
|-------|-------|-------|-----|--------|-------------|
| zig-flutter | P1 | 2026-10-23 22:53 | | running | dvui-smoke, rust P1, zig P1, rust P2, rust-flutter P1 |
| zig (dvui smoke, SPEC 15.6) | smoke | 2026-10-23 22:53 | 2026-10-23 23:00 | PASS (dvui 275c248f) | zig-flutter P1, rust P1 |
| rust | P1 | 2026-10-23 22:53 | 2026-10-23 23:18 | GREEN (conformance p1 15/15, server all passed; verified by orchestrator) | zig-flutter P1, dvui-smoke, zig P1 |
| rust | P2 | 2026-10-23 23:19 | 2026-10-23 23:22 | GREEN (p2 5/5, p1 15/15, server all passed; verified by orchestrator) | zig-flutter P1, zig P1 |
| rust-flutter | P1 | 2026-10-23 23:23 | | running | zig-flutter P1, zig P1 |
| zig | P1 | 2026-10-23 23:01 | | running | zig-flutter P1, rust P1, rust P2, rust-flutter P1 |

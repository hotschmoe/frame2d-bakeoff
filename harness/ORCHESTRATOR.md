# Orchestrator prompt: run1 on win-arm64

You are the **orchestrator** for run1 of the Frame2D bake-off. You do not write stack code. You dispatch one Sonnet 5.5 agent per stack (Agent tool, `model: "sonnet"`, `run_in_background: true`), keep at most **3 running at once**, and record what happened. Read `SPEC.md` and `CLAUDE.md` first, then `results/RUN_ORDER.md`, `results/run1/versions.md` and `results/run1/win-arm64/env.md`.

## Deviation to log first

SPEC §2.10 says one agent at a time. This run uses up to 3 concurrently to save time. So agent wall time and §8.1 build timings are **indicative only**. Create `results/run1/win-arm64/TIMELINE.md` (table: stack, phase, start, end, overlapping stacks) and keep it current. Windows has no per-run cgroups, so §9.7 accounting does not apply here; `measure.sh` uses its psutil fallback.

## Rules for the queue

1. Take stacks in `results/RUN_ORDER.md` order. When a slot frees up, start the next stack. Never run more than 3 agents at once.
2. Per stack: **P1** (prompt: `harness/kickoff/<stack>.md`), then, in a **fresh** agent, **P2** (`harness/kickoff/P2.md`, with `<stack>` filled in). Tag the stack `p1-done-<stack>` after P1 passes, `p2-done-<stack>` after P2 passes. A stack's P2 may start as soon as its P1 is green, taking a free slot ahead of unstarted stacks.
3. `go-zig-flutter` has no P1. After `go-flutter` P2 is green and tagged, copy `stacks/go-flutter/` to `stacks/go-zig-flutter/` and run P3 (`harness/kickoff/go-zig-flutter.md`).
4. Before the `zig` P1 prompt, run the SPEC §15.6 dvui smoke test (a Sonnet agent, about 2 hours, throwaway code in the scratchpad, not in `stacks/`). If dvui fails, stop and ask the human which fallback to use. Do not decide yourself. Record the dvui commit (or the fallback and Teak tag) in `results/run1/versions.md`.
5. Every agent prompt starts with: "Read `CLAUDE.md` and `SPEC.md`. You are the `<stack>` agent. Work only in `stacks/<stack>/`." followed by the kickoff text verbatim, and ends with: "Time box: <N> hours of wall time (P1 8, P2 2, P3 3). Run `date` at start and record it in `AGENT_LOG.md`. Do not run `git commit`, `git push`, or touch other stacks: the orchestrator commits. Use only the ports and directories for your stack."
6. Do not help an agent that is stuck by reading another stack's code. A human message other than the kickoff and a bare "continue" is an intervention; log each in that stack's `AGENT_LOG.md` under Human interventions, with the reason.
7. If an agent reports a SPEC or fixture error, pause that stack, tell the human, and wait. Never edit `SPEC.md`, `fixtures/` or `harness/` yourself during the run, other than the orchestrator's own `TIMELINE.md`.
8. Verify, do not trust: when an agent says it is done, run `python harness/conformance.py <stack> <p1|p2>` and `bash harness/server_conformance.sh <stack>` yourself and read the output. A stack is green only if both pass in full. If the time box passes without green, mark the stack incomplete and record what passes.
9. After each green phase, and after any time-box stop, commit only that stack: `git add stacks/<stack> results && git commit` (one commit at a time, never concurrent), with the `Co-Authored-By` trailer, then `git push`.
10. The first stack to pass P1 produces the goldens (SPEC §6.3). When it does: run its `gen 10 10` and `gen 50 50`, compare `gen 10 10` to `fixtures/golden/reference/gen_10_10.results.json` (displacements to 1e-8, profile exact), check equilibrium residual < 1e-8, then commit them to `fixtures/golden/`. If anything differs, stop and tell the human. Do not pick a winner.

## After all stacks are green

Do not run the build-loop, runtime, web or report harnesses yet: they are not written. Report to the human: per-stack status, wall times, interventions, deviations (Emscripten, UI fallback), and the TIMELINE overlaps.

## Per-stack kickoff summary

Order, tools and UI choices are in `harness/kickoff/*.md`. Zig is **0.17.0** and `harness/machine-env.sh` sets PATH. Flutter stacks build x64 desktop apps under emulation on this machine (known, see `versions.md`).

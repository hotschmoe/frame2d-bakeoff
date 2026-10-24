# frame2d-bakeoff: instructions for agents

Read `SPEC.md` first. It defines everything. This file only restates the rules that matter most when you are the agent building a stack.

## If you are building a stack (P1, P2, P3, P4)

- You are given one stack id. Work **only** in `stacks/<stack>/`. **Never read, list or grep any other `stacks/*` directory.** (Exception: `go-zig-flutter` starts as a fork of `go-flutter`.)
- Your kickoff prompt is in `harness/kickoff/<stack>.md` (P2/P3 prompts alongside).
- Build, check and test **only** through the functions in your `stack.sh` (`build_check`, `build_dev`, `test_all`, ...), wrapped in `harness/measure.sh`. Never call cargo/go/zig/flutter directly for builds you want counted; flags live inside `stack.sh`.
- Write the solver yourself. No linear algebra or numeric libraries (SPEC §2.3). `harness/reference/ref.py` may be run for comparison; do not port its code.
- No Emscripten unless absolutely needed (SPEC §2.12); explain why in `AGENT_LOG.md`.
- Keep `AGENT_LOG.md` (template in `harness/templates/`): a short note for any problem that cost more than ~10 minutes.
- Do not edit `SPEC.md`, `fixtures/`, `harness/` or other stacks. If you believe the spec or a fixture is wrong, stop and say so in `AGENT_LOG.md` and to the human; do not work around it silently.
- Done means `harness/conformance.py <stack> <phase>` passes in full, plus the server conformance and bench modes for P1. Stop at the time box (SPEC §2.8).

## If you are doing repo/harness work (setup sessions)

- Commit and push at milestones, with the `Co-Authored-By` trailer.
- Fixtures are generated: edit `harness/make_fixtures.py`, then rerun it. Validate any fixture or spec change against `harness/reference/ref.py` (`python harness/conformance.py reference all --bin "python harness/reference/ref.py" --no-golden`).
- Results are tagged by run id and machine id (SPEC §15). Toolchain versions are frozen per run in `results/<run-id>/versions.md`; never upgrade mid-run.
- `results/RUN_ORDER.md` is fixed; do not reorder.

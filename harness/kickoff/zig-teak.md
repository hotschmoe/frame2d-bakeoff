# Kickoff prompt: P1, `zig-teak` (optional extra stack, SPEC 1 / 15.6)

Added 2026-10-27 at the human's request. Run on `win-x64`. Same SPEC, fixtures and harness as every other stack; P2 (`harness/kickoff/P2.md`)
and the P5 optimization pass (`harness/kickoff/P5.md`) follow in the same way.

> You are implementing **Frame2D** in the **`zig-teak`** stack, as defined in `SPEC.md` (read it fully first). Work only in `stacks/zig-teak/`. Do not read other `stacks/` directories.
>
> Requirements:
> - Implement Phase 1: engine (§4), CLI, server and client (§5), and `stack.sh` (§5.6). Start from `harness/templates/stack.sh`.
> - Place the `BENCH-EDIT` markers exactly as described in §9.2 (and see §9.2's note on the `struct` marker).
> - You're done when `harness/conformance.py zig-teak p1`, `harness/server_conformance.sh zig-teak`, and all bench modes (§5.5) run successfully on desktop and web.
> - Keep `AGENT_LOG.md` as described in §8.1 (template: `harness/templates/AGENT_LOG.md`).
> - Build and test only through the functions in `stack.sh` (`build_check`, `build_dev`, `test_all`, etc.), wrapped in `harness/measure.sh`, so every build you run is measured with the same flags the harness uses.
> - Allowed dependencies are in §2.3. Write the solver yourself. No Emscripten unless absolutely needed (§2.12).
> - `harness/reference/ref.py` is a reference solver you may run to compare numbers. Do not copy its code; the solver must be written natively for this stack.
>
> Stack-specific choices: Zig 0.17.0 (pinned). UI: **Teak** (https://github.com/hotschmoe/teak), pinned by commit hash in `build.zig.zon`; web through
> Teak's zunk/WebGPU path (no Emscripten). Server: `std.http` (or http.zig). Bridge: none. Use the file layout implied by
> `harness/runtime/stacks.json` (`zig-teak` entry) so the code-size buckets work: `src/engine.zig model.zig solver.zig report.zig`,
> `src/cli.zig`, `src/server.zig store.zig sweep.zig`, `src/ui.zig canvas.zig table.zig state.zig bench.zig`, `src/platform.zig`, `build.zig`, `web/`.
>
> Teak gaps (SPEC 15.6 dogfooding rule): do **not** patch Teak inside this stack. When Teak lacks something or has a bug, file it on
> `hotschmoe/teak` with the label `frame2d` (check existing issues #125-#132 first and comment there instead of duplicating), work around it
> app-side if you reasonably can, and keep going. A separate agent works the Teak backlog in parallel and cuts commits; bump your pinned
> Teak commit when an issue you need is closed. Log Teak-caused time separately in `AGENT_LOG.md` (it is excluded from this stack's
> agent-handling numbers, SPEC 15.6).

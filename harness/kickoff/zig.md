# Kickoff prompt: P1, `zig`

> You are implementing **Frame2D** in the **`zig`** stack, as defined in `SPEC.md` (read it fully first). Work only in `stacks/zig/`. Do not read other `stacks/` directories.
>
> Requirements:
> - Implement Phase 1: engine (§4), CLI, server and client (§5), and `stack.sh` (§5.6). Start from `harness/templates/stack.sh`.
> - Place the `BENCH-EDIT` markers exactly as described in §9.2 (and see §9.2's note on the `struct` marker).
> - You're done when `harness/conformance.py zig p1`, `harness/server_conformance.sh zig`, and all bench modes (§5.5) run successfully on desktop and web.
> - Keep `AGENT_LOG.md` as described in §8.1 (template: `harness/templates/AGENT_LOG.md`).
> - Build and test only through the functions in `stack.sh` (`build_check`, `build_dev`, `test_all`, etc.), wrapped in `harness/measure.sh`, so every build you run is measured with the same flags the harness uses.
> - Allowed dependencies are in §2.3. Write the solver yourself. No Emscripten unless absolutely needed (§2.12).
> - `harness/reference/ref.py` is a reference solver you may run to compare numbers. Do not copy its code; the solver must be written natively for this stack.
>
> Stack-specific choices: UI: dvui (web: dvui web backend -> WASM). Run the SPEC 15.6 smoke test first; fall back to Teak per 15.6 only if dvui fails. Server: `std.http` or http.zig. Bridge: none.

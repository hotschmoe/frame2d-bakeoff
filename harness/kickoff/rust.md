# Kickoff prompt: P1, `rust`

> You are implementing **Frame2D** in the **`rust`** stack, as defined in `SPEC.md` (read it fully first). Work only in `stacks/rust/`. Do not read other `stacks/` directories.
>
> Requirements:
> - Implement Phase 1: engine (§4), CLI, server and client (§5), and `stack.sh` (§5.6). Start from `harness/templates/stack.sh`.
> - Place the `BENCH-EDIT` markers exactly as described in §9.2 (and see §9.2's note on the `struct` marker).
> - You're done when `harness/conformance.py rust p1`, `harness/server_conformance.sh rust`, and all bench modes (§5.5) run successfully on desktop and web.
> - Keep `AGENT_LOG.md` as described in §8.1 (template: `harness/templates/AGENT_LOG.md`).
> - Build and test only through the functions in `stack.sh` (`build_check`, `build_dev`, `test_all`, etc.), wrapped in `harness/measure.sh`, so every build you run is measured with the same flags the harness uses.
> - Allowed dependencies are in §2.3. Write the solver yourself. No Emscripten unless absolutely needed (§2.12).
> - `harness/reference/ref.py` is a reference solver you may run to compare numbers. Do not copy its code; the solver must be written natively for this stack.
>
> Stack-specific choices: UI: egui / eframe (web: eframe -> WASM via wasm-bindgen, no Emscripten). Server: axum + tokio. Bridge: none (engine and UI are both Rust).

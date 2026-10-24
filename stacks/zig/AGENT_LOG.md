# AGENT_LOG: zig, phase P1

Run id: run1   Machine: win-arm64   Agent model: claude-sonnet-5-5   Started: Fri Oct 23 23:00:40 MST 2026

## Toolchain surprises / problems over ~10 minutes

### Stale API: Zig 0.17 renamed optimize enum fields
- Time lost: ~2 minutes (below threshold, noted for the stale_api rate)
- Category: stale_api
- What happened: `std.builtin.OptimizeMode.Debug` no longer exists; the enum is now `.debug/.safe/.fast/.small`.
- What fixed it: used `.debug`.

### Golden tolerance vs. floating-point noise (spec/harness question)
- Category: wrong_result (false alarm)
- What happened: `gen 10 10` matches the reference golden in `fixtures/golden/reference` except 5 values that are
  numerically zero (station M and end-force moments, about 1e-10 absolute against force scales of 1e5). The golden
  absolute floor is 1e-10, which is below the rounding noise of any implementation. profile_before/after match exactly
  (10221 / 7575).

## Deviations (Emscripten, UI fallback, extra dependency, spec question)

- SQLite is the official amalgamation (zig fetch, compiled by build.zig), with hand-written extern bindings (no @cImport in 0.17).
- Zig global cache is kept inside the stack dir (`.zig-global`) so `clean_all` cannot disturb other stacks.

## Human interventions

- orchestrator notice: harness bash fix e99a3f6 (not help with stack code)

## Phase notes

P1 status (finished well inside the time box, about 1 h 15 min wall):
- `harness/conformance.py zig p1`: 17/17 (15 fixtures + gen_10_10 + gen_50_50 goldens). `server_conformance.sh zig`: all passed.
- Bench modes run on desktop (SDL3, D3D11) and web (headless Chromium via Playwright, swiftshader GL): drag, render, startup, ready (web), boundary (web: JS to wasm, zero-copy view; desktop: in-process, reported for completeness).
- Desktop `frame_ms` is the interval between frame starts with vsync off. dvui records draw commands and presents afterwards, so render p50 (about 1.3 ms) is mostly CPU-side command building, not GPU time.
- Drag solves on the UI thread, so lag_max is 0 by construction (input and result land in the same frame).
- Desktop startup is measured from the process creation time (GetProcessTimes); web from navigation start (performance.now()).
- Note for the harness: `conformance.py` without `--bin` initially hit the WSL bash stub (fixed by the orchestrator, e99a3f6).
- Cold build note: with an empty cache the first `zig build` compiles the build runner (about 50 s) before anything else.
- No Emscripten; web build is wasm32-freestanding with the dvui web backend and a custom index.html loader (web/index.html).

## P2 (change request SPEC 4.7)

Started: Fri Oct 23 23:38:56 MST 2026 (finished in about 15 min wall; no problems over 10 minutes).
- Files touched: model.zig (Spring, Release, JSON round trip), solver.zig (support_conflict, static condensation, springs on the diagonal, auto-restraint pre-pass, warnings), report.zig (warnings output).
- Static condensation is done on the local 6x6 stiffness and fixed-end forces by eliminating released dofs one at a time; end forces are then `kc*u + fc`, which gives zero at released ends with no back-substitution.
- Auto-restraint runs a stiffness pre-pass only when some member has a release (P1 path unchanged). Reactions stay on user-declared supports only.
- `conformance.py zig p2`: 7/7; `zig p1`: 17/17. Desktop/web UI not extended for springs/releases (not required by the P2 conformance).

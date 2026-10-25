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

## P5 optimization pass

Machine busy with other agents throughout; numbers are same-session before/after comparisons, not quiet-machine measurements.

### Changes
- `build.zig`: debug builds are stripped by default (no PDB/DWARF generation); `-Ddebug-info=true` restores it. Targets build_dev wall/CPU. Desktop debug compile 6 s -> 3 s, web wasm 4 s -> 0.6 s in isolation.
- `build.zig`: debug wasm (web) uses Zig's self-hosted backend (`use_llvm = false`). Native aarch64-windows cannot (`UnsupportedCOFFArchitecture`), so native targets stay on LLVM. Targets build_dev CPU.
- `build.zig`: CLI built `single_threaded` (it never spawns threads). Targets CLI size (0.67 -> 0.65 MB).
- `src/server.zig`: `/solve` streams the result JSON straight to the socket (`respondStreaming`, chunked, 32 KB buffers) instead of building the whole 16 MB body in memory (doubling realloc, copy). Targets server RSS and CPU per request.
- `src/report.zig`: `NumCache` reuses the formatted text of N and V across consecutive stations (constant on members without UDL) and of station x across members of equal length. Output is byte-identical (verified with cmp except timing stats). Targets JSON encode time (write phase was 30 ms of ~43 ms per gen_50_50 solve in the CLI, now far lower), used by CLI, server and sweep.
- `src/server.zig`: `respondError` JSON-escapes code and detail (review defect).
- `src/tests.zig` (new, hooked from `engine.zig`): 6 new tests (spring F21, mz release end moment, auto-restraint warning, skyline factor/solve, singular pivot, results JSON round trip incl. cache). `factor`, `solveInPlace`, `Skyline` made `pub` for the tests. 3 -> 9 tests, all pass via `test_all`.

### Smoke numbers (before -> after, same noisy session)
- build_dev after a leaf edit, measure.sh wall/CPU, 4 runs each: before 7.5-10.5 s wall, 15-18 s CPU; after 4.1-8.3 s wall, 7.8-10.2 s CPU (CPU roughly halved; wall limited by the desktop LLVM compile plus build runner start).
- Server, gen_50_50 `/solve`, oha c=64, runtime --quick: rps 207 -> 257, p50 267 -> 168 ms, peak RSS 1048 -> 402 MB, server CPU 75.8 -> 53.6 s (own script, 5 s runs: CPU per request 54 -> 41 ms, RSS 1 GB -> 30-120 MB).
- buildloop `--quick` edits (1 run each, machine heavily loaded, so only indicative): no-op check 1.5 s / dev 1.6 s; leaf check 1.7 / dev 6.6; struct 3.3 / 4.9; server 2.5 / 4.0; ui 2.8 / 10.6. Run1 quiet numbers were check ~1.1-1.2 / dev ~6.2 (server 0.7 / 2.3). Same-session A/B above (CPU halved) is the more reliable signal; real wall gain to be confirmed on a quiet machine.
- buildloop `--quick` cold: cli 72 s, dev 72 s on the loaded machine (run1 quiet: 43 / 68 s). Cold builds are dominated by compiling the build runner with dvui and its dependency build scripts, which this pass cannot change; no cold gain claimed.
- Release sizes unchanged within noise (server 1.72 MB, desktop bundle 6.92 MB, web br 0.58 MB).
- Desktop/web UI drag/render/startup: code path untouched; smoke values were within machine noise (desktop drag p50 11.6 ms on the busy machine vs 8.7 in run1), no claim.

### Review defects
- Fixed: unescaped `respondError` JSON; only 3 unit tests (added 6, incl. springs/releases).
- Rejected: 400 for malformed JSON vs 422 for model errors: SPEC only asks 422 for model errors, malformed JSON is not a model error. `solve()` length / duplicated load loops: refactor risk without a metric gain in the time box.
- Noted, not changed: a model whose only free dof is auto-restrained reports `no_free_dofs` (checked after auto-restraint); SPEC silent.

### Not done
- Reuse RCM ordering across drag solves (topology unchanged); would cut the UI drag solve a little.
- Parallel load-case solves; wasm-opt pass on web.wasm; sqlite compiled with more omit flags; server thread pool instead of thread-per-connection.
- Cold build is dominated by compiling the build runner with dvui's dependency build scripts (about 40-50 s); not reducible without changing dependencies.

### Final conformance
`conformance.py zig p1` 17/17, `p2` 7/7, `server_conformance.sh zig` all passed, `test_all` 9 tests pass, runtime --quick bench modes (desktop startup/drag/render/boundary, web ready/startup/drag/render/boundary) all ran.

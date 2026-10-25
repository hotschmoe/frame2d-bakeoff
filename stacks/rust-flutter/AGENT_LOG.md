# AGENT_LOG: rust-flutter, phase P1

Run id: run1   Machine: win-arm64   Agent model: claude-sonnet-5-5   Started: Fri Oct 23 23:23:16 2026 (local, `date` at start)

Layout: `crates/engine` (solver), `crates/cli` (`frame2d`), `crates/server` (axum + tokio + rusqlite), `crates/bridge`
(flutter_rust_bridge cdylib for desktop, wasm-bindgen module for web, one shared `api.rs`), `app/` (Flutter).

## Toolchain surprises / problems over ~10 minutes

### Intermittent native crash (access violation) in the release desktop app
- Time lost: about 75 minutes
- Category: ffi (unconfirmed) / runtime_crash
- What happened: after changing the member drawing code, the AOT release app died with 0xC0000005 on the first frame
  that showed a model. It crashed on the UI thread while it was building a picture (a plain Dart loop over typed
  data), at a different point depending on the code. The same code ran fine in the JIT debug build. Old drawing code
  that happened to allocate differently never crashed. The one thing all crashing runs had in common: the first
  paint of the new model happened while the first async flutter_rust_bridge `solve` call was still running in its
  Rust worker thread.
- What fixed it: `AppState._install` now creates the model, solves case 0, and only then publishes model and
  results together, so nothing is painted while that first async call is in flight. A 100-iteration stress mode
  (overlapping async `moveAndSolve` with repaints) did not crash afterwards. Root cause not found (no debugger on the
  machine); suspected a race between Dart GC/painting and FRB's async result delivery under x64 emulation.

### Stroked lines are very slow in Impeller (OpenGLES) on this machine
- Time lost: about 30 minutes
- Category: build_config (rendering performance)
- What happened: `drawRawPoints` hairlines cost about 4.7 us per segment on the raster thread: 330 ms per frame for the
  50x50 moment diagram and 380 ms for the 200x200 model.
- What fixed it: members, deflected shape and moment diagram are built as triangle meshes (`Canvas.drawVertices`) in
  cached world-space pictures; drag p50 went from 330 ms to about 32 ms. Per-vertex colours crashed the engine, so
  one draw per colour bucket is used.

### flutter_rust_bridge codegen path bug on Windows
- Time lost: about 10 minutes
- Category: build_config
- What happened: `rust_output:` in `flutter_rust_bridge.yaml` fails with "prefix not found" (mixed `\\?\` paths).
- What fixed it: leave `rust_output` at its default (`crates/bridge/src/frb_generated.rs`); only `dart_output` is set.

### Accidentally killed other agents' Flutter processes
- Time lost: 0 for me; may have cost another stack a bench rerun
- What happened: while chasing a hung benchmark I ran `taskkill /IM frame2d_app.exe` (and Stop-Process by name). Several
  Flutter stacks use the same exe name and run concurrently on this machine, so I may have killed a bench run in
  another stack around 23:50 to 23:55 (local). After that I only killed processes by PID.

## Deviations (Emscripten, UI fallback, extra dependency, spec question)

- No Emscripten. Web engine: `wasm32-unknown-unknown` + wasm-bindgen CLI + wasm-opt, loaded by `web/index.html`
  and called from Dart through `dart:js_interop`. flutter_rust_bridge is used for desktop only, not for web
  (FRB's own web build needs nightly Rust, which the run pins away).
- Added the Rust target `x86_64-pc-windows-msvc` (`rustup target add`). The pinned Flutter is x64 on this machine, so
  the engine DLL it loads must be x64. This adds a component to the pinned toolchain; it is not an upgrade.
- Extra Dart dependencies: `file_picker` (open/save dialogs), `ffi` (process start time on Windows for the startup bench).
- Generated code is listed in `LOC_EXCLUDE`.
- `hot_reload_probe` (optional) not implemented.
- Desktop renderer: Impeller with the OpenGLES backend (reported by the engine at start up), Adreno X2-90 via x64 emulation.
- A model and its first results are published together (see the crash note above).

## Human interventions

- none

## Phase notes

Results (win-arm64, release builds, one run each, other agents were building concurrently so treat as indicative):
see the end of this file for the numbers recorded at completion.

### Final state (finished about 01:00 local, 8 h box not exhausted; about 1.5 h of wall time)

- `harness/conformance.py rust-flutter p1`: 17/17 (F01-F15 plus both goldens). `harness/server_conformance.sh rust-flutter`: all passed.
- Unit tests via `test_all`: engine 9, server 3, bridge 2, Flutter 4. `build_check` clean.
- Cold builds through `measure.sh` (wall s / cpu s): cli release 9.1 / 11.6, server release 18.3 / 56.9, desktop release 42.0 / 20.1,
  web release (JS + `--wasm`) 73.3 / 22.9, build_check 26.5 / 59.1, build_dev 41.9 / 44.1, test_all 7.3. Flutter's own CPU is
  under-counted by the psutil fallback on Windows.
- CLI bench (median of 3): 50x50 assemble 3.2 ms, factor 9.6 ms, solve 1.6 ms, 2,705 allocations, 8.6 MB peak; 200x200 assemble 96 ms,
  factor 2,745 ms, solve 161 ms, 40,521 allocations, 425 MB peak.
- Desktop (Impeller GLES, x64 emulated): startup 1,490 ms, drag p50 32.5 / p95 35.4 / p99 39.2 / max 43.4 ms (engine solve p50 12.8 ms,
  lag_max 2 frames, RSS 599 MB), render p50 8.5 / p99 18.1 ms (single 200x200 solve 2.1 s), boundary noop 467 ns, echo(38,103) 329 us
  (FRB sync SSE copy).
- Web, JS build (headless Chromium via a throwaway Playwright script, SwiftShader, x64 emulated): ready 680 ms, startup 1,764 ms, drag p50 36 / p99 139 ms
  (solve p50 13.3 ms), render p50 52 / p99 153 ms (solve 4.1 s), boundary noop 15.5 ns, echo 59 us.
- Web, `--wasm` build: ready 551 ms, startup 1,342 ms, drag p50 36 / p99 216 ms, render p50 19 / p99 70 ms, boundary noop 34 ns, echo 61 us.
- Not done: `hot_reload_probe`; open/save dialogs were not exercised by an automated test (file_picker native dialogs).
- Run the web benches with a COOP/COEP static server; the `web/engine` directory is generated by `build_web_release` (and holds the
  debug WASM after `build_dev`, so run `build_web_release` before serving a web build).

# Phase P2 (SPEC 4.7: springs, mz releases, auto-restraint)

Started: Sat Oct 24 00:42:19 2026 (local, `date` at start). Green by about 00:55 (conformance p1+p2: 22/22, test_all ok).
Files touched (engine only): `model.rs` (Spring, Release), `topology.rs` (support_conflict, auto-restraint, release flags),
`analysis.rs` (static condensation, spring diagonal, auto_restrained warnings, spring forces in equilibrium sum),
`generate.rs` and `tests/engine.rs` (new struct fields). No problems over 10 minutes.
Design notes: auto-restrained rotations are not listed as reactions unless the node also has an explicit support.
The Flutter app and wire formats were not changed (no UI for springs/releases in P2).

## P5 optimization pass

Machine win-arm64, other agents building concurrently, so timings are indicative. Before = run1 code measured the same way
(`harness/measure.sh`, label `p5-before-*`), after = `p5-after-*` in `results/adhoc/rust-flutter/`.

### Changes
- `stack.sh` build_check / build_dev: the Dart analyzer and the Flutter desktop build are the expensive steps (about 5 s and
  10 s even when nothing changed), while the Rust steps take about 1 s each. Both are now skipped by a make-style stamp
  (`target/.stamps/`, any input file newer than the stamp re-runs them; inputs = app/lib, app/test, pubspec*, analysis_options,
  and app/windows for the build). Targets: no-op and engine/server-edit loops.
- build_dev, after an engine-only edit: the Flutter build is skipped and the fresh engine DLL is copied into the existing Debug
  bundle (what the install step would do). A Dart or Windows-runner edit still runs `flutter build windows --debug`.
- build_check / build_dev run their independent parts in parallel (3 cargo checks + analyzer; cli+server, wasm, and DLL+Flutter),
  output is buffered per job and replayed. Different target layouts, so cargo's directory locks do not serialise them.
- `flutter analyze` replaced by `dart analyze --fatal-infos` (same strictness, about 1.5 s less start-up); runs `flutter pub get`
  first when pubspec.yaml is newer than package_config.json.
- `_bridge_wasm`: wasm-bindgen / wasm-opt skipped when cargo's wasm output is unchanged for that profile.
- Cargo.toml: `[profile.dev] debug = "line-tables-only"`, `[profile.dev.package."*"] debug = false` (smaller objects, faster links;
  not measured separately). Release profile already had LTO / 1 CGU / strip; panic=abort deliberately not set (the FRB bridge
  and axum rely on unwinding to report a panic instead of dying).
- Solver `dot` (skyline.rs): 8 independent accumulators, fused multiply-add on aarch64 only (plain mul+add elsewhere, since
  `mul_add` without hardware FMA is a slow libm call on x64/wasm). Same algorithm (§4.4 LDL^T), summation order differs in the last bits.
- Server: tokio runtime built by hand with `max_blocking_threads = cores` and at most 4 workers. The default 512-thread blocking
  pool gave 534 threads and about 1 GB RSS under the oha load; requests now queue instead. Sweep failure flag is an AtomicBool
  (no mutex lock per iteration).

### Numbers (wall s)
| metric | before | after |
|---|---|---|
| build_check, leaf edit | 7.05 | 1.30 |
| build_check, struct edit | 6.7 (run1) | 1.40 |
| build_check, server edit | 5.6 (run1) | 2.0 |
| build_dev, leaf edit | 12.67 | 3.87 |
| build_dev, struct edit | 13.5 (run1) | 3.79 |
| build_dev, server edit | 9.8 (run1) | 1.72 |
| build_check / build_dev, ui edit | 5.5 / 11.4 (run1) | 4.65 / 10.19 (the Flutter tool's fixed cost remains) |
| no-op build_check / build_dev | 6.3 / 8.9 (run1) | 0.79 / 0.84 |
| CLI 100x100 factor_ms | 136.7 | 98.4 (50x50: 9.6 to 6.1) |
| x64 CLI 100x100 factor_ms (what the desktop DLL runs) | 130 (4 acc) | 113 (8 acc) |
| server oha --quick (5 s) | run1: 300 rps, p99 716 ms, 534 threads, 1016 MB RSS | 324 rps, p99 276 ms, 26 threads, 380 MB RSS |
Desktop drag (p50 34 ms, solve 11.8 ms), desktop render, web drag/render are unchanged: they are bound by Impeller GL / CanvasKit
under emulation, not by the engine. Rendering code was not touched.

Cold builds were not re-measured (cold_dev should gain from the parallel jobs and `debug = false` for dependencies, unmeasured).

### Review defects
- Fixed: `engine_move_and_solve` left a rejected position (zero_length / unstable) in the session; it now rolls back (test added).
- Fixed: unchecked id narrowing. Node / member ids outside i32 are now rejected on load with `invalid_model|...`; profile and DOF
  counts saturate instead of wrapping (test added).
- Fixed: `Store` mutex poison panics (`lock().unwrap()`); the guard is recovered, SQLite state is unaffected by a panic elsewhere.
- Fixed: missing numeric tests for releases and springs (engine tests: released end turns a propped cantilever into a simply supported
  beam, spring shares load with the member).
- Rejected: process-global `Mutex` session in the bridge. One FRB isolate owns one model by design; changing it would alter the API
  and regenerate bindings for no measurable gain. `solve_case` length / change-resilience (new load type touches ~10 places) not addressed.

### Not done
- Hot-reload probe, FRB regeneration timing, Dart-side `flutter build` speed (2.2 s "unpack_windows" check is inside the Flutter tool).
- Assembly and `solve` (forward/back substitution) tuning; the web wasm path still uses plain mul+add.
- Server: sqlite access is a single mutexed connection.

### Final conformance
`conformance.py rust-flutter p1` 17/17, `p2` 7/7, `server_conformance.sh rust-flutter` all passed (port 18097), `test_all`: engine 11, server 3,
bridge 3, Flutter 4, all pass. Smoke `runtime/run.sh rust-flutter meta build cli desktop web server binsize --quick` ran to completion
on desktop, web (JS and wasm) and server (F2D_RUN=run1p5). `buildloop edits --quick` ran; edits restored.

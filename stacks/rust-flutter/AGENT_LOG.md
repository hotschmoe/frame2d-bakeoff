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

# AGENT_LOG: zig-flutter, phase P1

Run id: run1   Machine: win-arm64   Agent model: claude-sonnet-5-5   Started: Fri Oct 23 22:52:53 USMST 2026

## Toolchain surprises / problems over ~10 minutes

### ffigen needs an x64 libclang
- Time lost: ~15
- Category: ffi
- What happened: Dart runs as x64 under emulation here, so ffigen cannot load the arm64 libclang.dll from LLVM.
- What fixed it: downloaded the win_amd64 `libclang` wheel with pip, extracted libclang.dll to `.tools/libclang-x64/bin`, and pointed `llvm-path` in `app/ffigen.yaml` at it. Generated bindings are committed under `app/lib/generated/`.

### Desktop engine library must be x86_64
- Category: build_config
- Flutter builds an x64 Windows app on this machine, so `stack.sh` builds the engine DLL with `-Ddesktop-target=x86_64-windows-gnu` while the CLI and server stay native arm64.

## Deviations (Emscripten, UI fallback, extra dependency, spec question)

- No Emscripten. Web engine is Zig `wasm32-freestanding` (simd128) loaded with dart:js_interop.
- Extra dependency: `file_selector` (Flutter team) for open/save dialogs; SQLite amalgamation 3.50.4 fetched via build.zig.zon.

## Human interventions

- orchestrator notice: harness bash fix e99a3f6 (not help with stack code)

## Phase notes

- Finished P1 in about 1h45 wall time. conformance p1 17/17 (incl. gen_10_10 golden from the reference), server conformance all passed.
- Rendering: Flutter strokes (drawRawPoints) were raster-bound under Impeller/GLES on this machine (about 8 us per segment); members are now drawn as quads in one ui.Vertices, which cut render p50 for 200x200 to about 24 ms.
- Bench (debug-free release builds): desktop drag p50 15.8 ms (solve 8.2 ms), render p50 23.8 ms, startup 1025 ms, boundary noop 5.7 ns / echo 8.9 us (zero-copy view). Web (dart2js): drag p50 44 ms, render 24 ms, boundary 6 ns / 12 us; web --wasm: drag 65 ms, render 67 ms, boundary 14 ns / 43 us (memcpy).
- `bash` on PATH is the WSL stub on this machine; I invoked Git bash explicitly before the orchestrator fix.
- Extra stack.sh function: build_web_wasm_release (output app/build/web_wasm). hot_reload_probe not implemented. ffigen output is committed; regenerate with `dart run ffigen --config ffigen.yaml` in app/ (needs .tools/libclang-x64).
- Extra bench parameters for diagnosis: --size=N, --defl=0, --moment=0, --color=0 (desktop) or ?size=N etc. (web).

# Phase P2 (spring supports, end releases, auto-restraint)

Started: Fri Oct 23 23:56:21 USMST 2026

- Done in one pass, no problems over 10 minutes. conformance p2 7/7 and p1 17/17.
- Touched src/engine only: model.zig (support_conflict, Member.rel, Model.springs), model_json.zig (springs, release, writeModel round trip), solver.zig (Geom.condense for static condensation of K and fixed-end forces, spring diagonal in assemble, auto-restrain in buildPlan, spring forces in equilibrium sum), results_json.zig (auto_restrained warnings).
- Profile stats are computed with the original supports (as ref.py does); free_dofs and factorization use the auto-restrained numbering. Reactions are listed only for nodes with user supports.
- UI (Flutter) not extended for springs/releases; the bridge compiles unchanged.

## P5 optimization pass

Changes (all in `stack.sh`, `build.zig`, `src/bridge/exports.zig`, `src/server/main.zig`, `src/engine/tests.zig`):
- stack.sh `build_dev`: each Flutter build (windows, web) is skipped when no non-engine input (app/lib, pubspec, platform dir) is newer than a stamp; a Zig-only edit just refreshes the engine DLL/WASM inside the existing build output. Targets: no-op and Zig-edit dev loop.
- `_stage_engine` copies only when content differs (`cmp`), so an unchanged engine no longer bumps mtimes and forces Flutter rebuilds. Targets: no-op dev.
- `build_dev` runs the desktop and web Flutter builds concurrently (independent output trees); `--no-wasm-dry-run` on the dev web build. Targets: UI-edit dev loop.
- `build_check`: `dart analyze` is skipped when no Dart input changed since the last clean analyze (stamped on success only). Zig `check` always runs (incremental in the Zig cache). Targets: no-op/Zig-edit check.
- Release builds clear the dev web stamp (build/web is shared). `clean_all` already removes the stamps (they live in app/build).
- build.zig: `.strip` on every module for non-Debug (smaller CLI/server/DLL/WASM); extra SQLite `-DSQLITE_OMIT_*`/`DEFAULT_MEMSTATUS=0` flags. Targets: binary size.
- Release web: `wasm-opt -O3 -all` (binaryen, only if on PATH) on the staged WASM; desktop release uses `--split-debug-info`. Targets: web download / bundle size.
- Server: `/solve` and `/models/:id/solve` stream the ~16 MB results JSON straight to the socket (chunked, 64 KB buffer) instead of building it in memory. Targets: server RSS, latency. Also a 1024-connection cap on the thread-per-connection loop (refuses beyond it; spawn failure decrements the counter).
- exports.zig: getters return null (not a trap/UB) with no session; case-name and `f2d_set_node_xy` indices are bounds checked; `adopt` rewritten with errdefers so a partial OOM no longer leaks; documented the single-thread contract. C ABI unchanged (nullable pointers have the same representation; frame2d.h and ffigen bindings untouched).
- Tests: added Zig tests for F21 tip spring, end moment release + auto-restraint, and error codes invalid_json / invalid_ref / duplicate_id / zero_length.

Smoke numbers (F2D_RUN=run1p5, win-arm64, noisy machine, sequence = before -> after; "before" = run1 baseline / the same harness on the untouched stack):
| metric | before | after |
|---|---|---|
| no-op build_dev | 33.2 s | 0.7 s |
| no-op build_check | 4.4 s | 0.5 s |
| leaf edit check / dev | 6.7 / 35.4 s | 3.2 / 4.6 s |
| struct edit check / dev | 6.6 / 36.2 s | 3.2 / 5.1 s |
| server edit check / dev | 5.9 / 35.1 s | 3.1 / 3.7 s |
| ui edit dev (one run, concurrent builds added after) | 37.8 s | 40.6 s sequential, 30.6 s concurrent |
| cold build_dev | 101 s | 88 s |
| cli / server / engine dll bytes | 1042944 / 2090496 / 497152 | 762368 / 1817088 / 357888 |
| wasm uncompressed | 1.73 MB | 0.26 MB (wasm-opt) |
| web raw / br body | 9.96 / ~2.65 MB | 8.50 / 2.31 MB |
| desktop bundle | 28.5 MB | 26.0 MB |
| server /solve gen50 (oha c=64, quick 5 s) | 134 rps, p50 450 ms, RSS 1618 MB | 169-306 rps, p50 148-257 ms, RSS 695-722 MB |
Desktop/web drag, render, startup and CLI solve are unchanged within noise (drag p50 28 ms, render 37 ms; both raster/GL bound on this machine). p99 on the server run is dominated by machine contention from other agents.

Review defects: fixed - unchecked `session.?` getters, unchecked `set_node_xy`, `adopt()` leak on partial OOM, unbounded thread per connection, thin tests (springs/releases/error codes). Rejected - sweep bad request 400 vs 422 (SPEC only requires 422 for model errors; a malformed sweep body is not a model error); 160-byte Diag truncation (details are short, no spec impact); server generic 500 for non-model failures (intended, covers only OOM/IO); export thread-safety (host calls from one thread by contract, now documented).

Not done: results JSON is ~27 ms of the ~53 ms server CPU per 50x50 request, all shortest-round-trip float formatting (35 ns/number, 760k numbers); a faster hand-rolled formatter or caching station x values would help but is a larger change. UI-edit dev loop is bound by the dart2js debug compile (~25-30 s). Per-request Solver/model allocations could use an arena. Dart UI for springs/releases not extended (outside P5 scope). Skipping the CanvasKit variants would shrink the web dir but changes browser coverage.

Final conformance: `conformance.py zig-flutter p1` 17/17, `p2` 7/7, `server_conformance.sh zig-flutter` all passed, `test_all` green (Zig tests incl. 4 new, 2 Dart); runtime smoke desktop (startup/drag/render/boundary) and web default + wasm bench modes all ran OK after the changes. Not committed.

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

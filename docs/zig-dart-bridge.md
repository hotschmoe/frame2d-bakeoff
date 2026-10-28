# Zig <-> Dart (Flutter) bridge: profile and optimization report

Scope: the bridge used by `stacks/zig-flutter` (Zig engine, `src/bridge/exports.zig`, dart:ffi via ffigen on desktop,
wasm32-freestanding + dart:js_interop on web) and `stacks/go-zig-flutter` (same idea, Go server, handle-based
sessions, JS loader shim). Goal: what to change so a **reusable Zig-engine + Flutter-UI bridge** is fast, safe and
pleasant in the dev loop and CI.

Machine: win-x64 (Core Ultra 7 270K Plus, 24 cores, Windows 11, Defender on), Zig 0.17.0, Flutter 3.47.8 /
Dart 3.13.7, Node 24, Playwright 1.64.1 + Chromium 156.0.8078.4 headless (installed under the scratch dir for this
work, `C:\Users\hotschmoe\dev\bridge-lab\pw`). **Two other agents were building on the machine throughout**, so every
timing is a median of 3-5 runs and absolute numbers carry roughly +-10% noise (build timings more). Nothing under
`stacks/`, `harness/`, `fixtures/` or `SPEC.md` was modified; all experiments ran in copies under
`C:\Users\hotschmoe\dev\bridge-lab` (the "lab", layout at the end).

## Summary: findings ranked by impact

| # | Finding | Measured before -> after | Change | Effort |
|---|---|---|---|---|
| 1 | The UI-edit dev loop is a full rebuild; hot reload is 100x faster | ui edit `build_dev` 18.5 s -> hot reload 0.17 s / hot restart 0.21 s | Iterate UI with `flutter run` (+ `hot_reload_probe`), keep `build_dev` for CI; drop the debug web compile from the inner loop | S |
| 2 | ~50 s of every cold Zig build is the build runner / global-cache warm-up, not the engine | cold `zig build lib` 60 s -> 6.8 s with a warm global cache (runner only: 48.5 / 51.4 s) | Share one `ZIG_GLOBAL_CACHE_DIR` per machine / CI cache key = zig version; don't wipe `o/` | S |
| 3 | Real memory-safety bugs in the bridge contract (views into freed / detached memory) | web: held result view length 7803 -> 0 after `f2d_export_model`; my own first unified web engine hit it too (dart2wasm: TypeError on a detached buffer; dart2js: silently drew empty geometry, drag "p50" 17.6 ms instead of 38-40 ms); native: access violation from a one-line `out_ptr`/`export` call order | Return (ptr,len) together, add a memory epoch/generation, never hand out views that outlive the next mutating call; copy into Dart-owned reused buffers where views must persist | M |
| 4 | Flutter build hooks (native assets) are stable in 3.47.8 and work for Zig | prototype: DLL built + bundled by `hook/build.dart`, no CMake edits, no copy step; `@Native` noop 1.50 ns vs ffigen 1.90 ns in the release app | Ship the engine as a Dart package with `hook/build.dart` + `@Native` bindings | M |
| 5 | The `boundary` metric measures the engine's fill loop, not the crossing | zig-flutter "transfer_us" 7.1 us = 7.10 us engine fill; true call + zero-copy view = 6 ns | Make `f2d_echo` fill once (as go-zig-flutter does) or report fill separately | S |
| 6 | Long solves run on the UI thread although moving them costs microseconds | 50x50 solve 6.3 ms (console) / 8.1 ms (app) on the UI isolate; round trip to a helper isolate 2.4 us, to a native worker via `NativeCallable.listener` 9.9 us | Engine-owned worker thread + listener (or a helper isolate), double-buffered results, `lag_frames` becomes 0-1 | M |
| 7 | Web module: ReleaseSmall beats ReleaseFast + wasm-opt | br 88.3 KB (stack release) -> 60.4 KB (ReleaseSmall) / 59.6 KB (+ `-Oz`), solve 8.85 -> 8.96 ms | `-Doptimize=ReleaseSmall` for the wasm artifact only; `wasm-opt -O3` currently makes the brotli payload *bigger* | S |
| 8 | Copies: the API used matters 25x | `Float64List.fromList(view)` 105 us vs `setRange` into a reused list 3.9 us (native); JS `slice()` 91 us vs view 0.07 us (web) | Never allocate a fresh 300 KB list per frame; reuse buffers | S |
| 9 | One API description can generate the C header, the ffi bindings and the web bindings | prototype generator (Zig comptime) emits all four files; one Dart engine class (151 lines) replaces 140 + 258 + 364 generated lines; desktop, dart2js and dart2wasm drag benches match the stack (14.5 / 38-42 / 48 ms p50) | `flutter_zig_bridge` sketch below | M |
| 10 | Cross-compiling from one Windows host covers everything but iOS dylibs | 11/11 desktop + Android targets build in 6-7 s each; iOS static libs build after a 6-line workaround; iOS dylib needs the SDK | CI: one Linux/Windows job for all non-Apple targets + a macOS job for iOS/macOS signing | S-M |
| 11 | Engine DLL hot swap works on Windows (dev only) | swap + state restore + 50x50 solve = 27 ms, old image really unloaded | Dev-mode `DynamicLibrary` backend that watches `zig-out` and reloads | M |

Smaller items (struct returns, `isLeaf` on long calls, 64-bit ints on wasm, Android TLS) are in the detailed sections.

---

## 1. Developer loop

### 1.1 Why a UI edit costs 17-18 s and what hot reload costs (finding 1)

Method: lab copy of zig-flutter, `harness/edits/toggle.py` UI edit, 3 runs each (`bin/uiloop.sh`), then
`bin/hotreload_probe.py` driving `flutter run -d windows --machine --debug` and timing `app.restart` responses.

| step after a UI edit | median |
|---|---:|
| stack `build_dev` (desktop and web Flutter builds in parallel) | **18.5 s** (18.54 / 18.57 / 18.58) |
| `flutter build windows --debug` alone | 6.6 s |
| `flutter build windows --debug`, nothing changed (fixed cost: tool start, assemble, CMake/MSBuild) | 5.0 s |
| `flutter build web --debug` (dart2js debug) alone | 17-21 s |
| `flutter build web --debug`, nothing changed | 3.2 s |
| **hot reload** (`flutter run`, edit, reload: "Reloaded 1 of 793 libraries") | **0.17 s** |
| hot restart | 0.21 s |
| `flutter run` launch to `app.started` | 11.2 s (6.2 s for the hook-based app with a warm build) |

So the 17 s is the dart2js web compile, which `build_dev` waits for on every Dart edit. Desktop alone would be 6.6 s,
of which 5 s is fixed Flutter/CMake overhead. (For scale: `dart compile js` of the 270-line plain-Dart web bench in
the lab takes 0.9 s; the Flutter framework is what makes dart2js slow.)

Recommendation for a reusable template:
- inner loop = `flutter run` + hot reload (0.17 s) for UI work; this works unchanged with a native library because
  the DLL stays loaded across reload **and restart** (note: the engine's process globals therefore also survive a hot
  restart; the Dart side must re-create or re-query its session on startup, which the stack already does);
- implement the optional `hot_reload_probe` with the lab script (it toggles the marker, sends `app.restart`, waits for
  the response; kills only the process it started);
- keep the web build out of `build_dev` (or behind a flag); run it in `test`/CI, or iterate the web UI with
  `flutter run -d web-server` instead of `flutter build web`.

### 1.2 Native leaf edit (~3 s) and what a no-op redoes

Method: lab engine copy with per-artifact steps added to `build.zig` (`lib`, `wasm`, `cli`), real leaf edits
(`toggle.py` on the `BENCH-EDIT:leaf` line), 3 runs each, warm cache (`bin/zigrunner.sh`).

| `zig build <step>` after a leaf edit | Debug | ReleaseFast |
|---|---:|---:|
| `lib` (desktop DLL only) | 2.0 s | 5.3 s |
| `wasm` only | 1.1 s | 3.3 s |
| `cli` only | 2.4 s | 7.1 s |
| `check` (cli + server + dll + wasm + tests) | 2.9 s | 8.8 s |

The stack's leaf `build_check` (3.0 s) is the `check` row: the engine is recompiled once per artifact (5 compilations,
partly parallel); Zig does not share compiled modules between artifacts. The stack's no-op `build_dev` is already
0.4 s because `stack.sh` stamps skip Flutter entirely; a no-op Zig build is ~0.1 s. Nothing heavy is redone on a no-op.

Leaf edit to a running app: the stack builds the DLL and copies it into the existing Flutter output (3.2 s), but the
running app must still be restarted to load it (SPEC 9.2 "engine edit to running app"). Options:
- dev loop builds only the artifact being exercised (`zig build lib`), not all five (saves ~1 s in Debug, ~3.5 s in
  ReleaseFast);
- go-zig-flutter uses ReleaseFast for the dev library because Debug makes the solver ~10x slower; that trade-off is
  right for an interactive app, and the `lib` step keeps it at 5.3 s;
- for engine work without restarting the app, see the hot swap (section 1.5).

`-fincremental` was not evaluated (SPEC 9.3 asks for it; not in this scope).

### 1.3 Cold builds: the 50 s nobody needs to pay twice (finding 2)

Method: fresh local cache and global cache (package sources `p/` kept), lab engine copy, `bin/zigdecomp.sh` and
`bin/zigrunner.sh`.

| cold step (Debug) | wall |
|---|---:|
| `zig build --help` only (compiles the build runner; nothing of ours) | 48.5 s / 51.4 s |
| `zig build lib`, from fully cold | 60.0 s |
| `zig build wasm`, from fully cold | 55.9 s |
| `zig build check`, from fully cold | 63.0 s |
| `zig build install` (cli, server+SQLite, dll, wasm), from fully cold | 72.4 s |
| `zig build lib` Debug / ReleaseFast **after** the runner is cached | 6.8 s / 5.3 s |
| editing `build.zig` (runner recompiles) | 2.8 s |

About 50 s of every cold Zig build on this machine is per-Zig-version global-cache warm-up (build runner and its
std/compiler_rt objects), shared by every project that uses the same Zig. `stack.sh` gives each stack a private
`ZIG_GLOBAL_CACHE_DIR` and `clean_all` wipes everything but `p/`, which is correct for the bake-off's cold-build metric
but the wrong default for a multi-project template:
- dev machines: one global cache per Zig version (Zig's cache is lock-protected and safe for concurrent builds);
- CI: cache `$ZIG_GLOBAL_CACHE_DIR` keyed on `zig version` + `build.zig.zon` hash (package sources) and the local
  cache keyed on the source hash; the measured saving is ~50 s per job, about 60-70% of zig-flutter's cold builds
  (70-100 s in `results/run1p5/win-x64`).

### 1.4 Flutter build hooks / native assets (finding 4)

**Status in Flutter 3.47.8:** `flutter_tools/lib/src/features.dart` has `nativeAssets` *enabled by default on stable*
(no `flutter config` flag needed). `flutter_tools` itself pins `hooks 2.0.2`, `hooks_runner 1.5.0`,
`code_assets 1.2.1`; a package may depend on `code_assets ^2.0.0` (needed anyway to coexist with `ffigen ^23`, which
requires `code_assets ^2`; the lab resolved `code_assets 2.1.0`, `hooks 2.2.0`). Web builds do **not** run code-asset
hooks (code assets are native only; data assets are master-only), so the wasm still has to be staged into `web/`.

**Prototype** (`C:\Users\hotschmoe\dev\bridge-lab\frame2d_engine`): a Dart package with `hook/build.dart` that maps
`input.config.code.targetOS/targetArchitecture` to a Zig triple, runs `zig build lib -Doptimize=ReleaseFast
-Ddesktop-target=<triple> --prefix <outputDirectory>`, adds a `CodeAsset(name: 'frame2d_engine.dart',
linkMode: DynamicLoadingBundled())`, and declares every `.zig` file as a dependency. The app
(`C:\Users\hotschmoe\dev\bridge-lab\app_hook`) depends on it by path. Result:
- no CMake install rule, no `_stage_engine` copy, no `DynamicLibrary.open(<exe dir>)` path logic: Flutter bundles
  `build/native_assets/windows/frame2d_engine.dll` next to the exe itself (debug and release verified, `flutter run`
  verified, `dart run` verified);
- the same hook gives correct per-ABI libraries for Android/iOS/macOS/Linux builds (Flutter calls it once per target),
  which is the part that is otherwise hand-written per platform runner;
- `@Native` externals with an `assetId` replace the `DynamicLibrary` + `late final` lookups.

| measured (lab, 3 runs, median) | stack today | hook prototype |
|---|---:|---:|
| release app `--bench=boundary` noop | 1.90 ns (1.88-1.93) | **1.50 ns** (1.49-1.51) |
| release app `--bench=drag` p50 / solve_p50 | 14.1 / 8.16 ms | 14.5 / 8.28 ms (same within noise) |
| `flutter build windows --debug`, no-op | 5.0 s (stack.sh skips it: 0.4 s) | 5.1 s |
| `flutter build windows --debug` after a Zig leaf edit | n/a (stack: zig + copy 3.2 s) | 9.8 s (hook runs `zig build lib` ReleaseFast) |
| first `flutter build windows --debug` | - | 25.4 s |
| `dart run` (pure Dart consumer) first / no-op | - | 7.3 s / 0.67 s |

Trade-off: hooks make every `flutter build/run` correct and portable but do not make the edit loop faster; the
5 s Flutter fixed cost stays. Keep a direct `zig build lib` + hot swap (1.5) for engine iteration, and let the hook be
the single source of truth for packaging and CI. Rough edges: hooks have no Debug/Release input (the hook picks the
Zig optimize mode itself, here always ReleaseFast); the hook's stderr is hidden unless the build fails.

### 1.5 Hot swapping the engine DLL (finding 11)

`DynamicLibrary.close()` (Dart 3.1+) calls `FreeLibrary`. Prototype `ffibench/bin/hotswap.dart`: snapshot the
model as JSON (`f2d_export_model`), close, delete the old image (succeeds, so Windows really unmapped it), open a
fresh copy `frame2d_engine.<n>.dll` (a copy, because a loaded DLL cannot be overwritten in place), `f2d_load_json`,
solve. **27 ms** median per swap including the 50x50 solve, results identical. Limits: only works with
`DynamicLibrary` bindings (`@Native` symbols are bound to the asset for the process lifetime), so this is a dev-only
backend; memory allocated by the old image leaks unless the engine exports a `shutdown` that frees it
(RSS reached 72 MB after 6 loads); any engine threads must be joined before `close`. Wiring: a debug-only file
watcher on `zig-out/bin` in the app, triggered after `zig build lib` (2 s Debug / 5.3 s ReleaseFast), gives
engine-edit-to-running-app in ~2-5 s without losing UI state.

### 1.6 ffigen

ffigen needs libclang (on win-arm64 an x64 libclang had to be downloaded, AGENT_LOG) and only describes the native
side. The generator in section 4 removes ffigen, libclang and the hand-maintained `frame2d.h` from the loop
(the generated header is byte-for-byte the same prototypes as the hand-written one).

---

## 2. Runtime

### 2.1 dart:ffi call overhead

Method: `C:\Users\hotschmoe\dev\bridge-lab\ffibench\bin\bench.dart`, AOT (`dart compile exe`, same compiler as a
Flutter release build), against the lab DLL (stack engine + `lab_exports.zig` probes), 5 reps after a warm-up,
median (min-max in `ffibench/aot_run1.txt`; JIT numbers in `jit_run1.txt`).

| call | AOT | JIT |
|---|---:|---:|
| `f2d_noop`, `isLeaf: true` (what ffigen emits for every `f2d_*`) | 1.50 ns | 1.56 ns |
| `f2d_noop`, non-leaf | 11.5 ns | 14.2 ns |
| `@Native` leaf / non-leaf | 1.49 / 11.8 ns | 1.57 / 14.0 ns |
| `add(i64,i64)` leaf, lookup style / `@Native` | 2.45 / 2.06 ns | 2.33 / 2.37 ns |
| 50x50 solve (case 1), leaf vs non-leaf | 6.31 / 6.31 ms | 6.55 / 6.51 ms |

Conclusions: the crossing is ~1.5 ns; nothing on this path matters at 60 fps unless you make millions of calls per
frame. **But** the stack's ffigen config marks *every* function leaf, including `f2d_solve` (6-8 ms),
`f2d_load_json` and `f2d_export_*`. A leaf call keeps the isolate from reaching a safepoint for its duration
(GC in other isolates of the group waits) and forbids callbacks into Dart. The cost of marking them non-leaf is 10 ns.
Rule for the generator: leaf by default, non-leaf for anything that can run longer than ~10 us or allocate a lot
(the prototype's `bridge_meta.leaf_unsafe`).

### 2.2 Transfer mechanisms (finding 5, finding 8)

38,103 f64 values (the 50x50 payload), 2,000 iterations:

| mechanism | AOT |
|---|---:|
| stack's `f2d_echo` + `asTypedList` ("transfer_us" in the `boundary` bench) | 7.11 us |
| engine-side fill alone (`lab_fill`) | 7.10 us |
| **zero-copy: call + `asTypedList` (no fill)** | **6.2 ns** |
| memcpy into a caller-owned native buffer (`lab_echo_into`) | 4.56 us |
| view + `setRange` into a reused Dart `Float64List` | 3.87 us |
| view + `Float64List.fromList(view)` | **105 us** |
| Dart loop summing all values: external view / Dart-heap list | 14.3 / 14.2 us |
| engine summing a Dart-provided native buffer (`lab_sum`) | 14.2 us |

- The published desktop `transfer_us` (zig-flutter 8.1 us on win-arm64, 7.1 us here) is the engine writing 38k
  doubles, not the bridge. go-zig-flutter's `f2d_echo` fills once, which is why it reports 0.036 us. Fix: fill once,
  or report `fill_us` separately; otherwise the "transfer share of a solve" in SPEC 8.8 is overstated by 1000x.
- Reading through an `asTypedList` view costs the same as a Dart-heap list, so on native there is no reason to copy.
- If a copy is needed (to keep data past the next solve), `setRange` into a buffer you keep is 27x cheaper than
  `fromList` (which allocates 300 KB and appears to take a slow element path for external typed data).

### 2.3 Struct passing vs flat buffers

| stats (6 doubles) | AOT ns |
|---|---:|
| struct returned by value (`Struct` subclass) | 10.8 |
| out-pointer into a cached native buffer, read `.ref` | 2.6 |
| pointer + `asTypedList(6)` (stack) | 3.6 |

Returning structs by value allocates a Dart object per call. Prefer out-pointers into a buffer allocated once, or a
flat f64 block, which also maps 1:1 to wasm (structs by value do not cross the wasm/JS boundary at all).

### 2.4 Threading: solving off the UI isolate (finding 6)

Today: `f2d_solve` runs synchronously on the UI isolate (desktop release `drag`: frame p50 14.0 ms, `ui_p50`
10.4 ms, of which `solve_p50` 8.1 ms). SPEC 5.5 allows it, but the UI thread is blocked for half the frame budget,
and a 100x100 or 200x200 model would block it for 100 ms to seconds.

| off-thread mechanism (lab probes) | AOT round trip | JIT |
|---|---:|---:|
| long-lived helper isolate, `SendPort` request/response, no work | **2.4 us** | 3.5 us |
| persistent engine worker thread (Zig, futex handoff) + `NativeCallable.listener`, no work | 9.9 us | 5.2 us |
| new native thread per call + listener | 69 us | 75 us |
| `Isolate.run` per call, no work | 26 us | 72 us |
| 50x50 solve: sync / engine worker + listener / helper isolate / `Isolate.run` | 6.31 / 6.52 / 6.34 / 6.40 ms | |

All mechanisms add < 0.2 ms to a 6 ms solve. Two workable designs:
- **helper isolate** that owns the engine and is the only caller (cheapest, no Zig changes, but the UI isolate then
  cannot read zero-copy views of the results while the next solve runs; send results as `TransferableTypedData`
  or copy into a shared native buffer);
- **engine-owned worker** (`lab_solve_async(mask, tag, cb)` in `engine/src/bridge/exports.zig`): the Zig side runs the
  solve on its own thread and calls back through `NativeCallable.listener`; the Dart UI stays on one isolate. This is
  the better template because it is the same shape as a Web Worker on the web side.

Either way the engine must stop being a bag of unsynchronized process globals: `session`, `diag`, `scratch`,
`echo_buf`, `stats_buf`, `last_error` in exports.zig (go-zig-flutter: `sessions[256]`, `last_error`). Reviewers
flagged this and it was rejected with "single-thread contract", which is true today but rules out every design above.
Needed: a `busy` flag (the prototype rejects posts while busy and getters should refuse while busy), and
**double-buffered results**: the worker writes into the back buffer and publishes it atomically, so views the UI holds
stay valid until the UI releases them. With that, the drag bench would report `lag_frames` 1 instead of 0 and
`ui_p50` would drop by ~the solve time (estimate: ~10 ms -> ~2-3 ms on this machine; not measured in the app).

### 2.5 Safety: views into freed or detached memory (finding 3)

Two reproducible failures in the current contract:

1. **Web, detached views.** Node + the stack wasm (`webtest/detach.mjs`): generate 50x50, solve, take
   `new Float64Array(memory.buffer, f2d_disp(0), n)` (what the dart2js path returns as a "zero-copy view"), then call
   `f2d_export_model()` (the app's Save): memory grows 12.3 MB -> 14.4 MB and the held view's length becomes **0**
   (`f2d_export_results`: 12.3 -> 29.1 MB, same). In the zig-flutter web app `AppState` keeps `disp`, `endForces`,
   `maxM`, `stationM` as such views between solves, so a Save (or any call that grows memory) leaves the canvas reading
   an empty list until the next solve: a RangeError in paint under dart2js. The dart2wasm path wraps the same JS view
   (see 2.6) and has the same exposure. Also easy to trip: evaluating `memory.buffer` *before* a call that grows memory
   (it threw `RangeError` at `new Float64Array` in the first version of the web micro-bench).
2. **Native, freed memory.** `f2d_out_ptr()` returns the scratch buffer pointer, which `f2d_export_*` may reallocate.
   The natural one-liner `utf8.decode(f2d_out_ptr().asTypedList(f2d_export_model()))` evaluates the pointer first and
   reads freed memory: **access violation** in the lab (`ffibench/bin/hotswap.dart`, first version). The stack calls
   them in the right order, but the API makes the wrong order the obvious one. Same class: every `f2d_disp/...` view
   dangles after `f2d_generate`/`f2d_load_json` (the solver frees and reallocates case buffers when the size changes).

3. **It happened to the prototype.** The first version of the unified engine in `app_hook` (section 4) returned
   views for geometry too. Under dart2wasm the drag bench died with `TypeError: Cannot perform
   DataView.prototype.getInt32 on a detached or out-of-bounds ArrayBuffer` (3/3 runs timed out); under dart2js it ran
   and looked *faster* (p50 17.6 ms, raster 4.9 ms) because the detached geometry views had length 0 and nothing was
   drawn. After copying geometry once per model into Dart-owned lists (what the stack's `engine_web.dart` does by
   hand) the numbers match the stack: dart2js p50 38.8-41.9 ms (stack rerun 37.6-37.8 ms), dart2wasm 47.7-48.8 ms
   (stack 48.1-53.4 ms), headless software raster dominating both. A silent wrong-render is the worst failure mode, so
   the bridge layer, not each app, has to own this rule.

Fixes for the template (in order of value):
- return pointer and length together (`fn export_model(out: *Slice) i32`) instead of two calls;
- a monotonically increasing **generation** (bumped on every reallocation of a published buffer; on web additionally
  when `memory.buffer` changes identity) that every view carries; the Dart wrapper re-fetches when it changed
  (the generated web backend in section 4 already tracks `memoryEpoch` by buffer identity);
- pre-size wasm memory for the model (`--initial-memory`/an explicit `memory.grow` after load) so steady-state calls
  never grow it;
- results the UI keeps across calls: copy with `setRange` into Dart-owned buffers you reuse (3.9 us native / 4.4 us
  dart2js for 38k doubles) rather than keeping views.

**2.5 fixed** (zig-flutter stack and the lab generator). Final contract:
- Every buffer-publishing export takes a caller-owned out slice as its last parameter and returns a status:
  `int32_t f2d_disp(uint32_t k, f2d_slice* out)` with `f2d_slice { uintptr_t ptr; size_t len /* elements */;
  uint32_t gen; uint32_t _pad; }` (24 bytes native, 16 on wasm32). Pointer and length come from one call; the
  separate `f2d_out_ptr`, `f2d_error_ptr/len`, `f2d_case_name_ptr/len` exports are gone.
- `uint32_t f2d_generation()` increases whenever a published buffer may have been freed or moved: new model
  (`f2d_load_json`/`f2d_generate`), case buffers reallocated by `f2d_solve`, the export scratch buffer or the echo
  buffer regrown, and on wasm whenever linear memory grew (`@wasmMemorySize` checked on every call that reports a
  generation). The Dart web backend additionally tracks `memory.buffer` identity with `strictEquals` (`identical`
  does not work under dart2wasm, where every property read is a new wrapper).
- The Dart side caches views per buffer and re-fetches them when the generation moved; views never leave the bridge
  class. Geometry is copied once per model into fresh Dart lists; results are copied with `setRange` into a list the
  caller passes back (`displacements(k, into: disp)`), so steady-state solves allocate nothing; strings and JSON
  exports are decoded immediately. `f2d_echo` stays a raw probe (transient view) and now fills its buffer only on
  (re)allocation, so the `boundary` bench's `transfer_us` measures the crossing (SPEC 5.5: "separate from the
  engine's own work"): zig-flutter desktop 7.1 us -> ~0.02 us, web dart2js ~0.5 us / dart2wasm ~1 us (view creation).
- Wasm memory is not pre-sized: with no long-lived views, growth is harmless, so this was not needed.
- Tests: `app/test/bridge_lifetime_test.dart` (native: hold results -> export model + results -> regenerate other
  sizes -> held lists unchanged; fails with the old views) and `app/test_web/` (same scenario through the real
  `engine_web.dart` compiled with dart2js and dart2wasm, run under node, plus a control showing a raw view does
  detach), both in `stack.sh test_all`. Drag p50 unchanged within noise (desktop 13.7 -> 13.3 ms, dart2js
  44.7 -> 38.3, dart2wasm 52.2 -> 46.8, single quick runs on a shared machine).
- Generator (`engine/tools/gen_bindings.zig` in the lab): an export whose last parameter is `*Slice(T)` (an extern
  struct with `pub const bridge_slice_elem = T`) is not exposed raw; the generated `Frame2dRawBase` offers
  `<name>_view(arg)` (generation-checked, transient), `<name>_copy(arg, into:)` (setRange into a reusable list) and,
  for u8 text slices, `<name>_text(arg)`; `generation` is part of the interface. `bridge_meta` gains `slice_c`,
  `generation`, `alloc` (for the one out-slot each backend allocates) and `text`.

### 2.6 Web: dart2js vs dart2wasm, views vs copies

Method: same Dart source (`webbench/web/main.dart`) compiled with `dart compile js -O2` and
`dart compile wasm -O2`, stack engine wasm (ReleaseFast), headless Chromium 156 via Playwright, 4 page loads, each
5 reps; medians (`pw/webbench_runs.txt`).

| per call (38,103 f64 unless noted) | dart2js | dart2wasm |
|---|---:|---:|
| `f2d_noop` | 0.31 ns (V8 inlines the wasm call) | 2.5 ns |
| new `Float64Array` view + `toDart` (typed `@JS` constructor) | 0.07 us | 0.16 us |
| same via `globalContext['Float64Array'].callAsConstructorVarArgs` (stack code) | 0.07 us | 0.42 us |
| read all elements through the view | 15.3 us | 24.5 us |
| read all elements of a Dart `Float64List` | 14.3 us | 14.3 us |
| JS `slice()` then `toDart` (go-zig-flutter / wasm-bindgen style copy) | 91 us | 89 us |
| `Float64List.fromList(view)` | 76 us | 96 us |
| `setRange` into a reused Dart list | 4.4 us | 35 us |
| 50x50 solve inside the wasm engine | 9.24 ms | 9.27 ms |
| fetch + instantiate the 288 KB engine | 6.9 ms | 2.9 ms |

Flutter app (`--bench=boundary`, stack release builds, 3 runs): dart2js noop 1.16 ns / transfer 7.1 us; dart2wasm
3.9 ns / 8.0 us. Like desktop, the transfer number is the engine fill (6.8 us in V8).

- Under dart2wasm, `JSFloat64Array.toDart` is a **wrapper** over the JS view (SDK doc: "wrapped"), not a copy; the
  stack labels it `memcpy`. Element reads cost ~1.7x a Dart list; copying it element-wise (`setRange`, `fromList`)
  is the slow option (35-96 us). So under dart2wasm read through the view; under dart2js views are free.
- Fresh-allocation copies (`slice`, `fromList`, wasm-bindgen's default) cost 75-95 us per 38k doubles, about 1% of a
  solve each, and they allocate 300 KB per call (GC pressure in a 60 fps drag); this is the main web transfer cost in
  go-zig-flutter (45-49 us on win-arm64) and rust-flutter (57-60 us).
- Startup/instantiate of the engine is not a factor (0.3-0.6 ms compile+instantiate in V8 for every variant; 3-7 ms
  including fetch in Chromium).
- Keep the web ABI to i32/u32/f64. A `u64`/`i64` export crosses as a JS BigInt: the first web bench version with an
  `i64` probe failed the Dart `int` cast under dart2js. The generator rejects 64-bit integers at compile time.

### 2.7 Web module size (finding 7)

Lab engine copy, `zig build wasm`, binaryen `wasm-opt` from `machine-env.sh`, brotli q11 in Node, V8 timings in Node
(3 runs, identical within 1%; `wasm/wasmbench.txt`):

| variant | raw bytes | brotli | 50x50 solve |
|---|---:|---:|---:|
| ReleaseFast | 287,718 | 85,929 | 8.85 ms |
| ReleaseFast + `wasm-opt -O3 -all` (**stack release**) | 266,189 | **88,300** | 8.83 ms |
| **ReleaseSmall** | 166,783 | **60,421** | 8.96 ms |
| ReleaseSmall + `wasm-opt -Oz -all` | 149,128 | 59,611 | 8.94 ms |
| ReleaseSafe | 317,615 | 94,969 | 10.17 ms |

`wasm-opt -O3` shrinks the raw module but grows the compressed payload by 2.8%; ReleaseSmall is -30% on the wire for
+1% solve time (the hot loops are the same; only the result fill loop is 46% slower, 9.9 vs 6.8 us). The web engine is
~0.5% of the Flutter web payload (2.3 MB br), so this is cheap hygiene, not a headline.

---

## 3. CI and distribution

### 3.1 Cross-compiling the engine from this Windows x64 host (finding 10)

`bin/xmatrix.sh`: `zig build lib -Doptimize=ReleaseFast -Ddesktop-target=<triple>` (plus a `-Dstatic-lib` option added
in the lab), one run each, warm global cache:

| target | result | time | output |
|---|---|---:|---|
| x86_64-windows-gnu / -msvc, aarch64-windows-gnu | ok | 6.2-7.4 s | 289-403 KB DLL |
| x86_64-linux-gnu, aarch64-linux-gnu | ok | 6.3-6.4 s | 263-305 KB .so |
| x86_64-macos, aarch64-macos | ok (no SDK needed: Zig ships libSystem stubs) | 4.4-6.2 s | ~299 KB .dylib, unsigned |
| aarch64/x86_64/x86-linux-android, arm-linux-androideabi | ok (no NDK needed: the library links no libc) | 6.1-7.4 s | 265-336 KB .so |
| aarch64-ios, aarch64-ios-simulator, x86_64-ios-simulator, static | **fails** in Zig 0.17.0 std (`Io.Threaded` `null_file.fd` on iOS, reached from `solver.nowMs`) | - | - |
| same, with a 6-line `clock_gettime` workaround in `nowMs` | ok | 3.4-3.5 s | ~301-313 KB .a |
| aarch64-ios dynamic | fails: undefined `___error` etc. (needs the iOS SDK's libSystem) | - | - |

Implications:
- one Linux or Windows CI job can build Windows, Linux, Android (all four ABIs) and macOS libraries; Apple **signing,
  notarization, xcframework assembly and iOS dylibs** need a macOS runner with Xcode (`--sysroot` to the SDK).
  Flutter's native-assets iOS path wants a dynamic library (it wraps it into a framework), so iOS needs the SDK in
  practice;
- the engine reads its clock through `std.Io.Threaded`, which pulls a large part of std into a library that only needs
  a timestamp and breaks iOS today. Template rule: the bridge library takes time from the host (the wasm build already
  imports `env.f2d_now_ms`; do the same natively via a function pointer, or use per-OS raw clocks);
- **Android risk (not verified on a device):** the Android .so files carry a PT_TLS segment (4-byte aligned) and
  `DF_STATIC_TLS` (`llvm-objdump -p`), from `std.heap.smp_allocator`'s thread-locals. Bionic only supports ELF TLS from
  API 29 and has alignment rules for it; a `dlopen`ed library with static TLS may be refused. Test on a device before
  relying on it; the safe template choice is an allocator without thread-locals in the bridge library (an arena over
  `page_allocator`, or link NDK libc and use `c_allocator`).

### 3.2 Caching and reproducibility

- Zig: pin the exact version (`minimum_zig_version` is only a floor; CI should fetch a checksummed tarball of 0.17.0).
  Dependency hashes in `build.zig.zon` (`.hash = "N-V-__8AA..."`) already make package fetches reproducible.
  Cache `ZIG_GLOBAL_CACHE_DIR` (key: zig version) - worth ~50 s per job (1.3) - and `p/` (key: zon hash).
- Flutter: pin the SDK by git revision (`737ba8f885` here) and cache `~/.pub-cache` (key: `pubspec.lock`) and
  `bin/cache` (engine artifacts, key: Flutter revision). Commit `pubspec.lock` for apps.
- Hooks: `hooks_runner` caches hook outputs in `.dart_tool/hooks_runner` keyed on the declared dependencies, so a CI
  cache of `.dart_tool` avoids rerunning `zig build` when engine sources did not change (no-op `dart run`: 0.67 s).

### 3.3 One artifact layout for many projects

```
<engine>/                  Zig engine, no Flutter knowledge
  build.zig                steps: lib (-Dtarget, -Dstatic-lib), wasm, bindings, test
  src/bridge/exports.zig   the C ABI + bridge_meta (single source of truth)
packages/<name>_engine/    Dart package, depends on hooks + code_assets
  hook/build.dart          zig build lib for the requested target -> CodeAsset (native)
  lib/src/*.g.dart         generated: raw interface, ffi backend (@Native), web backend (js_interop)
  lib/<name>_engine.dart   openEngine() with conditional import ffi / web
  web/<name>_engine.wasm   staged by `zig build wasm` (hooks do not run for web)
app/                       Flutter app; depends on the package; no CMake or runner edits
dist/<triple>/             CI release artifacts: lib + header + wasm + SHA256SUMS
```

---

## 4. Reusability: a minimal `flutter_zig_bridge` (prototype)

Design: the Zig exports are the only API description. A generator reads them **at comptime** and emits everything the
Dart side needs. Dart gets one raw interface with two backends, and the app's domain wrapper is written once.

```zig
// src/bridge/exports.zig: plain C ABI, marked pub so comptime reflection can see it
pub export fn f2d_solve(mask: u32) i32 { ... }
pub export fn f2d_disp(k: u32) ?[*]const f64 { ... }
pub const bridge_meta = .{
    .prefix = "f2d_",
    .asset = "package:frame2d_engine/frame2d_engine.dart",
    .leaf_unsafe = .{ "f2d_load_json", "f2d_generate", "f2d_solve", "f2d_export_model", "f2d_export_results" },
    .names = .{ .f2d_solve = .{"mask"}, ... }, // Zig reflection has no parameter names
};
```

`zig build bindings` runs `tools/gen_bindings.zig`, which walks `@typeInfo(bridge).@"struct".decl_names`, maps
types (u8..u32, usize, f32/f64, bool, pointers; rejects 64-bit ints for wasm), and writes:
- `frame2d.h` (for C consumers; identical prototypes to the hand-written header),
- `frame2d_raw.g.dart`: `abstract interface class Frame2dRaw` with every export (pointers as `int` addresses) plus
  `f64/i32/u32/u8(addr, n)` view helpers and `memoryEpoch`,
- `frame2d_ffi.g.dart`: `@Native(assetId: ..., isLeaf: ...)` externals and `FfiFrame2dRaw`,
- `frame2d_web.g.dart`: a `dart:js_interop` extension type over the wasm exports and `WebFrame2dRaw`
  (typed `@JS('Float64Array')` constructors, epoch tracking by `memory.buffer` identity).

Prototype result (32 exported functions): `C:\Users\hotschmoe\dev\bridge-lab\engine\tools\gen_bindings.zig`
(298 lines) + the package `C:\Users\hotschmoe\dev\bridge-lab\frame2d_engine` + the app
`C:\Users\hotschmoe\dev\bridge-lab\app_hook`, whose `lib/engine/engine_raw.dart` (151 lines, including the geometry copy of 2.5) replaces
`engine_native.dart` (140), `engine_web.dart` (258) and the 364-line ffigen output, and runs on Windows (debug,
release, `flutter run`), dart2js and dart2wasm. Benches of the prototype app (3 runs each): desktop release boundary
noop 1.50 ns, drag p50 14.3-17.0 ms (stack 14.0-14.8); web dart2js boundary 1.17 ns / 6.9-7.1 us, drag 38.8-41.9 ms;
dart2wasm boundary 4.0 ns / 7.4-8.3 us, drag 47.7-48.8 ms - the same as the hand-written stack within noise. The generator compiles in ~3 s and runs in well
under a second; there is no libclang/ffigen step.

Next steps to make it a real package: generate the domain-level helpers too (functions returning
`(ptr, len)` -> `Float64List` with a generation check; strings in/out), a `shutdown` export for hot swap, the async
worker pattern (`*_async(args, tag, cb)` -> `Future` on native, a Web Worker on web), and a CI matrix job.

---

## Lab layout and how to reproduce

`C:\Users\hotschmoe\dev\bridge-lab\`
- `stacks/zig-flutter/` - untouched copy of the stack (plus `harness/machine-env.sh`, `harness/edits`) for baseline
  builds and benches; `times.log` holds every timed command (label, wall seconds, exit code).
- `engine/` - copy of the Zig sources with: `src/bridge/lab_exports.zig` (probes, worker thread), `lab_solve_async`,
  `pub export` + `bridge_meta` in `exports.zig`, `lib`/`wasm`/`cli`/`bindings` steps and `-Dstatic-lib` in `build.zig`,
  the iOS clock workaround in `solver.zig`, `tools/gen_bindings.zig`.
- `ffibench/` - dart:ffi micro-benchmarks (`bin/bench.dart`, results `aot_run1.txt`, `jit_run1.txt`) and the hot swap
  (`bin/hotswap.dart`).
- `webbench/` - web micro-benchmarks, `pw/run.mjs` (static server on 127.0.0.1:18100 + Playwright), results in
  `pw/webbench_runs.txt`, `pw/flutter_web_bench.txt`.
- `webtest/detach.mjs` (detached-view repro), `webtest/wasmbench.mjs` + `wasm/` (size variants).
- `frame2d_engine/` (hook package), `app_hook/` (app using it).
- `bin/` - `tm` (timer), `uiloop.sh`, `zigdecomp.sh`, `zigrunner.sh`, `xmatrix.sh`, `hotreload_probe.py`;
  `xmatrix.txt`, `xout/` (cross-compiled libraries).

Not done in the time box: Android/iOS device runs of the cross-compiled libraries, `-fincremental`, wiring the hot swap
into the Flutter app, the async solve inside the app's drag bench (the UI-thread saving in 2.4 is an estimate), and the
go-zig-flutter stack's own boundary bench on this machine (its numbers above are the run1 win-arm64 ones).

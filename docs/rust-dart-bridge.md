# Lean Rust <-> Dart (Flutter) bridge: prototype and benchmarks vs flutter_rust_bridge

Scope: a speed-first replacement for flutter_rust_bridge (frb) in `stacks/rust-flutter`, built next to the Zig study
(`docs/zig-dart-bridge.md`) and measured the same way. The lean bridge is plain `extern "C"` exports over the
unchanged Frame2D engine crate, a generated C header, `@Native` Dart bindings bundled by a Flutter build hook, and the
same exports compiled to `wasm32-unknown-unknown` and instantiated directly from Dart through `dart:js_interop` (no
frb runtime, no wasm-bindgen). One macro table drives the header and all Dart bindings.

Machine: win-x64 (Core Ultra 7 270K Plus, 24 cores, Windows 11, Defender on), Rust 1.99.1, Flutter 3.47.8 /
Dart 3.13.7, Zig 0.17.0, binaryen 133, Node 24, Playwright + Chromium 156 headless (SwiftShader). **Other agents were
building on the machine throughout**: every comparison below ran back-to-back (A/B interleaved, 5 reps unless noted,
medians). Treat absolute numbers as indicative (+-10%, builds more); the A/B ratios are the robust part. Nothing under
`stacks/`, `harness/`, `fixtures/` or `SPEC.md` was modified, and nothing of the Zig lab (`engine/`, `app_hook/`,
`frame2d_engine/`) was touched; all work is in `C:\Users\hotschmoe\dev\bridge-lab\rust` (layout at the end).

## Summary: findings ranked by impact

| # | Finding | Measured (lean vs frb unless noted) | Change | Effort |
|---|---|---|---|---|
| 1 | frb's per-call runtime is the dominant boundary cost on desktop; plain `@Native` leaf calls remove it | desktop app `boundary`: noop **197 ns -> 1.50 ns** (131x), 38k-double transfer **219 us -> 15.3 us** (14x) | `extern "C"` + `@Native(isLeaf)`; results returned as (ptr, len) and copied with `setRange` into reused Dart lists | M |
| 2 | Desktop drag gets faster and loses its lag although the solve is identical | drag p50 **24.5 -> 18.8 ms**, lag_max **2 -> 0** frames, same solve_p50 (10.9 / 10.8 ms) | Synchronous leaf call on the UI isolate for <~15 ms solves; frb's async port hop costs a vsync slot | M |
| 3 | dart2wasm copies must happen on the JS side | 38k doubles: Dart `setRange` from a JS view 39 us -> JS `TypedArray.set` into a reused JS-owned array **3.95 us**; app `boundary` dart2wasm transfer **104 (frb) / 44.6 -> 15.3 us** | Generated web backend copies with `set` into a pool of JS-backed lists | S |
| 4 | Release profile: only `opt-level` matters; LTO / codegen-units buy nothing for this cdylib; `panic=abort` saves 20% DLL with no speed change | solve 50x50: o3 10.6 ms, o2 14.3, s 21.8, z 30.9; fat/thin/no LTO 10.6/10.6/10.6; DLL 513 KB -> 408 KB with abort; `target-cpu=x86-64-v3` **9.3 ms (-12%)** | `opt-level=3`, `lto=false` or thin (2.3 s faster builds), keep unwind natively (see 6), ship an x86-64-v3 build where the install base allows | S |
| 5 | Memory-safe contract costs ~nothing | generation check + cached view 11 ns; copying all 8 result arrays (125k f64) into the reused pool 10.8 us/solve (0.1% of a solve) vs 165 us into fresh lists | (ptr, len) together, generation counter, epoch on `memory.buffer`, copy-into-pool | S |
| 6 | `catch_unwind` at every export is free natively; on wasm a panic is a trap that can wedge the instance | guarded noop 1.476 vs raw 1.466 ns; panic -> rc -99 + message in 4.2 us, engine usable after; wasm: `RuntimeError: unreachable`, and a panic inside the state lock leaves every later call `ERR_BUSY` | unwind + catch natively; on web treat any trap as fatal and re-instantiate the module | S |
| 7 | The process-global engine needs a lock; `Mutex::try_lock` is the main per-call overhead left | +8.5 ns per stateful call (noop 1.48 -> 9.96 ns) | Fine at 60 fps; a single atomic busy flag would cut it if a hot getter ever matters | S |
| 8 | Off-UI solving is cheap either way, but does not shorten the awaited frame | engine worker + `NativeCallable.listener` round trip 2.7-4.5 us (Zig lab worker 10.2 us), helper isolate 2.1 us; drag with worker p50 22.6 ms vs sync 18.8 ms | Keep sync for the drag loop; use the worker (it returns `ERR_BUSY` to racing UI calls) for 100x100+ models | M |
| 9 | One macro table can generate the C header and every Dart file; no cbindgen, syn, proc-macro or libclang | generator 259 lines, runs in 0.07 s warm (1.3 s incl. compile) vs frb codegen 3.4 s warm (28.8 s first run); 3 generated Dart files (397 lines) replace 1,289 lines of frb Dart + 682 lines of wasm-bindgen JS | Rows are language-neutral: the same Dart backend can serve Zig (comptime) and Go (cgo export scan) | M |
| 10 | Web drag and engine time are the same for both bridges (raster-bound), and the wasm is the same size | dart2js drag p50 30.2 vs 30.1 ms, dart2wasm 16.9 vs 16.9 ms; wasm 85.6 KB br vs frb 83.4 KB + 3.4 KB JS glue | Use plain `release` + optional `wasm-opt -O3` (-1%); `opt-level=s/z` is 2.7-3.8x slower for -14-18% | S |

The Zig comparison in one line: the crossing itself is identical (1.47 ns for both DLLs in the same Dart binary); the
Rust engine solves 50x50 natively in 10.5 ms vs 7.8 ms for the Zig engine (engine, not bridge: factorization is 70%
of it), and both engines are equal in wasm (9.2 ms in Chromium, 8.9 / 8.8 ms in Node).

## Lean vs frb vs Zig

All rows measured on this machine in this session. "lean" and "frb" share the identical Flutter UI (the rust-flutter
app, only the engine layer swapped); the Zig numbers come from the Zig lab DLL/wasm through the same benches, and Zig
app numbers are from `docs/zig-dart-bridge.md` (different UI, so only indicative).

| metric | lean (this work) | frb (rust-flutter stack, rebuilt here) | Zig bridge (lab) |
|---|---:|---:|---:|
| desktop app `boundary` noop | **1.50 ns** | 197 ns (sync SSE call) | 1.50 ns (zig doc) |
| desktop app `boundary` transfer, 38,103 f64 incl. engine fill | **15.3 us** (fill 10.9 + copy 3.6) | 219 us (serialize + copy) | 7.1 us (fill, view only) |
| desktop app `drag` p50 / p95 / lag_max | **18.8 / 25.2 ms / 0** | 24.5 / 26.0 ms / 2 | 14.1 ms (zig-flutter UI) |
| engine solve 50x50 native (ffibench, same Dart binary) | 10.5 ms | 10.9 ms (app solve_p50) | **7.8 ms** |
| `@Native` leaf noop / add(i64,i64) (ffibench) | 1.47 / 2.02 ns | n/a | 1.47 / 2.02 ns |
| zero-copy view call + `asTypedList` | 12.2 ns (with lock) | n/a (always copies) | **4.9 ns** (no lock) |
| web dart2js `boundary` noop / transfer | **1.67 ns / 14.6 us** | 1.99 ns / 106 us | 1.16 ns / 7.1 us (zig doc) |
| web dart2wasm `boundary` noop / transfer | **6.2 ns / 15.3 us** | 14.3 ns / 104 us | 3.9 ns / 8.0 us (zig doc) |
| web drag p50 dart2js / dart2wasm | 30.1 / 16.9 ms | 30.2 / 16.9 ms | 38-42 / 48 ms (zig doc, other UI) |
| wasm solve 50x50 (Chromium, webbench) | 9.18 ms | (same engine) | 9.27 ms |
| engine wasm, brotli | 85.6 KB (84.7 with wasm-opt) | 83.4 KB + 3.4 KB JS glue | 85.9 KB (stack), 60 KB ReleaseSmall |
| desktop engine DLL | 513 KB (408 KB panic=abort) | 745 KB | 289-403 KB |
| cold Rust/Zig engine lib build (release, deps downloaded) | **7.05 s** | 8.54 s | 5.3 s warm runner, 60 s fully cold |
| engine leaf edit -> lib rebuilt (release / dev) | 4.16 / 0.86 s | 4.55 / 1.01 s | 5.3 / 2.0 s |
| cold desktop release app (cargo clean + flutter clean) | 26.1 s | 33.5 s | 100 s (zig-flutter buildloop) |
| hand-written glue for this app (excl. reusable bridge kit) | ~690 lines | 708 lines | 151 lines (generated raw + app wrapper) |
| generated code | 476 lines | 2,721 lines (incl. 682 lines wasm-bindgen JS) | 4 files |
| toolchain extras | none (no cbindgen/libclang) | frb codegen 2.13.0, wasm-bindgen-cli 0.2.129 (pinned pair) | ffigen + libclang (stack) / none (generator) |

---

## 1. Design

### 1.1 The ABI contract (`rust/lean/src/lib.rs`, `state.rs`)

- Every export is `extern "C"` with only `u8/i32/u32/f64/usize` (and one `*mut F2dSlice` out-pointer). 64-bit integers
  are rejected by the generator for anything that reaches the web (a wasm `i64` is a JS BigInt).
- Results live in engine-owned `Vec`s listed in a `buffers!` table (26 ids). `f2d_buf(id, *mut F2dSlice)` returns
  pointer **and** length in one call (the Zig report's `out_ptr`/`export` ordering trap cannot be written).
- `f2d_generation()` is bumped whenever any published (ptr, len) pair changes. Results are rewritten in place
  (`clear` + `extend`), so a drag loop keeps the same pointers and the generation stays put (verified: stable across
  `f2d_move_and_solve`); a new model gets fresh `Vec`s, so its views can never alias the previous model's.
- The Dart layer (`LeanBuffers`, hand-written, generic) caches views per (generation, memory epoch) and drops them when
  either changes. The web backend bumps the epoch when `memory.buffer.byteLength` changes (a grow is the only way the
  buffer is replaced). Anything the app keeps is copied into Dart-owned lists: model arrays once per model, result
  arrays into a two-slot pool, so a `SolveData` the UI holds stays valid for one more solve and a drag allocates
  nothing.
- Every export returns an `i32` status (`OK`, `ERR_MODEL`, `ERR_NO_MODEL`, `ERR_BUSY`, `ERR_BAD_ARG`, `ERR_PANIC`) and
  leaves `code|detail` in `Buf::Error`; `LeanBuffers.check(rc)` turns it into a typed `LeanError(code, detail)`, which
  the app maps 1:1 to its existing `EngineError` (all SPEC 4.6 codes survive, verified with `bin/smoke.dart`:
  `invalid_ref`, `bad_json`, panic).
- Threading: the engine state is a `static Mutex<Option<State>>` that exports only `try_lock`; a call racing the worker
  thread gets `ERR_BUSY` instead of a data race; a poisoned lock (panic while held) resets the state. Rust does not let
  you write the unsynchronized globals the Zig exports use, which is a real advantage here: the helper-isolate and
  worker designs are safe by construction.

### 1.2 Header: generated from the export table, not cbindgen or hand-written

cbindgen is not installed (installing it is a toolchain change) and would be a second parser of the same source.
The `exports!` macro (macro_rules, 30 lines in `abi.rs`) emits each `#[no_mangle] extern "C" fn` wrapped in the panic
guard and a `const EXPORTS: &[FnMeta]` row (name, kind `leaf|slow|raw`, doc, `(arg, type)` strings, return type).
`gen_bindings` (a bin in the same crate) links the rlib, reads the rows and writes `include/frame2d_lean.h` (91 lines,
with the error codes and the buffer enum) plus the Dart files. Unsupported types fail the generator with a message.
No proc-macro, no `syn`, no libclang; `cargo run -p f2d-lean --bin gen_bindings` takes 0.07 s warm (1.3 s when the bin needs recompiling); frb codegen takes 3.4 s warm, 28.8 s on first run.

### 1.3 Panic strategy

- Native: `panic = "unwind"` + `catch_unwind(AssertUnwindSafe(..))` in every export. Cost: none measurable (guarded
  noop 1.476 ns vs unguarded 1.466 ns, AOT). A panic returns `ERR_PANIC`, its message is in `Buf::Error`
  (`panic|lab_panic: lab_panic called`), the state is reset, and the next call works (smoke test). Full round trip
  of a panicking call incl. the default hook's stderr print: 4.2 us. `panic=abort` would save 105 KB of DLL (-20%) at
  equal speed, but turns any engine bug into a process kill; not worth it for a UI app.
- Web: `wasm32-unknown-unknown` is abort-only on stable (no unwinding without `-Zbuild-std`), so the guard compiles to
  nothing and a panic is a `RuntimeError: unreachable` thrown into Dart. Measured in Node (`webtest_panic.mjs`): a
  panic outside the lock leaves the instance usable; **a panic while holding the state lock wedges it** (the lock is
  never released, every later call returns `ERR_BUSY`). Rule for the web backend: treat any JS exception from an export
  as fatal for that instance, drop it and re-instantiate (the module bytes are already fetched; instantiate is 0.3-0.5 ms).
  `release` and `r-abort` wasm are byte-identical, confirming there is nothing to tune there.

---

## 2. Runtime

### 2.1 Call overhead (desktop, AOT)

`dart/frame2d_lean/bin/leanbench.dart` through the generated `@Native` bindings (built with `dart build cli`, so the
hook bundles the DLL exactly as in the app), 5 reps, median (`leanbench_aot.txt`); `ffibench` (the Zig lab's binary,
unchanged) run alternately against the Zig lab DLL and the lean DLL, 5 alternations (`ffibench_ab.txt`):

| call | lean | Zig lab DLL |
|---|---:|---:|
| `@Native` leaf noop (ffibench) | 1.47 ns | 1.47 ns |
| non-leaf noop | 12.6 ns | 12.6 ns |
| `add(i64, i64)` leaf `@Native` / lookup | 2.02 / 2.41 ns | 2.02 / 2.41 ns |
| noop without `catch_unwind` / with | 1.466 / 1.476 ns | - |
| noop with guard + state `try_lock` | 9.96 ns | - |
| `f2d_buf(id, out*)` + read slice | 11.6 ns | - |
| `LeanBuffers.f64(buf)` (generation check + cached view) | 11.0 ns | - |
| stats: struct by value / out-pointer / pointer + `asTypedList(6)` | 6.4 / 2.4 / 11.0 ns | 6.2 / 2.5 / 3.4 ns |
| frb sync noop (app `boundary`) | 197 ns | - |

- The crossing is the same machine code for both languages; Rust adds nothing until you touch state. The lock is the
  only real per-call cost (8.5 ns); it buys freedom from data races, which no 60 fps path will notice.
- frb's 197 ns sync call (SSE: encode args into a buffer, call, decode a result buffer, plus its handler) is 130x a leaf
  call; frb's default *async* calls add a port round trip on top. On win-arm64 under x64 emulation the stack measured
  467 ns.
- `isLeaf`: the generator emits leaf for `leaf` exports and non-leaf for `slow` ones (generate/load/export/solve), as
  the Zig report recommends; the 11 ns difference is irrelevant next to a 10 ms solve, and long calls must not block
  the isolate's safepoints.
- Struct-by-value vs out-pointer: same result as Zig (6.4 vs 2.4 ns); the lean ABI only uses out-pointers.

### 2.2 Bulk transfer

Native (AOT, 38,103 f64 unless noted):

| mechanism | time |
|---|---:|
| frb sync `Vec<f64>` return (app `boundary`, incl. fill) | 219 us |
| lean `boundary`: engine fill + view + `setRange` into a reused list | 15.3 us |
| engine fill alone (`lab_fill`; Rust's `k as f64` loop, Zig 7.0 us) | 10.8 us |
| view + `setRange` into a reused Dart list | 3.6 us |
| view + `Float64List.fromList` | 106 us |
| all 8 result arrays of a 50x50 solve (125k f64): views only | 0.09 us |
| ... copied into the reused 2-slot pool | **10.8 us** |
| ... copied into fresh lists | 165 us |

Web (webbench, same Dart source for both engines, 5 page loads per cell, interleaved; `webbench_ab.txt`):

| per call (38,103 f64) | dart2js rust / zig | dart2wasm rust / zig |
|---|---:|---:|
| `f2d_noop` | 2.0 / 0.32 ns | 2.48 / 2.48 ns |
| new view (typed `@JS` ctor) + `toDart` | 0.06 / 0.05 us | 0.17 / 0.16 us |
| JS `slice()` + `toDart` (wasm-bindgen style) | 95 / 95 us | 90 / 91 us |
| `Float64List.fromList(view)` | 78 / 78 us | 64 / 71 us |
| `setRange` into a reused Dart list | 4.45 / 4.45 us | **39 / 35 us** |
| **JS `set` into a reused JS-owned array, then `toDart`** | 3.86 / 3.85 us | **3.95 / 3.95 us** |
| read all elements: Dart list / JS-backed list | 20.1 (14.4) / 30.5 us | 14.2 / 27.7 us |
| 50x50 solve in the wasm engine | 9.18 / 9.27 ms | 9.18 / 9.24 ms |

- New finding vs the Zig report: under dart2wasm the right copy is `TypedArray.set` on the JS side into a JS-backed
  list you reuse (`reuse.toJS` unwraps without copying). It is 10x faster than `setRange` and the result is a normal
  `Float64List` for Dart (reads are ~2x a Dart-heap list, so copy + one full read is still 31.7 vs 53 us). The
  generated `WebLeanRaw.copyF64` does this; it took the dart2wasm app `boundary` transfer from 44.6 to 15.3 us.
- Rust's noop under dart2js is 2.0 ns vs Zig's 0.32 ns: V8 inlines the empty Zig export; the Rust one is not
  inlined, probably because of the guard's landing pad. Irrelevant in absolute terms.

### 2.3 End-to-end: 50x50 solve and the drag loop

Desktop release apps, `--bench=boundary` and `--bench=drag`, interleaved frb / lean / lean+worker, 5 runs each
(`ab_boundary.txt`, `ab_drag.txt`):

| | frb | lean (sync) | lean (worker + listener, `F2D_LEAN_ASYNC=1`) |
|---|---:|---:|---:|
| drag p50 | 24.5 ms | **18.8 ms** | 22.6 ms |
| drag p95 / p99 | 26.0 / 26.7 ms | 25.2 / 26.4 ms | 25.6 / 26.9 ms |
| drag max | 27.7 ms | 49.1 ms | 57.1 ms |
| solve_p50 (engine) | 10.9 ms | 10.8 ms | 10.9 ms |
| lag_max | 2 | **0** | 2 |
| RSS | 164 MB | 161 MB | 151 MB |

The engine work is identical, so the 5.7 ms p50 gain is the bridge: frb runs the solve on its thread pool and delivers
the result through a Dart port, an extra event-loop turn that often misses the next vsync (frames quantize to the
display), and the result lands 2 frames late. The lean sync call returns in the same task. The lean max (49-57 ms) is
a single slow frame per run (cause not investigated); p95/p99 are unchanged.

Web release builds in headless Chromium (SwiftShader), interleaved, 5 runs (`ab_web_v1.txt`, `ab_web_v2_boundary.txt`):

| | frb dart2js | lean dart2js | frb dart2wasm | lean dart2wasm |
|---|---:|---:|---:|---:|
| `boundary` noop | 1.99 ns | 1.67 ns | 14.3 ns | 6.2 ns |
| `boundary` transfer | 106 us | **14.6 us** | 104 us | **15.3 us** |
| drag p50 / p99 | 30.2 / 37.0 ms | 30.1 / 35.8 ms | 16.9 / 20.8 ms | 16.9 / 20.8 ms |
| drag solve_p50 | 9.41 ms | 9.42 ms | 9.72 ms | 9.75 ms |

On the web the frame is raster-bound (software rendering) and both bridges call the wasm synchronously, so drag is a
tie; the transfer win (7x) is real but 0.1 ms per frame.

### 2.4 Off the UI isolate

| mechanism (AOT) | lean | Zig lab |
|---|---:|---:|
| engine worker thread + `NativeCallable.listener`, no work | 2.7 us (ffibench) / 4.5 us (leanbench, via `f2d_move_and_solve_async`) | 10.2 us |
| thread per call + listener | 46.6 us | 65.9 us |
| helper isolate `SendPort` round trip | 2.1 us | 2.2 us |
| `Isolate.run` per call | 24.4 us | 24.1 us |
| 50x50 move+solve on worker + listener + copy results | 10.8 ms (sync 10.5) | - |
| 50x50 move+solve in helper isolate + `TransferableTypedData` disp back | 10.5 ms | - |

The worker exports (`f2d_solve_async`, `f2d_move_and_solve_async`, `f2d_busy`) are native-only; the generated web
backend throws `UnsupportedError` for them. Because the state is behind `try_lock`, a UI call during a worker solve
gets `ERR_BUSY` (safe), and the Dart wrapper copies results only after the callback. In the drag bench the worker does
not help (the bench awaits each result; p50 22.6 vs 18.8 ms sync) but frees the UI isolate, which matters once solves
exceed a frame (100x100+). Rust's std `Condvar` worker round trip (2.7 us) is ~4x faster than the Zig lab's futex one.

### 2.5 Release profile tuning (desktop DLL)

`bin/sweep_build.sh` builds every variant (lean + engine rebuilt, deps cached), `profbench.exe` loads all DLLs in one
process and interleaves them for 5 rounds (`sweep_bench.txt`):

| profile | DLL bytes | build (lean+engine) | noop | solve 50x50 | move+solve |
|---|---:|---:|---:|---:|---:|
| `release` (o3, fat LTO, cgu=1, unwind) | 512,512 | 6.9 s | 1.31 ns | 10.60 ms | 10.53 ms |
| thin LTO, cgu=16 | 536,576 | 4.7 s | 1.31 ns | 10.59 ms | 10.60 ms |
| no LTO, cgu=16 | 536,576 | 4.6 s | 1.30 ns | 10.58 ms | 10.37 ms |
| `panic = "abort"` | **407,552** | 6.7 s | 1.30 ns | 10.46 ms | 10.55 ms |
| opt-level 2 | 503,808 | 6.8 s | 1.31 ns | 14.33 ms | 14.24 ms |
| opt-level s | 474,112 | 5.4 s | 1.31 ns | 21.81 ms | 21.90 ms |
| opt-level z | 437,248 | 4.9 s | 1.31 ns | 30.90 ms | 31.10 ms |
| release + `-C target-cpu=x86-64-v3` | 519,680 | 6.9 s | 1.30 ns | **9.32 ms** | 9.34 ms |

- The engine is one crate with no hot dependencies, so cross-crate LTO has nothing to inline: use thin or no LTO and
  `codegen-units=16` for 2.3 s faster release builds (the hook's rebuild after an edit) at equal speed.
- opt-level is everything (o2 is already +35%); never ship `s`/`z` natively.
- `x86-64-v3` (AVX2/FMA, every x64 desktop CPU since ~2015) is -12% on the solve; legitimate for a desktop app with a
  runtime fallback or a minimum-CPU statement, not for the default artifact. `target-cpu=native` is never legit for
  distribution.
- `strip = true` is already on (the frb stack's 745 KB DLL is also stripped; the difference is frb's runtime and its
  dependencies).

### 2.6 Web module size

`bin/build_wasm.sh` (`+simd128`, as the frb stack), binaryen 133, brotli q11, Node/V8, 5 runs (`wasm_variants_5.jsonl`):

| variant | raw | brotli | solve 50x50 | compile+instantiate |
|---|---:|---:|---:|---:|
| `release` (o3) | 284,427 | 85,635 | 8.90 ms | 0.47 ms |
| `release` + `wasm-opt -O3` | 255,263 | **84,676** | 8.94 ms | 0.37 ms |
| `r-s` (opt-level s) | 267,318 | 74,021 | 24.7 ms | 0.40 ms |
| `r-z` + `wasm-opt -Oz` | 201,688 | 69,791 | 34.3 ms | 0.41 ms |
| frb stack (wasm-bindgen + `wasm-opt -O3`) | 255,408 + 29,624 JS | 83,444 + 3,410 | (same engine) | - |
| Zig stack release (ReleaseFast + wasm-opt) | 287,718 | 85,929 | 8.81 ms | 0.36 ms |

Unlike Zig (ReleaseSmall cost 1%), Rust's size levels cost 2.8-3.8x in the solver for 14-18% fewer bytes. The engine
is ~0.5% of the Flutter web payload; use `release` (+ `wasm-opt -O3`, -1%). wasm-bindgen's JS glue (3.4 KB br) is
gone.

---

## 3. Dev loop and CI

| step (Windows x64, release Rust unless noted) | lean | frb |
|---|---:|---:|
| cold engine lib build (`cargo clean`, registry cached), 5 runs | 7.05 s | 8.54 s |
| leaf edit (`BENCH-EDIT:leaf`) -> lib, release / dev profile, 5 runs | 4.16 / 0.86 s | 4.55 / 1.01 s |
| regenerate bindings after an API change, 3 runs | 0.07 s (`gen_bindings`; 1.3 s cold) | 3.4 s (`flutter_rust_bridge_codegen generate`; 28.8 s first) |
| leaf edit -> `flutter build windows --debug` (hook runs cargo), 3 runs | 9.6 s | stack: dev lib 1.0 s + DLL copy (Flutter skipped) |
| no-op `flutter build windows --debug` with the hook | 5.0 s | 0.4 s (stack.sh stamps skip Flutter) |
| cold desktop release app (cargo clean + flutter clean), 2 runs | 26.1 s (26.7 / 25.5) | 33.5 s (33.7 / 33.3) |
| first web release build, dart2js + dart2wasm | 14.1 + 22.1 s (+ wasm 1-7 s) | 47.7 s (incl. wasm-bindgen + wasm-opt) |
| hot reload / hot restart with the engine loaded, 5 runs (`flutter run` launch 17.6 s) | 0.22 / 0.26 s | not measured (same Flutter mechanism; frb re-inits its handler on restart) |
| engine DLL hot swap (snapshot 1.2 MB JSON, close, open new copy, load, solve 50x50), 5x6 swaps | 41.8 ms, RSS flat at 45 MB | not supported (frb binds its library once) |

Notes:
- The hook is the single source of truth for packaging: no CMake install rule (the stack's `F2D_BRIDGE_DLL` block and
  its "build through stack.sh" error are gone), no `DynamicLibrary.open` path logic, same per-ABI behaviour for
  Android/iOS/macOS/Linux. It has no debug/release input, so it builds `release` (Debug Rust would be ~10x slower in the
  solver); `F2D_PROFILE=dev` overrides it. Web builds do not run code-asset hooks, so `bin/build_wasm.sh` stages the
  wasm into `web/`.
- frb ties the Dart package, the codegen binary and (for the stack's web path) wasm-bindgen-cli to exact versions;
  the lean bridge has no generator binary to pin beyond the crate itself.
- Hot reload and restart keep the DLL loaded (as in the Zig report); the engine's process state survives a hot
  restart, and `init()` re-queries it. The hot swap needs `DynamicLibrary` lookups instead of `@Native` (which binds
  to the asset for the process lifetime), so it stays a debug-only backend; the lean ABI makes it safe because the
  snapshot is read with `f2d_buf(Out)` (pointer and length together).

---

## 4. Developer experience

**What you hand-write.** Per app: the engine state and its result flattening (`state.rs`, 378 lines, the equivalent of
frb's `api.rs` 325), one `exports!` block (~150 lines incl. doc comments), and the domain wrapper that turns buffers
into the app's model types (`engine_lean.dart` 127 + async 33). That is ~690 lines vs frb's 708 hand-written lines for
the same app (`api.rs` + `web.rs` + `engine_native.dart` + `engine_web.dart`). Once per project ("bridge kit", reusable
as is): `abi.rs` 131, `gen_bindings.rs` 259, `buffers.dart` 101, `hook/build.dart` 68, open helpers 17. Generated:
476 lines (header 91, raw 121, ffi 125, web 170) vs frb's 2,721 (incl. 682 lines of wasm-bindgen JS).

**What frb gives you that lean does not:** structs, `Vec<String>`, `Result<T, String>` and async as first-class
types; you write `pub fn engine_solve(...) -> Result<SolveView, String>` and get a `Future<SolveView>` in Dart.
In the lean bridge the API shape is buffers + status codes and the Dart wrapper maps buffers to fields by hand (the
`Buf` enum is generated, the mapping is not). For a numeric engine that publishes flat arrays this is the natural
shape anyway; for an API with many small structured calls frb's ergonomics are worth more than its 200 ns.

**Error handling.** Equal in power, different in shape: frb maps `Err(String)` to a thrown Dart exception
automatically; lean returns a code and keeps the message in a buffer, and `LeanBuffers.check(rc)` throws a typed
`LeanError(code, detail)` (one line per call site in the wrapper). Panics: frb catches them too (as an exception);
lean returns `ERR_PANIC` with the message and resets the state.

**One Dart backend for Zig, Rust and Go.** The generator's input is a list of rows
`(name, kind, [(arg, type)], ret)` plus buffer rows `(name, elem)`, with types restricted to
`u8 i32 u32 f64 usize ptr callback`. Every engine language can emit those rows from its own source of truth:
Rust from the `exports!` table (this prototype), Zig from `@typeInfo` at comptime (the Zig lab's `gen_bindings.zig`
already walks the same information), Go from `//export` comments or a small table compiled into a `cmd/gen`.
The Dart side (`lean_raw.g.dart` / `lean_ffi.g.dart` / `lean_web.g.dart` + `buffers.dart`) does not know which
language produced the library. The sensible split is: rows -> JSON (`bridge.json`), one Dart generator that reads it
(a `dart run bridge_gen` tool or a build hook), and a 50-100 line row emitter per engine language. The prototype
keeps the emitter and the Dart writer in one Rust bin for brevity.

---

## 5. Recommended template

```
<engine crate>/            pure Rust, no bridge knowledge
<bridge crate>/            cdylib + rlib
  src/abi.rs               F2dSlice, guard (catch_unwind), exports!/buffers! macros  (copy as is)
  src/state.rs             Mutex<Option<State>> + try_lock, published Vecs, generation  (per app)
  src/lib.rs               exports! { leaf fn ...; slow fn ... }  buffers! { ... }  (per app)
  src/bin/gen_bindings.rs  rows -> C header + Dart raw/ffi/web  (copy as is)
packages/<name>/           Dart package: hooks + code_assets only
  hook/build.dart          cargo build --release --target <triple> -> CodeAsset(DynamicLoadingBundled)
  lib/src/*.g.dart         generated; lib/src/buffers.dart (generation-checked views, copy-into-pool, check(rc))
web/<name>.wasm            bin/build_wasm.sh (release, +simd128, optional wasm-opt -O3)
```

Rules: leaf by default, `slow` (non-leaf) for anything >~10 us; never return a pointer without its length; bump the
generation on any reallocation; copy what the UI keeps (`setRange` natively, JS `set` on web) into reused lists;
`opt-level=3`, `lto=false`/thin, `codegen-units=16`, `panic=unwind` natively (abort is implicit on wasm: re-instantiate
after a trap); sync calls for per-frame work under a frame, the worker export for longer solves.

---

## Lab layout and how to reproduce

`C:\Users\hotschmoe\dev\bridge-lab\rust\` (`source bin/lib.sh` first; it sources `harness/machine-env.sh`)
- `Cargo.toml` (workspace + profile variants), `engine/` (copy of `stacks/rust-flutter/crates/engine`), `lean/` (bridge
  crate: `abi.rs`, `state.rs`, `lib.rs`, `worker.rs`, `bin/gen_bindings.rs`, `include/frame2d_lean.h`).
- `dart/frame2d_lean/` (Dart package: hook, generated bindings, `buffers.dart`, `bin/smoke.dart`, `bin/leanbench.dart`).
  Regenerate: `cargo run -p f2d-lean --bin gen_bindings -- dart/frame2d_lean lean/include/frame2d_lean.h`.
  Smoke: `cd dart/frame2d_lean && dart run bin/smoke.dart`. AOT bench: `dart build cli -t bin/leanbench.dart -o ../../leanbench_out`.
- `app_lean/` (the rust-flutter app with only `lib/engine/` swapped; `flutter build windows --release`; web:
  `bin/build_wasm.sh release` then `flutter build web --release [--wasm]`). `F2D_LEAN_ASYNC=1` selects the worker path.
- `frb_stack/` (copy of `stacks/rust-flutter` built through its own `stack.sh`).
- `bin/ab_desktop.sh <mode> <reps>`, `bin/ab_web.sh <reps> <modes>` (uses `../pw/rust_run.mjs`, port 18107),
  `bin/sweep_build.sh` + `profbench/profbench.exe`, `bin/devloop.sh`, `bin/devloop2.sh`, `bin/med.py` (medians).
- Results: `ab_boundary.txt`, `ab_drag.txt`, `ab_web_v1.txt`, `ab_web_v2_boundary.txt`, `leanbench_aot.txt`,
  `ffibench_ab.txt` (`../ffibench/bench.exe` vs `../ffibench/engine_src.dll`), `webbench_ab.txt` (`webbench/`),
  `sweep_bench.txt`, `wasm_variants_5.jsonl`, `webtest_panic.mjs`, `times.log` (every timed build).

Not done in the time box: Android/iOS builds of the hook (the triple map is there), a JSON row format shared with the
Zig generator, re-instantiate-on-trap in the generated web backend (measured, not implemented), the 100x100+ drag with
the worker, and an atomic busy flag instead of the mutex.

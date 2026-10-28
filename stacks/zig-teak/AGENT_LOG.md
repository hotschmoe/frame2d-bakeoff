# AGENT_LOG: zig-teak, phase P1

Run id: run1p5   Machine: win-x64   Agent model: claude-opus-5-5   Started: 2026-10-27

Stack: Zig 0.17.0, Teak 9b16f1065daa65ff7cc823c76db0d9275f53bcc3 (v0.1.0, pinned by URL + hash in build.zig.zon),
zunk 0.16.0 (pinned by Teak), wgpu-native v29.0.1.1 (lazy Teak dep), SQLite 3.46.1 amalgamation (compiled by zig cc),
server on std.http + std.Io.net (one thread per connection). No Emscripten.

Machine note: two other agents were building/profiling on this machine at the same time, so all timings here are indicative only (SPEC 2.10).

## Toolchain surprises / problems over ~10 minutes

### Zig 0.17 std churn (stale_api, many small hits, ~15 min total)
- Time lost: ~15 min, spread over many builds
- Category: stale_api
- What happened: `std.time` is gone (clocks are `std.Io.Clock.awake.now(io)`), `main` takes `std.process.Init` for io/args/env,
  `Allocator.dupeZ` became `dupeSentinel`, optimize modes are lowercase (`.debug`), `**` array repetition is removed (`@splat`),
  `std.meta.fields` is gone (`@typeInfo(E).@"enum".field_names`), `@enumFromInt` is `@fromBackingInt`, `CanvasEventKind` gained `.key`.
  Networking is `std.Io.net.IpAddress.listen` + `Stream.reader/writer(io, buf).interface` into `std.http.Server.init`.
- What fixed it: reading the pinned std sources (`lib/std/Io.zig`, `Io/net.zig`, `http/Server.zig`) and Teak's `docs/migration-0.17.md`.

### Generator member count (wrong_result, ~5 min)
- Category: wrong_result. I first generated beams at level 0 as well (220 members for 10x10). Conformance golden caught it; SPEC 4.8's table (210) is right.

### Harness environment: python / numpy / Playwright (build_config, ~10 min)
- `harness/server_conformance.sh` does not source `machine-env.sh`, so a bare `python` resolves to Python 3.11. Run it from a shell that
  has sourced `harness/machine-env.sh` (Python 3.12). Python 3.12 had no numpy, which `harness/reference/ref.py` needs, so I ran
  `python -m pip install numpy` (outside the stack).
- Playwright was not installed at the default `~/dev/tools/playwright`. I installed `playwright@1.64.1` there, plus its Chromium
  (outside the stack), to run `harness/bench_web.mjs`.

## Teak-caused time (excluded from agent-handling numbers, SPEC 15.6)

- ~10 min: reading Teak/zunk docs and source to wire bench timing (own loop around `teak.Runtime`) and the web entry.
- ~10 min: web bridge. `linkWebWgpu` has no option for an app JS file, so `js/bridge.js` has to sit at the build root. Filed
  hotschmoe/teak#136. Workaround: `stacks/zig-teak/js/bridge.js` (counted as glue, but it is outside the `web/` LOC bucket).
- Comments (no new issues needed, Teak master already covers them): #125 (canvas: `lines` batches are enough), #126 (DataTable
  covers the member table), #127 (`Runtime` + `idle_skip=false` is enough for frame timing).

## Deviations (Emscripten, UI fallback, extra dependency, spec question)

- Desktop `--bench=boundary`: a pure-Zig desktop app has no language boundary. The mode still prints a BENCH line: an in-process
  noinline call (`noop_ns`) and filling and returning a 38,103-f64 slice by reference (`transfer_us`), with
  `mechanism = "none (pure Zig, in-process call...)"`.
- Web `?bench=boundary`: real JS->wasm crossing. `js/bridge.js` calls the exports `f2d_noop` / `f2d_echo(n)` and reads the result
  through a `Float64Array` view over wasm memory (zero copy).
- `lag_max` is always 0: the solve runs synchronously on the UI thread inside `update`, so each frame shows its own result.
- Desktop `rss_mb` = Windows working set (K32GetProcessMemoryInfo). Web `rss_mb` = wasm linear memory size (the closest the page can report).
- Drag bench: each frame re-solves only case D (`Options.only_case`); the interactive drag re-solves all cases.

- **Web needs extra Chromium flags (harness setting; I did not edit the harness).** Teak's web path is WebGPU-only (Teak's
  `docs/features/web-fallback.md`: the WebGL2 backend is deferred). With the harness default launch args
  (`--ignore-gpu-blocklist --enable-unsafe-swiftshader`), Playwright's headless Chromium on win-x64 reports "No WebGPU adapter",
  and `--enable-unsafe-webgpu` alone does not change that. `--enable-gpu` finds the hardware adapter, but `requestDevice` then fails:
  `DynamicLib.Open: dxcompiler.dll Windows Error: 87`. The headless shell does not ship DXC. Adding
  `--disable-dawn-features=use_dxc` makes Dawn use FXC, and everything works. So run the web bench with
  `F2D_PW_ARGS="--enable-unsafe-webgpu --enable-gpu --disable-dawn-features=use_dxc"`.
  Note: the web numbers then come from the **hardware GPU (D3D12)**, not SwiftShader like the WebGL stacks. Record this in the web
  results. Cost: ~15 min (Teak/toolchain time).

## Human interventions

- Scope update from the coordinator: web became optional ("desktop is the must-have").

## Harness notes for the orchestrator

- `harness/runtime/run.sh` rejects the stack (`unknown stack zig-teak`: there is a hard-coded case list on line 12), so I could not run the
  runtime sections through it. I ran every bench mode directly through the same interfaces the harness uses (desktop `--bench=<mode>` on
  stdout, web `harness/bench_web.mjs`).
- `server_conformance.sh` / `conformance.py` need a shell that has sourced `harness/machine-env.sh` (Python 3.12 + numpy).

## Phase notes (end of P1 session, 2026-10-27; timings indicative, shared machine)

- `python harness/conformance.py zig-teak p1`: 17/17 (F01-F15, gen_10_10, gen_50_50).
- `harness/server_conformance.sh zig-teak`: all passed (0 failures), port 18087.
- `test_all`: 9/9 tests pass.
- CLI bench (ReleaseFast, 1 rep): 100x100 factor 81 ms; 200x200 assemble 111 / factor 1233 / solve 191 ms, peak heap 509 MB, 45 allocations.
- Desktop (Win32 + wgpu-native, hardware GPU, Fifo): startup 342 ms; drag p50 8.3 / p95 8.5 / p99 11.5 ms, solve_p50 6.8 ms, 148 MB;
  render p50 8.3 / p95 28.5 / p99 40.4 ms, 774 MB; boundary noop 0.22 ns (in-process).
- Web (`F2D_PW_ARGS` above, hardware D3D12 WebGPU): ready 258 ms, startup 290 ms, boundary noop 2.3 ns / transfer 7.3 us (zero-copy),
  drag p50 16.8 / p99 21.3 ms, solve_p50 12.8 ms; render p50 16.8 / p99 29.9 ms; 257 KB brotli transferred (2.0 MB raw).

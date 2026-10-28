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

---

# AGENT_LOG: zig-teak, phase P2 (change request, SPEC 4.7)

Run id: run1p5   Machine: win-x64   Agent model: claude-opus-5-5   Started: 2026-10-27 (from tag `p1-done-zig-teak`)
Teak pin unchanged (9b16f10...). Shared machine: other agents were building concurrently, timings indicative only.

## What changed

- `model.zig`: `Member.release` (`{"i":[..],"j":[..]}`, only `mz` matters), top-level `springs` (`kx`/`ky`/`kr` optional, presence
  = sprung), both written back by `model.write` (Save in the UI).
- `engine.zig`: releases by static condensation of the local stiffness (`condenseK`) and of the UDL fixed-end forces (`condenseF`,
  same elimination step), applied to assembly, the load vector and end-force recovery, so released end moments come out as 0.
  Springs add to the free DOF diagonal after assembly; restrained + sprung on the same DOF -> `support_conflict`. Auto-restraint:
  a free `rz` with at least one incident member, every incident member released in `mz` at that end, and no `kr` spring, is
  restrained before DOF numbering and listed in `Results.auto_restrained`. Profile still uses all 6 member DOFs (structural coupling).
  Spring forces (-k u) are included in the equilibrium residual (the reference leaves them out, so its F21 residual is 0.33;
  ours is 2e-16). Springs are not listed under `reactions` (only user-restrained nodes are), matching the reference.
- `report.zig`: `warnings` array (`{"warning":"auto_restrained","node":n,"dof":"rz"}`, node-id order).
- UI: warning line (amber, first 12 nodes) and warning count in the status line; member table gets a sortable `Rel` column
  (`-`, `i`, `j`, `i+j`); canvas draws springs (zigzags for kx/ky, a ring marker for kr) and hinge dots near released ends.
- Tests: engine F23/F24/F25 unit test; UI test that loads a P2 model and checks the warning text and the `Rel` cells (11/11 pass).

## Problems over ~10 minutes

- None in the engine. Self-inflicted tooling slip (~3 min): a Python edit script run with Windows' default cp1252 encoding
  truncated `src/engine.zig` (open-for-write before the encode failed) and wrote CRLF into `model.zig`; restored from git
  and re-ran with explicit UTF-8 / `newline=''`. Also the Bash tool collapsed a leading `\` in Zig multiline-string lines inside
  a heredoc; fixed with Edit.

## Teak-caused time (excluded, SPEC 15.6)

- ~3 min: Teak `Palette` has no warning colour; filed hotschmoe/teak#143, app uses a literal amber colour.

## Phase notes (end of P2)

- `python harness/conformance.py zig-teak p2`: 7/7 (F21-F25, gen_10_10, gen_50_50); `... p1`: 17/17.
- `harness/server_conformance.sh zig-teak`: all passed (0 failures), port 18087. Spot-check: POST /solve F24 -> 200 with the
  warning, F25 -> 422 `support_conflict`.
- Desktop bench (release): startup 359 ms; drag p50 8.3 / p99 8.7 ms, solve_p50 7.0 ms; render p50 8.4 / p99 37.6 ms; boundary ok.
- Web bench (`F2D_PW_ARGS="--enable-unsafe-webgpu --enable-gpu --disable-dawn-features=use_dxc"`, 1 run): ready 254 ms,
  startup 308 ms, drag p50 16.8 / p99 23.0 ms (solve_p50 13.5), render p50 16.8 / p99 29.3 ms, boundary 2.1 ns / 7.3 us.
- Diff vs P1 tag: 8 files, ~+259 / -7 lines (incl. ~65 lines of tests). Failed builds in P2: 2 (both the test multiline-string typo).

---

# P5 optimization pass (run1p5, win-x64)

Agent model: claude-opus-5-5, 2026-10-27, one session (~60 min). Teak pin unchanged (9b16f10): the newer
hotschmoe/teak master commits are features (bridge_js option #136, Palette.warning #143, canvas vectors, svg, TextArea),
none a build-time or runtime win for this app, so no bump. Shared machine (two other agents), timings indicative.

## Changes

- **`build.zig`: `check` is now real type-checking (`-fno-emit-bin`)** (dev loop, `build_check`). Before, `check` depended
  on the installed exes, so after an edit it did full LLVM codegen + link of CLI, server and desktop (= a `build_dev`).
  Now each target gets a second, never-installed `Compile` sharing its root module; the build system passes
  `-fno-emit-bin` when nothing asks for the binary, so `check` runs Sema only. It also now covers the **web** wasm target
  (`web/main.zig` was not checked before). An error in any of the four targets still fails `build_check` (verified).
- **Engine: empty node / member lists no longer crash** (review High). `for (1..nn)` / `for (1..nm)` are guarded;
  `{}` and a fully supported single node give 422 `no_free_dofs`, a free node with no members gives 422 `unstable`.
- **Engine: equilibrium residual includes moment balance** (review Medium). `residual = max(force residual,
  |sum M about origin| / (total load x model size + sum |applied mz|))`, so it stays dimensionless and roundoff-only.
- Server: unreadable body -> 400 `bad_request` + `connection: close` (was: socket closed with no reply); 413 now also
  closes the connection instead of trying to drain a >64 MB body; `FRAME2D_ADDR=[::1]:port` accepted.
- Store: `sqlite3_bind_text` return codes checked, `sqlite3_column_text` null-checked, step errors distinguished from "no row".
- Sweep: no per-variant `model.clone` (solve does not mutate the model, only sections are copied; `model.clone` removed);
  missing case `W` gives `roof_drift_W: null` (and a null envelope drift) instead of a silent 0; top-left ties broken by id.
- UI: Save bytes are owned by the Model (page allocator), freed when the download effect completes or is replaced
  (were in `model_arena`, which generate/load reset under an in-flight effect, and grew per Save). Member table re-applies
  its sort after a drag ends and after Solve (once, not per drag frame).
- Cleanups: dead `new_start` (solver), duplicate `comp` names (engine), unused arena `ra` (cli bench), wrong SQLite
  comment in build.zig; `engine.solve` documents its allocator contract (pass an arena; model-error paths do not free).
- Tests 11 -> 15: empty/member-less models, duplicate_id / invalid_ref / zero_length, moment equilibrium with an
  offset origin + UDL + nodal moment, member-table re-sort after drag (fails without the fix).

## Numbers (smoke, shared machine)

Own before/after, same method: `harness/edits/<e>.sh` toggle, then wall time of `build_check` and of `build_dev`
(bash `date` around the `stack.sh` function, 2 reps each, both agree within ~5%):

| | before check | after check | before dev alone | after dev alone |
|---|---:|---:|---:|---:|
| no-op | 0.13 s | 0.12 s | 0.12 s | 0.11 s |
| leaf | 7.0 s | **1.2 s** | 7.1 s | 7.0 s |
| struct | 7.1 s | **1.2 s** | 7.2 s | 7.2 s |
| server | 2.6 s | **1.2 s** | 2.7 s | 2.6 s |
| ui | 6.9 s | **1.1 s** | 6.9 s | 7.0 s |

(Before, a `build_dev` right after a `build_check` was ~0.2 s because check had already built the binaries; now
check + dev is ~1.2 + 7 s. The point is that the check-only loop is ~6x faster and covers web.)
`harness/buildloop/run.sh zig-teak zigincr --quick`: `zig build check --watch` rebuild 6.3 s -> 1.2 s;
**with `-fincremental` 7.6 s -> 0.05 s** (incremental works once check does no LLVM codegen). `build_check -fincremental`
without `--watch` gives no gain (1.35 s; state is not kept across processes), so `build_check` itself stays plain.
`buildloop cold edits --quick` before/after: cold cli 66 s / 55 s, cold dev 96 s / 90 s (noise level). Its quick
edit-check numbers (~0.47 s before) are not trustworthy here: with 1 run and no warmup they are cache hits.

Runtime (`harness/runtime/run.sh zig-teak build cli desktop web binsize server --quick`, `F2D_PW_ARGS` as in P1): unchanged
within noise vs the P2 notes: CLI 50x50 assemble 2.4 / factor 5.4 / solve 3.0 ms; desktop startup 437 ms, drag p50 8.3 /
p99 12.0 ms (solve_p50 7.0), render p50 8.3 / p99 36 ms; web ready 262 ms, startup 315 ms, drag p50 16.8 / p99 19.0,
render p50 16.9 / p99 26.8, boundary 1.9 ns / 8.1 us, 260 KB br; oha 64 conns on gen_50_50: 203 rps, p50 212 ms;
sweeps ok. Sizes: cli 0.91 MB, server 2.0 MB, desktop bundle 3.76 MB, web 0.25 MB br.

## Evaluated and rejected

- **Self-hosted x86_64 backend for Debug (`use_llvm = false`)**: CLI/server compile ~0.45 s vs 2-3 s, but the desktop
  app cannot link (`TODO handle name_type NAME_EXPORTAS` on `wgpu_native.dll.lib`; filed hotschmoe/teak#154), the
  self-hosted Debug server segfaulted at startup (SQLite + mingw libc), and Windows panics lose their stack trace (no PDB).
  `build_dev` wall time is the desktop compile anyway. Not adopted.
- **Strip debug info in Debug desktop**: ~4 s instead of ~7 s, but no symbolized panics in dev builds. Not adopted
  (a benchmark trick more than a best practice); the cheapest remaining `build_dev` lever if the human wants it.
- **ReleaseSafe for build_dev**: desktop leaf rebuild 23 s vs 7 s Debug. Rejected.
- **Skyline `dot` with 4 accumulators + `@mulAdd`**: 200x200 factor 1240 -> 1200-1300 ms (noise). Reverted.
- Profiled, no change made: server `/solve` on gen_50_50 is ~11 ms solve + ~37 ms writing the 16 MB results JSON
  (shortest round-trip float formatting is already std's direct `render`); `canvas.build` at 200x200 is 2.6 ms of an
  8.3 ms frame, so render p95/p99 are Teak/GPU time.

## Review items not changed

- `engine.solve` monolith / hand-mirrored `cli.freeResults`: documented the allocator contract instead of restructuring.
- Thread-per-connection with no limit, sweep threads per request: kept (Windows reserves, not commits, the 8 MB stacks).
- JSON parse errors without location; DB never closed (process lifetime).

## Teak issues filed

- hotschmoe/teak#153: DataTable has no public re-sort after row data changes (app works around it in `table.resort`).
- hotschmoe/teak#154: `linkNativeWgpu` on Windows: the MSVC import lib blocks Zig's self-hosted backend (`-fno-llvm`).

## Final conformance (end of P5)

- `harness/conformance.py zig-teak p1`: 17/17; `p2`: 7/7.
- `harness/server_conformance.sh zig-teak` (port 18087): all passed (0 failures).
- `test_all`: 15/15. Bench modes desktop (startup, drag, render, boundary) and web (ready, startup, drag, render,
  boundary) all produce BENCH lines (runtime smoke above, output in `results/run1p5/win-x64/runtime-smoke-p5/zig-teak`).
- Tip for agents: `zig build check --watch -fincremental` gives ~50 ms re-checks.

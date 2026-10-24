# Runtime / size harness (SPEC 8.2 - 8.8)

Measures code size, desktop/web/server runtime performance, binary size, cross-compilation and the "under the hood" data for one stack at a time.
Bash + Python 3 (stdlib + `psutil`) + Node (Playwright). Works on Linux and under Git bash on Windows. It builds only through each stack's
`stack.sh` (`build_*_release`, `run_server`, `deps_report`) and never touches `stacks/`.

```
harness/runtime/run.sh <stack> [sections...] [--quick] [--no-alt] [--runs N]
```

Sections (default is all, in this order): `meta build loc cli desktop web server binsize hood xcompile`.
`build` must run before `cli desktop web server binsize hood xcompile` (they read `artifacts.json`; `build` aborts the run on failure).
A section can be re-run alone, e.g. `run.sh go web` re-measures only the web build already snapshotted by `build`.

| Env | Default | Meaning |
|-----|---------|---------|
| `F2D_RUN` | `run1` | run id (`results/<run>/...`) |
| `F2D_MACHINE_ID` | set by `harness/machine-env.sh` on Windows; derived (`linux-x64`, `linux-aarch64`, ...) elsewhere | machine id |
| `F2D_RESULTS_SUBDIR` | `runtime` (`runtime-smoke` with `--quick`) | directory under `results/<run>/<machine>/` |
| `F2D_PLAYWRIGHT_DIR` | `~/dev/tools/playwright` | dir with `package.json` + `node_modules/playwright` (1.64.1 / Chromium 156 on run1) |
| `F2D_PW_ARGS` | empty | extra Chromium launch args (appended to the recorded defaults) |
| `F2D_PORT` | `18080 + stack offset` | server port (rust 18080, go 18081, zig 18082, rust-flutter 18083, zig-flutter 18084, go-flutter 18085, go-zig-flutter 18086) |
| `PYTHON` | `python` on Windows, `python3` elsewhere | interpreter |

`--quick` = 1 run per mode, `oha -z 5s`, sweeps of 100 / 20 variants, CLI sizes 10 and 50 only, 1 rep, 1 gctrace size. Smoke output only; never use quick numbers.

Output: `results/<run>/<machine>/runtime/<stack>/` (smoke: `runtime-smoke`). Scratch (web snapshots, brotli cache, generated models, cross-compile trees) lives in `harness/runtime/.work/` (self-ignoring).

## Files

| File | Purpose |
|------|---------|
| `run.sh` | driver; writes `timing.json` (`{section: {wall_s, rc}}`) and `logs/` |
| `stacks.json` | per-stack facts not in `stack.sh`: LOC bucket rules, port offset, engine-lib/wasm globs, flags + stripped notes, web alternate build, cross-compile recipe, dep-source kind. Edit here when a stack layout changes. |
| `f2d.py` | shared helpers (stack.sh runner, exact peak-RSS runner, process sampler, desktop-app runner) |
| `meta.py build.py loc.py cli_bench.py desktop_bench.py web_bench.py server_bench.py binsize.py xcompile.py hood.py` | one per section |
| `web_common.mjs`, `static_server.mjs` | the one shared static server: brotli q11 (lgwin 24) precompressed + content-hash cache, MIME incl. `application/wasm`, **COOP `same-origin` + COEP `require-corp` + CORP on every response** (Flutter `--wasm`/skwasm uses them for its multithreaded renderer; sent for all stacks so nothing is advantaged), `Cache-Control: no-store`, per-request byte accounting. Standalone: `node static_server.mjs --root DIR [--port N]`, or `--manifest` for sizes. |
| `../bench_web.mjs` | Playwright driver (headless Chromium, fresh browser + context per run, CDP cache disabled, service workers blocked) |

## What each section does

* **meta** host, tool versions, git rev, sha256 of `stack.sh` and `stacks.json` (drift check).
* **build** `build_cli_release`, `build_server_release`, `build_desktop_release`, `build_web_release` (the stack's default web build); then the alternate web build if any: rust-flutter prints it as `wasm: <dir>` (default = JS/dart2js, extra = `--wasm`), zig-flutter calls `build_web_wasm_release` (default = dart2js, extra = wasm), go-flutter / go-zig-flutter default to `--wasm` and the extra is `F2D_WEB_MODE=default` (dart2js). Web outputs are copied to `.work/<stack>/webdist/{default,alt-*}`. Wall times here are informational only (controlled build timings belong to `harness/buildloop`).
* **loc** `scc --by-file` (JSON), `LOC_EXCLUDE` applied, files bucketed by the regexes in `stacks.json`. Data/doc languages (Markdown, JSON, YAML, TOML, ...) are not counted. Files under `LOC_EXCLUDE` that look generated (`generated/`, `frb_generated`, `app/web/engine/`, `ffigen/`, lockfiles) go to the `generated` bucket (reported, never in totals); other `LOC_EXCLUDE` entries (Flutter scaffolding) are dropped and counted in `loc_exclude_dropped`. The CLI is bucketed `cli` and rolled into `engine` in `totals_code` (also reported alone). `stack.sh` counts as glue. Tests are bucketed by file path only, so inline Rust/Zig test modules stay in their source bucket.
* **cli** `frame2d bench N N --reps 5` for 10, 50, 100, 200, one process each. The CLI reports the median of its reps. Peak RSS is exact: `wait4()` rusage `ru_maxrss` on Linux (what `/usr/bin/time -v` reports) and `PeakWorkingSetSize` read from the process handle on Windows. Allocation stats (§8.8) are the 50x50 and 200x200 rows.
* **desktop** `<app> --bench=startup|drag|render|boundary`, 5 runs each, `BENCH {json}` parsed from stdout, median per field. Waits for the BENCH line, then for exit (kills the process tree by PID after 15 s). Peak RSS of the process tree is sampled every 100 ms. Any stdout/stderr line mentioning impeller/opengl/d3d/vulkan/software/renderer/... is recorded as `renderer_lines` (what the app reports about its renderer; empty if it reports nothing). The app opens a real window: do not touch the machine while it runs.
* **web** `harness/bench_web.mjs` on the default build (`web.json`) and the alternate build (`web_alt.json`). Per mode `ready startup drag render boundary`, 5 fresh-browser runs. Records brotli body bytes and uncompressed bytes of everything fetched (server-side counters) plus CDP wire bytes, `browser.version()`, Playwright version, launch args, WebGL/WebGPU status. **`chrome://gpu` cannot be opened in headless Chromium (ERR_FAILED, recorded as `chrome_gpu_error`)**; the GPU status is therefore taken from a WebGL query (`UNMASKED_RENDERER_WEBGL`, `software_rendering_suspected`), `navigator.gpu`, and `crossOriginIsolated`.
* **server** three fresh server processes started with `run_server` + `FRAME2D_ADDR=127.0.0.1:<port>` (the process measured is the one listening on the port; the whole tree is killed by PID at the end, a pre-existing listener aborts the run): A) idle RSS, then `oha -z 30s -c 64 -m POST -D gen_50_50.json http://.../solve`; B) `/sweep` 1000 variants on `gen 10 10`; C) `/sweep` 200 variants on `gen 50 50` (`beam_I_scale [0.5, 2.0]`). Startup time includes whatever build `run_server` does; metrics exclude it. Use `--direct` (python arg of `server_bench.py`) to run the `build_server_release` binary instead.
* **binsize** CLI, server, desktop (exe, whole bundle, engine library alone; pure stacks have no separate library, the CLI binary is recorded as the engine-alone proxy), web (total brotli of the whole static dir, engine `.wasm` alone; for pure stacks the app *is* the wasm).
* **hood** allocation table, Go `GODEBUG=gctrace=1` summaries (CLI 50x50 and 200x200; app drag where the Go runtime's stderr is visible), boundary table (desktop + web + `frame2d-server bench-boundary` for go-zig-flutter), binary composition, dependency footprint.
* **xcompile** cold-cache cross build of server + CLI for the other architecture (see below).

## Fallbacks and honest limits

* **CPU-seconds / threads / RSS for the server**: `psutil` on every OS (user+system `cpu_times` of the server process, delta over the phase; `num_threads` sampled every 100 ms; OS peak RSS = Windows `PeakWorkingSetSize` / Linux `VmHWM`). The SPEC asks for cgroup CPU on Linux; not implemented, psutil on Linux is equivalent for single-process servers. Windows `cpu_times` has ~15.6 ms resolution: sub-100 ms phases show `cpu_s` 0.0.
* **bloaty is not installed** here. Wasm: `twiggy top -n 30 -f json`. Native: `llvm-size -A` (sections) and `llvm-nm --size-sort -S` (only if the binary still has symbols). Release binaries are stripped and wasm-opt strips names, so most rows show sections only (`symbols_available: false`, `names_available: false`). Real compile-unit attribution needs unstripped builds: **TODO** (needs per-stack no-strip flags, which `stack.sh` does not expose). If `bloaty` is on PATH on a later machine it is used automatically (`-d sections|compileunits|symbols`, raw lines stored).
* **Dependency source size**: nothing is vendored. `scc` runs over the sources in place: Go used packages (`go list -deps`, module cache), Rust registry crates in the `cargo metadata` resolve graph for host + wasm32 (whole crates, so platform-binding crates such as `windows-sys` inflate it), Zig fetched packages, Dart pub-cache packages (Flutter SDK packages excluded). Approximate; treat as order-of-magnitude.
* **Renderer**: only what the app prints. Flutter desktop on win-arm64 is x64 under emulation (recorded in `desktop.json` as `emulation_note`).
* **Web GPU**: headless Chromium here uses SwiftShader (software); recorded, same flags everywhere (`--ignore-gpu-blocklist --enable-unsafe-swiftshader` plus anti-throttling flags).
* **Server via `run_server`**: some stacks' `run_server` builds a dev profile (go-zig-flutter builds a ReleaseSafe Zig lib and an unstripped Go server; go's `run_server` is not `-s -w`). That is what the stack defines as its server entry point, and is what is measured; `--direct` measures the release binary instead.
* **Cross-compile**: see `xcompile.json` `attempts[].error_tail` for the real failure. Nothing is installed (no `rustup target add`, no cross linkers). Rust to linux/arm64 from Windows fails at `rustup`'s missing std for the target (and would then need a cross linker); that is recorded as the result.

## Record schema (for `report.py`)

All files are JSON in `results/<run>/<machine>/runtime/<stack>/`; times in ms unless the name says otherwise; sizes in bytes unless `_mb`.

* `meta.json`: `run, machine, stack, date, quick, git_rev, stack_sh_sha256, stacks_json_sha256, host{platform,machine,cpu,logical_cpus,ram_gb,gpu}, tools{...}, toolchains{...}`
* `artifacts.json`: `cli, server, desktop_exe, desktop_bundle_dir (null for pure stacks), web{label,src,dist,what}, web_alt{label,src,dist,what}|null`. `build.json`: per build `{fn, env, rc, wall_s, last_line}`.
* `loc.json`: `totals_code{engine (incl. cli), ui, server, glue, tests, other, total_excluding_generated}`, `engine_of_which_cli`, `buckets{engine,ui,server,glue,tests,cli,generated,...:{files,code,comment,blank}}`, `generated_code_not_in_totals`, `loc_exclude_dropped{files,code,by_entry}`, `by_language_code`, `files[{path,language,bucket,code,...}]`.
* `cli.json`: `sizes["10x10"|"50x50"|"100x100"|"200x200"]{assemble_ms,factor_ms,solve_ms (medians over reps), peak_rss_mb, cpu_s, wall_s, nodes, members, free_dofs, profile_before, profile_after, alloc_count, alloc_bytes, peak_heap_bytes, rss_method}`, `alloc_stats_8_8{50x50,200x200}`.
* `desktop.json`: `modes{startup|drag|render|boundary: {ok_runs, median{first_frame_ms | p50,p95,p99,max,solve_p50,lag_max,rss_mb | noop_ns,transfer_us, peak_rss_mb_tree_sampled}, mechanism, runs[...]}}`, `renderer_lines[]`, `emulation_note`.
* `web.json` (default build) and `web_alt.json` (extra): `label, env{browser_version, playwright_version, launch_args, gl{webgl2_renderer,...,webgpu,crossOriginIsolated}, software_rendering_suspected, chrome_gpu_error}, server{...}, manifest{total_raw,total_br,files[]}, modes_out{ready|startup|drag|render|boundary:{ok_runs, median{...}, transferred_body_bytes_median, uncompressed_bytes_median, wire_bytes_cdp_median, runs[{bench, transfer{files[]}, page_errors, timed_out}]}}`, and **`summary{transferred_br_bytes, uncompressed_bytes, tti_ms, startup_first_frame_ms, drag{p50,p95,p99,max,lag_max}, render{...}, solve_p50_ms, boundary{noop_ns,transfer_us,mechanism}, directory_total_br_bytes}`** (the headline numbers).
* `server.json`: `port, idle_rss_mb, idle_threads, oha{rps,p50_ms,p95_ms,p99_ms,status_codes,success_rate,total_responses,wall_s,cpu_s,cpu_s_per_1000_req,core_utilization,avg_cores_busy,peak_rss_mb,peak_threads}`, `sweep_1000_gen10x10` and `sweep_200_gen50x50` `{variants,wall_s,cpu_s,core_utilization,avg_cores_busy,peak_rss_mb,peak_threads,ok,envelope}`, `cores_logical`.
* `binsize.json`: `flags, stripped, cli{bytes}, server{bytes}, desktop{exe_bytes,bundle_bytes,engine_lib_bytes|null,engine_alone_proxy?,largest_bundle_files}`, `web{total_br_bytes,total_raw_bytes,engine_wasm_br_bytes,engine_wasm_raw_bytes,largest_by_br}`, `web_alt{...}`.
* `hood.json`: `alloc_stats`, `go_gc{cli{50x50,200x200:{cycles,total_stw_pause_ms,max_stw_pause_ms}}, app_drag{...,drag_p99_ms}}`, `boundary_table[{platform,noop_ns,transfer_us,mechanism,transfer_share_of_50x50_solve}]`, `binary_composition{tools, fallback, cli, server, wasm_engine[]}`, `dependencies{transitive_count, list_head, dependency_source_loc{...}}` (full list in `deps_report.txt`).
* `xcompile.json`: `host`, `attempts[{target, success, cold_build_wall_s, rc, command, artifacts{name:{bytes}}, runs{ran,ok,how}, steps_beyond_native_build[], error_tail, target_installed?}]`.
* `timing.json`: wall seconds and exit code of each section.

## Expected wall-clock per stack on win-arm64 (full run: 5 runs per mode, oha 30 s)

Measured from the `--quick` smoke runs (1 run per mode) and scaled by 5 for the repeated sections; the machine was not quiet (another agent was building Flutter at the same time), so treat as +-30 %.

| Section | rust (pure, slow egui frames) | go-zig-flutter (Flutter) | Notes |
|---------|------------------------------:|-------------------------:|-------|
| build (warm caches) | 1.5 min | 2 min | cold Flutter web x2 + desktop can be 15+ min; `build` is only needed once per stack |
| loc, meta | < 10 s | < 10 s | |
| cli | 1 min | 1 min | 200x200 x 5 reps is the long one (factor ~3 s each) |
| desktop | ~25 min | ~4 min | rust's window ran at ~250 ms/frame in the smoke run (drag/render are 600 frames each), so 5 runs x (drag 150 s + render 155 s); Flutter ~30 ms/frame |
| web | ~21 min | ~21 min (two builds, ~10 min each) | render mode is the slowest (200x200 solve in WASM + 600 SwiftShader frames) |
| server | ~2 min | ~3 min | 30 s oha + 3 server starts (each includes `run_server`'s build check) + sweeps |
| binsize | ~1 min | ~1 min | first q11 brotli of a Flutter dist takes ~1 min, then cached in `.work/brotli-cache` |
| hood | ~1 min | ~1 min | +1-5 min for Go stacks (GODEBUG=gctrace drag run, CLI 200x200 x 5) |
| xcompile | ~1 min | ~1 min | Rust cold deps cross-build ~20 s here; larger on slower machines |
| **total** | **~55 min** | **~35 min** | pure Go/Zig should land in between; budget about 1 h per stack, ~7 h serial for all seven |

Run stacks one at a time on an idle machine, window in the foreground, plugged in, performance power mode. Nothing else (agents, builds) may run: every number here is a contention number otherwise.

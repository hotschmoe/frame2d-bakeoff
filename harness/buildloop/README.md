# Build-loop harness (SPEC 9)

Measures how long builds take (9.1-9.3, 9.5) and what they cost the machine (9.4, 9.6, 9.7) for any stack directory.
Bash + Python 3 stdlib (psutil optional but strongly recommended on Windows). Runs on Linux and under Git bash on Windows.
Every timed command goes through `harness/measure.sh` (cgroup counters on Linux, psutil fallback elsewhere), and the hyperfine
JSON is kept next to the per-run records.

```bash
source harness/machine-env.sh        # (run.sh does this itself) pinned PATH on Windows
harness/buildloop/run.sh <stack|dir> [sections...] [options]
```

`<stack>` is a name under `stacks/` or any directory that contains a `stack.sh` (a future `stacks/rust-tuned`, a copy, ...).
Nothing in the drivers is stack specific: they only call the SPEC 5.6 functions through `call.sh`, and detect the toolchain from
files (`Cargo.toml`, `go.mod`, `build.zig`, `app/pubspec.yaml`).

## Sections

| Section | SPEC | What it does | Platform |
|---------|------|--------------|----------|
| `cold` | 9.1 | per target (`cli server desktop web [web_wasm] dev`): `hyperfine --runs 3 --prepare clean_all` on `build_<t>_release` / `build_dev` | all |
| `edits` | 9.2 | primes `build_check`/`build_dev`; no-op rebuilds; then for each of `leaf struct server ui`: `hyperfine --warmup 1 --runs 10 --prepare <edit>` on `build_check` and `build_dev` | all |
| `hotreload` | 9.2 | Flutter only: runs the command printed by the stack's `hot_reload_probe` (`flutter run --machine`), toggles the `ui` edit, sends `app.restart` (hot reload), times file write to the `app.progress` "Reloaded" event. Stacks without a probe get status `not-implemented` | all (opens a debug app window) |
| `engine` | 9.2 | Flutter only: `leaf` edit, `build_dev` (measured), then start the freshly built debug desktop app with `--bench=startup` and time until its `BENCH` startup line (first frame). `edit_to_first_frame_s = build wall + launch wall` | all |
| `footprint` | 9.4 | `clean_all`, cold `build_dev`, size; then `--cycles` (default 50) x (leaf edit, `build_check`, `build_dev`, struct edit, `build_check`, `build_dev`); size every `--size-every` cycles and at the end | all |
| `breakdown` | 9.5 | one cold `build_dev` and one `struct`-edit `build_dev`, with each toolchain's own timing output switched on (see below), parsed into deps/frontend/codegen/link/tools | all (link-timer: Linux) |
| `zigincr` | 9.3 | Zig stacks: `zig build --watch` with and without `-fincremental` around `build_check`, file write to next "Build Summary". Status `unsupported` when it yields no rebuild | all |
| `contention` | 9.6 | 4 copies x 20 iterations x 4 configs, PSI and wake-up latency | **Linux only**; elsewhere records `skipped: Linux-only (SPEC 15.4)` |

Default sections: `cold edits hotreload engine footprint breakdown`. `all` adds `zigincr contention`.
SPEC 9.7 (whole-run accounting) is not a section: wrap an agent session with `harness/sample.sh run <stack> <phase> -- <cmd>` (Linux only).

Options: `--quick` (smoke: 1 run, no warmup, 2 cycles, cold targets `cli dev`), `--cold-runs --runs --warmup --cycles --size-every
--engine-runs --hot-reps --zig-reps`, `--cold-targets "cli dev"`, `--link-timer`, `--out-root DIR`.
Env: `F2D_RUN` (default `run1`), `F2D_MACHINE_ID` (set by `machine-env.sh` on Windows; elsewhere defaults to `linux-aarch64` / `linux-x64`),
`F2D_BUILDLOOP_ROOT` (same as `--out-root`).

Records go to `results/<F2D_RUN>/<F2D_MACHINE_ID>/buildloop/<stack>/`. Smoke runs must use
`--out-root results/run1/win-arm64/buildloop-smoke` so they never mix with real data.

### Rules the drivers follow
* Stack functions only through `call.sh` (fresh `bash`, `source stack.sh`, call). Flags live in `stack.sh`. Nothing calls cargo/go/zig/flutter directly, except `breakdown` which
  defines bash *functions* named `cargo`/`go`/`zig`/`flutter` before sourcing `stack.sh` so the stack's own calls pick up `--timings`, `-debug-actiongraph`, `--summary all`, `-v`.
* Stack files are only touched by `harness/edits/*.sh`. `edit.sh` counts toggles (state outside the repo, `$TMPDIR/f2d-bl-state`) and `run.sh` restores every edit on exit,
  including on ^C. After a run `git status --porcelain stacks` must be empty.
* Hyperfine is run with `--shell=none`; commands have no quoting (Windows paths are passed in 8.3 short form because `--prepare` goes through `cmd.exe`).
* Missing tools (GNU make, bloaty, mold, hyperfine) are detected and recorded, never installed.
* Hyperfine warmup records are removed from `<label>.jsonl` and parked in `<label>.warmup.jsonl`.

## Expected wall clock (full settings, win-arm64 estimates)

Scaled from `--quick` smoke runs on `rust` (egui) and `zig-flutter` on this machine (18 logical cores, other agents idle-ish). Smoke wall times, `--quick`:

| Stack | cold (cli+dev) | edits | footprint (2 cycles) | breakdown | engine | zigincr |
|-------|----------------|-------|----------------------|-----------|--------|---------|
| rust | 36 s | 51 s | 56 s | 27 s | n/a | n/a |
| zig-flutter | 173 s | 334 s | 293 s | 156 s | 89 s | 20 s |

Full-campaign estimates per stack (all default sections; the numbers that scale are `cold` = 3 runs x 5-6 targets, `edits` = 4 x 11 x (check+dev) + 22 no-op builds, `footprint` = 50 cycles x 4 builds):

| Stack | Estimate | Dominated by |
|-------|----------|--------------|
| rust, go | 0.5 - 1 h | footprint cycles, cold release builds |
| zig | 0.7 - 1.2 h | cold builds (6 zig targets), footprint |
| rust-flutter, zig-flutter, go-flutter, go-zig-flutter | 3 - 4 h each | footprint (50 cycles x two ~40 s Flutter dev builds), edits (`build_dev` ~40-50 s x 44), cold (Flutter release builds x 3 runs) |
| `contention` (Linux only), any stack | +1 - 3 h | 4 configs x (80 iterations / 4 parallel) plus solo baseline; Flutter stacks at the top of the range |

Use `--cycles 10 --runs 5` for a cheaper provisional pass. The whole campaign for 7 stacks is roughly 18 - 25 hours on this machine; run it on a quiet machine, one stack at a time.

## Record schema

All JSON numbers are seconds unless a name says otherwise. `<stack>` directory contents:

### `meta.json`
`stack, stack_dir, run, machine, started, quick, sections[], toolchains[] (cargo|go|zig|flutter), params{cold_runs, runs, warmup, cycles, size_every, engine_runs, hot_reps, cold_targets[]}, platform, cpu_count, hyperfine, repo_commit, goflags, measure_method`

### `sections/<section>.json`
`{"section","status","reason","wall_s","finished"}`; `status` is one of `ok | failed | skipped | unsupported | not-implemented`. `reason` says why for anything but `ok`
(e.g. `Linux-only (SPEC 15.4)`, `stack.sh defines no hot_reload_probe`, `not a Flutter stack`). `edits-not-applicable.txt` lists edits with no `BENCH-EDIT` marker.

### `<label>.jsonl` (one `measure.sh` record per measured run; warmups in `<label>.warmup.jsonl`)
`wall_s, cpu_s, parallelism, mem_peak_mb, swap_peak_mb, io_read_mb, io_write_mb, procs_peak, exit_code, method ("cgroup" | "psutil" | "wall-only"), stack, label`.
Fields the platform cannot supply are `null` (Windows: no swap, no io; cpu/mem/procs need psutil). Labels:

| Label | Meaning |
|-------|---------|
| `cold-cli`, `cold-server`, `cold-desktop`, `cold-web`, `cold-web_wasm`, `cold-dev` | 9.1, each run preceded by `clean_all` (unmeasured) |
| `prime-check`, `prime-dev` | untimed-by-hyperfine priming builds before the edit loop (not results) |
| `noop-check`, `noop-dev` | 9.2 rebuild with nothing changed |
| `edit-<leaf\|struct\|server\|ui>-<check\|dev>` | 9.2, an edit applied before every run |
| `footprint-clean`, `footprint-cold-dev` | 9.4 setup builds |
| `footprint-cycle-<leaf\|struct>-<check\|dev>` | 9.4, one record per cycle in order: build time drift as the cache grows |
| `engine-prime`, `engine-build` | 9.2 engine path builds |
| `hotreload-prep` | build before `flutter run` |
| `breakdown-cold-dev`, `breakdown-struct-dev` | the traced builds of 9.5 (tracing flags add small overhead; do not use as headline wall times) |
| `zigincr-prime` | priming for the zig probe |

### `hyperfine/<name>.json`
Raw `hyperfine --export-json` (`results[].command` equals the label). Names: `cold-<t>`, `noop`, `edit-<e>`.

### `summary.json`
`{label: {n, failures, method, wall_s{n,min,p50,mean,p95,max}, cpu_s{...}, parallelism{...}, mem_peak_mb{...}, procs_peak{...}, io_*{...}, hyperfine_s{mean,stddev,median,min,max,runs}}}`
Regenerated after each section by `bl.py summary`. The report should show `cpu_s` p50 next to `wall_s` p50 (SPEC 9.4).

### `footprint.json` (+ `footprint/*.json`)
`{cycles_requested, after_clean, cold_dev, after_cycles, growth_bytes, series:[{cycles,total_bytes}]}`; each snapshot is
`{stack_dir, total_bytes, total_mb, items:{<dir>:{bytes, disk_bytes, files, counted_bytes}}}`. Items: `target`, `build`, `zig-out`, `.zig-cache`,
`.zig-global/<child>` (not `p`, the kept package sources), `app/build`, `app/.dart_tool`, `app/web/engine`, and `GOCACHE` (shared cache: `counted_bytes` is the
delta over the size right after `clean_all`). `bytes` is apparent size; `disk_bytes` is allocated size where the OS reports blocks (Linux), else `null`.
`total_bytes` sums `counted_bytes`. Kept download caches (cargo registry, pub cache, Go module cache, zig-pkg) are intentionally excluded.

### `breakdown/<cold-dev|struct-dev>-<cargo|go|zig|flutter>.json` (+ `-trace/` raw output)
`{tool, seconds_by_category{deps,frontend,codegen,link,tools}, note, top_units[{name,cat,duration_s}], link_timer?}`. Values are **sums of per-unit work seconds**
(parallel units overlap), so they exceed wall time; compare shares, not totals. Precision per toolchain:

| Tool | Source | Splits it can make |
|------|--------|--------------------|
| cargo | `--timings` HTML `UNIT_DATA` | workspace crates: frontend and codegen from cargo's per-unit sections; `bin` targets (no sections) filed under `link`; registry crates = `deps` (frontend+codegen together); build scripts = `tools`. With `--link-timer` on Linux the exact link seconds replace the estimate |
| go | `-debug-actiongraph` | own packages' compile action = `frontend` (frontend+codegen are one action); other packages = `deps`; `link` actions = `link`; uses `CmdReal` so cache hits count 0 |
| zig | `--summary all` | each compile step is one number (frontend+codegen+link inseparable) reported under `frontend`; `run` steps = `tools` |
| flutter | `-v` `[ +N ms ]` stamps | keyword heuristic on the log line that ends each gap; approximate. Native steps inside `build_dev` are reported by their own tool in the same directory |

Several toolchains per stack (go-zig-flutter: go, zig, flutter) give one file per toolchain, so add the per-tool files; flutter's gaps include the time its child builds took.

### `hotreload.jsonl`
`{"kind":"startup","flutter_run_to_started_s"}`, then per rep `{"kind":"rep","edit":"ui","rep","file_write_to_reloaded_s","file_write_to_response_s","message","result"}`; `{"kind":"error",...,"tail":[log lines]}` on failure.
(`file_write_to_response_s` is when the `app.restart` request returned; `..._reloaded_s` is the `app.progress` finished event. They should be close.)

### `engine-build.jsonl`, `engine-launch.jsonl`, `engine-e2e.jsonl`
`engine-build` = measure records of `build_dev` after the leaf edit. `engine-launch` = `{"kind":"launch","exe","launch_to_bench_s","first_frame_ms","bench"}` or `{"kind":"error",...}`.
`engine-e2e` per rep: `{rep, ok, build_wall_s, build_cpu_s, launch_to_first_frame_s, first_frame_ms_reported, edit_to_first_frame_s}`.
Note: the app is the *debug* Flutter desktop build that `build_dev` produces, and the window is visible while it runs.

### `zigwatch-<plain|incremental>.json`
`{mode, fn, supported, initial_build_s, rebuild_s[], note}`. `supported:false` => section status `unsupported`.

### `contention/` (Linux only)
`skipped.json` on other platforms. Otherwise `solo.jsonl` (3 baseline iterations), per config directory (`default bounded jobserver jobserver+cgroup`) `copy<N>/iter.jsonl`
(`{iter, step: check|dev|test, wall_s, exit_code}`), `measure/c<N>/loop.jsonl` (cgroup totals of one copy's whole loop: cpu_s, mem_peak_mb, io, procs_peak),
`total.jsonl` (`wall_s` for all copies), `timeseries.csv` (1 Hz: `t, cpu_usage_delta_s, memory_current_mb, procs, psi_cpu_avg10, psi_mem_avg10, psi_io_avg10, mem_used_mb, pswpin, pswpout`),
`latency.json` (`p50,p99,max` wake-up lateness in ms for a 10 ms sleep loop), and `contention_summary.json` (`{config:{iterations, steps{check|dev|test:{p50,p95,n,slowdown_p50_vs_solo}}, total_wall_s, psi_*{max,mean}, machine_mem_peak_mb, pswpin_delta, pswpout_delta, wakeup_latency_ms}}`).
`jobserver*` configs apply only to stacks that build with Cargo or Make/CMake (Flutter); the others get a `skipped.json` in that config directory. The optional mixed round (4 different stacks) is not implemented.

### Whole-run accounting (9.7), Linux only
`harness/sample.sh run <stack> <phase> -- <agent command>` writes `<RESULTS_DIR>/<stack>/agent-<stack>-<phase>.jsonl` (one measure.sh record: whole-session `cpu_s, mem_peak_mb, io_write_mb, procs_peak`)
and `<RESULTS_DIR>/<stack>/<phase>_timeseries.csv` (same columns as above; cgroup-scoped). `RESULTS_DIR` defaults to `results/<run>/<machine>/accounting`. This is the per-run location
instead of the SPEC's literal `results/<stack>/` (SPEC 15.1 layout). CPU-hours in builds = sum of `cpu_s` over the stack's build records versus the session total.

## Files

| File | Role |
|------|------|
| `run.sh` | driver |
| `lib.sh`, `sections.sh` | shared helpers; section implementations |
| `call.sh` | run one stack.sh function; tracing/bounded/incremental shims |
| `edit.sh` | apply/restore `harness/edits/*.sh` with toggle counting |
| `bl.py` | `trim`, `summary`, `footprint`, `breakdown` parsers, `contention` summary |
| `engine.py`, `hotreload.py`, `zigwatch.py`, `proc.py` | interactive drivers |
| `contention.sh`, `contention_loop.sh`, `sampler.py` | 9.6 (Linux) |
| `../jobserver.sh`, `../sample.sh`, `../shims/link-timer` | 9.6.1, 9.7, 9.5 (link-timer: Linux; sets as linker via `CARGO_TARGET_<TRIPLE>_LINKER`, cgo `-extld`, CMake linker launcher) |

## Tuned variants (9.3)
No tuned copies are built here. Create `stacks/rust-tuned` (etc.) later and run `run.sh rust-tuned ...` exactly the same way; records go to their own directory. Zig `-fincremental` is probed by `zigincr`;
stacks can also force `-fincremental` into every `zig build` with `BL_ZIG_INCREMENTAL=1 run.sh zig edits`.
For Go the record includes `GOFLAGS` in `meta.json`.

## Known limits
* `hotreload` and `engine` open a visible debug Flutter window on the desktop; run them on a quiet, unlocked machine.
* On Windows `cpu_s`/`mem_peak_mb` come from psutil sampling at 50 ms (exited children are only counted for as long as they were observed); `io_*`, `swap_peak_mb` are null.
* `link-timer` cannot be used with rustc's MSVC target on Windows (it only sets up the MSVC environment when it runs `link.exe` itself): `breakdown --link-timer` records that.
* `breakdown` for Flutter stacks is heuristic. `--link-timer` for Go/cgo and Flutter/CMake is documented in the shim header but not wired automatically.

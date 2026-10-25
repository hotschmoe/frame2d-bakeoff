# AGENT_LOG: go, phase P1

Run id: run1   Machine: win-arm64   Agent model: claude-sonnet-5-5   Started: Fri Oct 23 23:59:58 2026 (local `date`)

## Toolchain surprises / problems over ~10 minutes

None cost more than ~10 minutes. Small notes:

- Gio v0.10.3 API differs from most examples online (`new(app.Window)`, `w.Event()`, `gtx.Event(pointer.Filter{...})`,
  `event.Op`). Read the module source in the Go module cache instead of guessing; no failed builds from it.
- A `clip.Path` records into the shared `op.Ops` while it is being built, so only one path can be open at a time.
  The canvas therefore buckets visible members by colour first and builds one path per bucket.
- Headless Chromium here is x64 under emulation with software WebGL: web `drag` frames take ~0.5 s, mostly the
  WASM solve plus software raster. Numbers are indicative only (SPEC 15.3).

## Deviations (Emscripten, UI fallback, extra dependency, spec question)

- No Emscripten. Web is `GOOS=js GOARCH=wasm` plus Go's own `wasm_exec.js`.
- Dependencies: `gioui.org` (UI), `modernc.org/sqlite` (pure-Go SQLite driver, so CGO is off everywhere).
- `boundary` bench: the Go engine is compiled into the app, so there is no boundary to cross. The mode times an
  in-process no-op call and an in-process call returning 38,103 f64, and says so in `mechanism`.
- `frame_ms` in the drag/render benches is the interval between consecutive FrameEvent starts (includes vsync wait).
  The solve runs on the UI thread, so `lag_frames` is always 0.
- `rss_mb` is the peak working set (Windows `GetProcessMemoryInfo`); on web it is the Go runtime's wasm memory (`MemStats.Sys`).
- `build_check` also vets the js/wasm client, because `platform_js.go` is only compiled for that target.
- Desktop Open/Save take a path from a text field (Gio has no native file dialog); web uses a file input and a download link.
- Spec ambiguity resolved: RCM components are concatenated in ascending min-id order and the whole sequence is reversed
  (matches the `gen` goldens: profile_before 10221 / profile_after 7575 for 10x10).

## Human interventions

- None.

## Phase notes

- Engine: `engine/` (model, gen, rcm, solve). Skyline LDLt, column-oriented, four-way unrolled dot/axpy kernels
  (halved factor time at 50x50: 23 ms -> 12 ms).
- Conformance: `harness/conformance.py go p1` 17/17; `harness/server_conformance.sh go` all passed.
- Native CLI bench (median of reps, win-arm64): 50x50 assemble 2.5 / factor 12.3 / solve 5.1 ms; 100x100 factor 192 ms;
  200x200 factor ~3.5 s (peak heap ~1 GB).
- Moment-diagram level of detail (skip members under 12 px, 3 stations under 40 px) cut the web `render` frame cost from
  ~3.5 s to ~0.5 s median at 200x200; without it the web render bench did not finish in 15 minutes.
- Desktop benches (win-arm64, Gio/D3D11, in-process solve): drag p50 27 ms (solve p50 15 ms), render p50 22 ms,
  startup first frame 214 ms, boundary noop 1.6 ns / echo 34 us.
- Web benches (emulated x64 Chromium, software WebGL, indicative only): drag p50 260 ms (solve p50 78 ms), render p50 486 ms,
  startup 1.4 s, ready 1.1 s. Web payload `main.wasm` is ~12.4 MB unstripped-of-runtime (Go runtime + Gio + Go Regular font).

# AGENT_LOG: go, phase P2

Started: Sat Oct 24 01:01:03 2026 (local `date`)

- Change (all in `engine/`): `Spring`/`Release` types and `support_conflict` in model.go; in solve.go springs are added to the
  assembled diagonal, `condense()` does sequential static condensation of mz releases (stiffness and fixed-end forces, used by
  assembly, loads and post-processing), and `zeroRotations` detects rz diagonals <= 1e-12 x max diagonal, then the model is
  renumbered/reassembled with those rz restrained and `auto_restrained` warnings emitted. profile_before/after stay computed
  from the original supports (matches ref.py); free_dofs is the final count.
- No problems over ~10 minutes. conformance p2 7/7, p1 run after (see below). No UI changes.

## P5 optimization pass

Run: run1p5 smoke (`--quick`, single runs, machine shared with other agents, so only large effects mean anything). No toolchain or
dependency change; solver is still the hand-written skyline LDLt; BENCH-EDIT markers untouched.

### Changes

- `stack.sh` `build_check`: host `go vet ./...` and js/wasm `go vet ./cmd/app` now run in parallel; the redundant `go build ./...` (vet
  already type-checks every package and test file) is gone. Verified that a type error in `platform_js.go` or in a host file still fails it. (dev loop)
- `stack.sh` `build_dev`: CLI+server (one `go build -o build/dev/ a b`), desktop app and wasm client build as three parallel processes
  instead of four sequential ones; `wasm_exec.js`/`index.html` are copied only when their content changed. (dev loop, cold dev)
- `stack.sh`: `-buildvcs=false` on every build (no per-build `git status` stamping inside the monorepo); the three `go env` spawns that ran
  on every build are folded into one at source time. (dev loop, cold)
- Web/desktop canvas (`cmd/app/canvas.go`): straight members (ghost layer, undeformed members, deflected members short enough to draw as one
  piece) and the moment-diagram outline are filled as flat-capped thin quads (`addSegment`, same winding so overlaps stay filled) instead of
  going through Gio's CPU stroker. A flat-capped stroke of one segment is exactly that quad; multi-piece deflected members still use
  `clip.Stroke` for their joins. Visual check: screenshots of the old and new wasm (10x10, with and without Moment) look identical at this
  scale; the only theoretical difference is the missing join at 1 px width between moment-diagram pieces. (web drag/render, desktop render)
- Engine `dot`: 8 independent accumulators instead of 4 (Analyze 50x50 drag micro-benchmark about 16.1 -> 14.3 ms; inside noise of the
  full harness). (drag solve, CLI)
- Engine `Results.WriteJSON` (new `engine/encode.go`): streaming encoder through a pooled 32 KB buffer, same field order as encoding/json
  (test compares against it, including `e`-format floats, escaped strings and null stats). The CLI `solve` and the server solve routes use it
  instead of building the whole 16 MB document with reflection. Non-finite floats become `null` instead of failing the response. (server CPU/RSS, CLI)
- Server: concurrent solves are bounded to `runtime.NumCPU()` with a semaphore (each in-flight solve holds a skyline plus a result document,
  and the work is CPU-bound, so more than cores only inflates RSS and tail latency). Sweep `variants` is capped at 1,048,576. (RSS, p99)
- Output file close errors in the CLI are now reported (full disk).

### Smoke numbers (same machine, before = run1 code)

| metric | before | after |
|---|---|---|
| build_check no-op / leaf / struct / server / ui edit (buildloop quick) | 1.91 / 1.97 / 2.12 / 2.41 / 2.23 s | 1.33 / 1.28 / 1.31 / 1.58 / 1.46 s |
| build_dev no-op / leaf / struct / server / ui edit | 1.94 / 3.77 / 3.52 / 2.54 / 2.70 s | 1.34 / 1.67 / 1.64 / 1.64 / 1.58 s |
| build_check, direct (no harness), no-op | 0.98 s | 0.29 s |
| build_dev, direct (no harness), no-op | 0.97 s | 0.39 s |
| cold build_dev | 20.4 s | 13.3 s |
| cold cli / server / desktop / web release | 6.1 / 9.0 / 7.0 / 8.8 s | 6.5 / 11.8 / 6.6 / 5.8 s (noise, no real change expected) |
| web drag p50 (frame) / solve p50 | 252 / 76 ms | 149 / 84 ms (solve is noise, same code) |
| web render p50 | 511 ms | 108 ms |
| desktop drag p50 | 26.9 ms | 25.4 ms (vsync bound) |
| desktop render p50 | 21.8 ms | 10.6 ms |
| web download br / raw | 2,334,337 / 12,439,952 B | 2,334,761 / 12,444,662 B |
| server `oha -c 64` rps / p50 / p99 / peak RSS | run1 full: 169 / 303 ms / 1468 ms / 3074 MB | quick 5 s: 171 / 392 ms / 470 ms / 484 MB |
| CLI 50x50 factor | 11.5 ms | 11.5 ms |

Server p50 rises because requests now queue for a slot instead of all running at once (same throughput, 64 / 171 rps = 374 ms by Little's
law); p99 and RSS fall. The run1 server baseline is from the full run, the after number from a 5 s quick run.

### Review defects

- Fixed: `Analyze` with an unknown `OnlyCase` silently returned zero cases; now `invalid_ref` (test added).
- Fixed: unbounded sweep `variants` (cap added); sweep `model_id` storage error was reported as 404 (now 500, unknown id stays 404).
- Fixed: `js.FuncOf` callbacks in the web file picker were never released (now released after the file is delivered or the picker is
  closed with no file; a cancelled picker never fires `change` and still leaks one closure per cancel).
- Fixed: thin tests. Added spring stiffness, spring-on-restrained-DOF (`support_conflict`), propped cantilever through an end release (with
  `auto_restrained` warning, reaction and moment closed forms), unknown case, and the streaming encoder.
- Rejected: "sweep envelope uses signed drift". SPEC says `max_roof_drift_W` is the maximum of the per-variant values and the golden
  conformance passes with it; changing it would change the contract.
- Not done: shared mutable `engine.Model` sorted in place by `setModel` (UI invariant is documented by the sort; no bug seen).

### Tried and dropped

- wasm-opt (binaryen 133) -O2/-Os: -3% raw, -0.7% brotli (2.326 -> 2.311 MB), +4-5 s build. Not worth a post-link step.
- Incremental refactorization during a drag (reuse the factor columns before the first changed DOF): the dragged top-middle node of the
  50x50 bench sits at free DOF 972 of 7650 after RCM, so only ~13% of the factor would be skipped. Not implemented.
- `-ldflags=-w` for dev builds: saves ~50 ms per link, but loses debugger symbols; kept dev builds debuggable.

### Ideas not done

- Two-column register blocking in `factor` (shares loads of the left columns; maybe 15-20% on the factor).
- Caching RCM numbering and heights across drag frames (topology does not change while dragging).
- Web: the 12.4 MB wasm is the Go runtime plus Gio plus go-text; only dropping `go-text`/Gio features would shrink it.

### Final conformance

`harness/conformance.py go p1` 17/17, `go p2` 7/7, `harness/server_conformance.sh go` all passed (FRAME2D_ADDR 127.0.0.1:18391),
`go test ./...` ok, `gofmt -l` clean, all bench modes (drag, render, startup, ready, boundary on desktop and web, CLI bench, server oha and sweeps)
ran through the runtime smoke harness (`F2D_RUN=run1p5`) without failures. Builds and tests were also run through
`harness/measure.sh go p5-*` (records in `results/adhoc/go/`).

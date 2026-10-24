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

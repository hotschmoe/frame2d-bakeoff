# run1 / win-arm64 findings

Indicative: one machine, one run, reduced protocol (3 runs, trimmed scope; see `TIMELINE.md` Deviations). Flutter and Chromium run as x64 under emulation on this ARM64 machine; the pure stacks are native. All numbers are from `SUMMARY.md` / `summary.json` unless noted.

## Scores

| stack | SPEC-weight overall | excl. agent handling | human-priority |
|---|---:|---:|---:|
| rust | **0.695** | 0.707 | 0.657 |
| zig | 0.663 | **0.723** | **0.684** |
| go | 0.648 | 0.605 | 0.502 |
| go-zig-flutter | (0.510, P3 only) | 0.510 | 0.315 |
| rust-flutter | 0.499 | 0.510 | 0.387 |
| zig-flutter | 0.486 | 0.484 | 0.325 |
| go-flutter | 0.473 | 0.456 | 0.287 |

Human-priority = binary size, cold build, warm build, in-app performance (desktop + web) and resources (server CPU/RSS, app RSS), equal weights. Differences below about 0.05 are noise.

## Dev loop

- **Pure stacks win.** Leaf-edit `build_check` / `build_dev`: rust 0.79 / 2.66 s, go 1.18 / 1.96 s, zig 1.20 / 6.25 s.
- **Flutter stacks lose:** `build_check` 6.5 s (rust-flutter) to 11.7 s (go-zig-flutter); `build_dev` 12.3 s (rust-flutter), 14.6 s (go-flutter), 29.0 s (go-zig-flutter), 35.4 s (zig-flutter).
- **Cold builds:** go is cheapest (CLI 5.6 s, desktop 8.2 s, web 5.3 s, dev 16.5 s), rust next (CLI 6.8 s, dev 18.3 s). Zig is slow cold (zig 43–89 s, zig-flutter 59–101 s); the first `zig build` after a cache wipe compiles the build runner (~50 s, zig AGENT_LOG).
- **Why the Zig + Flutter stacks are slow warm:** their `build_check` / `build_dev` redo fixed work every time. No-op ≈ edit: zig-flutter no-op dev 33.3 s vs 35.4 s edited; go-zig-flutter 28.8 vs 29.0 s. Cargo and Go do real incremental work (rust-flutter no-op dev 8.9 s vs 12.3 s edited). This is how the agents wrote `stack.sh`, not an inherent language cost.
- **Flutter extras:** hot reload is sub-second where a probe exists (go-flutter 0.83 s, go-zig-flutter 0.88 s; rust-flutter and zig-flutter have no probe). Engine edit → running app: rust-flutter 16.2 s, go-flutter 17.6 s, go-zig-flutter 31.5 s, zig-flutter 37.9 s.

## Runtime

- **zig (dvui) leads desktop and web:** drag p50 8.7 ms, startup 64 ms, web TTI 177 ms, 0.61 MB transferred. (Its 1.4 ms render p50 mostly measures draw-command building.) rust is next on desktop (13.9 ms drag, 152 ms startup), but its web render is slow (p50 252 ms).
- **go is slow on web:** drag p50 281 ms, render 487 ms, TTI 1.07 s; Gio on desktop is fine (26 ms drag, 97 ms startup).
- **Engine, CLI 200×200 factor+solve:** zig-flutter 1449 ms, zig 1514, go-zig-flutter 1715, rust-flutter 2106, rust 2114, go 2597, go-flutter 6366. The two Go engines differ 2.5×, so implementation quality is confounded with language.
- **Server, 50×50 `/solve`, 64 connections:** rust-flutter 300 req/s, rust 294, zig 251, zig-flutter 249, go-zig-flutter 180, go 169, go-flutter 155. p99 593 ms (rust) to 1575 ms (go-flutter). CPU-s per 1000 requests 55 (Rust) to 103 (go-flutter).

## Resources

- **Server idle RSS:** Rust and Zig 6.4–8.6 MB; Go 55–62 MB. **Peak RSS under load:** 1.0 GB (rust-flutter) to 3.1 GB (go).
- **Desktop drag RSS:** zig 79 MB, rust 127, go 195, Flutter stacks 356–605 MB.
- Build `cpu_s` / memory are psutil-sampled on Windows and under-count; machine-cost conclusions wait for Linux cgroups.

## The Flutter tax (on this machine)

Desktop bundle 28–31 MB vs 5.4–7.3 MB (`flutter_windows.dll` alone ~21 MB); startup 930–975 ms vs 64–152 ms; drag RSS 3–8× the pure stacks; `build_check` 5–15× slower. x64 emulation inflates startup, frame times and builds, so the ratio should shrink on x64 / Linux. Web flavors differ (dart2js/CanvasKit for rust-flutter and zig-flutter, `--wasm` for the Go ones), so Flutter web numbers mix renderer and engine effects.

## Go engine vs Zig engine (go-flutter → go-zig-flutter, P3)

- **Smaller:** engine DLL 3.07 MB → 0.34 MB; engine wasm 943 KB → 78 KB (brotli); web transferred 1.57 → 0.70 MB.
- **Faster:** CLI 50×50 20.7 → 7.4 ms, 200×200 6366 → 1715 ms; web drag p50 124 → 24 ms; desktop drag p50 46 → 30.5 ms (render ~16 ms for both, vsync-bound).
- **Server gains are modest:** 155 → 180 req/s, 103 → 92 CPU-s per 1000 requests, p99 1575 → 1123 ms; the Go HTTP/JSON path still dominates. Server binary 10.35 → 10.73 MB, CLI 2.73 → 3.02 MB (cgo + Zig object + mingw runtime).
- **Costs:** the dev loop roughly doubles (`build_check` 7.7 → 11.7 s, `build_dev` 14.6 → 29.0 s, cold dev 41 → 64 s); web TTI 1.93 → 2.16 s (both have a reproducible ~12 s first load with the Flutter `--wasm` build).
- **Agent effort:** 47 min active (stall-corrected), 88 turns, 2 failed builds, ~$10 estimated.

## Agent handling

- **P1 time to green:** rust 26 min, zig 37, go 61, zig-flutter 63, rust-flutter 78, go-flutter 95 (agents overlapped, so indicative). P2 took 1–3 min everywhere (137–195 lines, 2–5 files). Estimated cost P1+P2: $6.2 (rust) to $25.4 (rust-flutter); prices are assumed Sonnet-class list rates.
- **Failures** (one fresh classifier for all stacks): go 0 failed builds; zig 18 (10 `build_config`, 4 `stale_api` from Zig 0.17 API changes, 14.8 per 100 builds); rust 2 `stale_api` (`gen` is reserved in edition 2024); rust-flutter lost 55 of 67 failure minutes to 7 `runtime_crash` items, an intermittent access violation in the release app never root-caused (it did not recur in 12 campaign bench runs). Zig stacks catch 83–88% of failures at compile time; rust-flutter only 47%.
- **Shared cracks:** ffigen needs an x64 libclang on ARM64 (~15 min each in go-flutter and zig-flutter); Impeller/GLES `drawRawPoints` was very slow (~20–30 min each in three Flutter stacks); the harness `bash` → WSL bug cost early agents their `measure.sh` records; rust-flutter killed other agents' processes by image name.

## Code review (SPEC 10.2)

Means 3.0–3.7 (rust-flutter 3.67; rust, go, go-zig-flutter 3.5; zig 3.33; zig-flutter 3.17; go-flutter 3.0). Tests scored 2 for five of seven stacks: no stack unit-tests the P2 springs/releases. Reviewer-reported defects (not independently verified): unknown `only` case silently returns empty (rust, go); malformed JSON → 400 / exit 1 instead of 422 / exit 2 (rust, zig); rust-flutter `engine_move_and_solve` keeps a bad node position on failure; zig-flutter exports have unchecked null session access and leak on OOM; go-flutter lacks a `support_conflict` error code and misspells a sweep field (`BeamIScle`); go-zig-flutter OOM paths skip `last_error` and leak, and `POST /models` stores unvalidated models. SPEC gap: `max_roof_drift_W` doesn't say signed or absolute.

## Watch on linux-aarch64, linux-x64, win-x64

- Does the Flutter tax shrink without emulation, and does the web ordering hold?
- Zig cold builds and the always-rebuild `stack.sh` loops on a warm cache.
- Real cgroup CPU and memory per build (machine-cost category).
- Go server RSS and the Go-vs-Zig server gap; the go-flutter vs go engine slowdown.
- The ~12 s first-load TTI of Flutter `--wasm` web builds.
- Agent handling with serial (non-overlapping) runs.

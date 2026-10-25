# AGENT_LOG: rust, phase P1

Run id: run1   Machine: win-arm64   Agent model: claude-sonnet-5-5   Started: Fri Oct 23 22:53:08 2026 (local, `date` at start)

## Toolchain surprises / problems over ~10 minutes

Nothing cost more than ~10 minutes. Smaller notes (each a few minutes):

### wasm-opt `--all-features` output rejected by Chromium
- Time lost: ~5
- Category: build_config
- What happened: `wasm-opt -O3 --all-features` (binaryen version_133) emits "compact imports", which Chromium 156 refuses (`Invalid import kind 127`).
- What fixed it: enable only the features rustc 1.99 actually uses (bulk-memory, nontrapping-float-to-int, sign-ext, mutable-globals, multivalue, reference-types). Lives in `build_web_release`.

### `gen` is a reserved keyword in edition 2024
- Time lost: ~2
- Category: stale_api
- What happened: first draft had `mod gen;` and `use ... as gen;`; edition 2024 reserves `gen`. Renamed the module to `generator`.

### Harness note (not a stack problem): `bash` on PATH resolves to WSL on this machine
- `harness/conformance.py` (no `--bin`) and `measure_fallback.py` launch plain `bash`, which Windows resolves to `C:\Windows\System32\bash.exe` (the WSL stub, no distro installed), so `build_cli_release` "fails" with WSL banner text. I ran conformance with `--bin <abs path to frame2d.exe>` and ran measure.sh with the Git bash path. Orchestrator may want `C:\Program Files\Git\usr\bin` first on the Windows PATH for harness runs.
- `conformance.py --bin` with a relative forward-slash path failed with WinError 2; an absolute `C:/...` path works.

## Deviations (Emscripten, UI fallback, extra dependency, spec question)

- No Emscripten. Web build is `cargo build --target wasm32-unknown-unknown` + `wasm-bindgen --target web` + optional `wasm-opt`, no trunk.
- Extra dependencies beyond the SPEC list: `rfd` (file dialogs, native and web), `web-time` (Instant that works in wasm), `egui_extras` (virtualized table), `rusqlite` with the `bundled` feature (SQLite; compiles C), `wasm-bindgen`/`web-sys`/`wasm-bindgen-futures` (web glue).
- UI renderer is eframe `glow` (OpenGL / WebGL2), not wgpu, to keep the dependency and compile cost lower.
- Golden note for the orchestrator: `fixtures/golden/reference/gen_10_10.results.json` matches this stack everywhere except 5 values on member 60 (case D) that are theoretically zero (roundoff: ours 1.4e-10 vs reference 2.9e-11, golden abs floor is 1e-10). Everything else, including `profile_before = 10221`, `profile_after = 7575`, matches at 1e-8. Any stack will see similar noise on those entries.
- Spec ambiguity resolved: `equilibrium_residual` = max(|sum Fx|, |sum Fy|) / (1 + sum of |applied| + |reaction| force components), same as the reference.
- Spec ambiguity resolved: `startup` is measured from `main()` entry on desktop (not the OS process creation time); on web from `performance.now()` (= navigation start).
- Spec ambiguity resolved: the `boundary` mode in a pure-Rust stack has no language boundary on desktop (direct calls are reported, mechanism says so). On web, `index.html` times JS -> WASM calls of `f2d_noop` / `f2d_echo` exported through wasm-bindgen (the echo is a memcpy into a new Float64Array).
- Interactive drag solves only the selected load case (`engine::solve_filtered`); the full model solve (all cases) is used on load, "Solve" and case change when that case is missing.

## Human interventions

- None.

## Phase notes

P1 state at hand-off (win-arm64, native arm64 Windows, Chromium x64 emulated, software GL in headless):

- `harness/conformance.py rust p1`: 15/15 (goldens skipped, none committed yet). `harness/server_conformance.sh rust`: all passed.
- Engine: `frame2d bench 200 200 --reps 3`: assemble 88 ms, factor 2075 ms, solve 146 ms, profile 48,658,500, ~281k allocs / 535 MB. 50x50: factor 9.6 ms, solve 2.3 ms.
- Desktop (release, glow): startup first_frame 195 ms; drag p50 13.6 / p99 17.0 ms (solve_p50 11.8 ms); render p50 8.4 / p99 30 ms (200x200 solve 2.2 s, rss ~1.2 GB); ready 100 ms; boundary noop 0.21 ns (direct call).
- Web (Chromium 156 headless, swiftshader): ready 361 ms; startup 479 ms; drag p50 52 / p99 92 ms (solve_p50 30 ms); render p50 241 / p99 790 ms (200x200 solve 11.6 s in wasm, 500 MB); boundary noop 31 ns, echo(38103) 75 us (memcpy).
- Wasm size: 4.24 MB uncompressed (after wasm-opt -O3).
- Cold builds seen (not a controlled measurement): CLI release 2-3 s, server release 23 s, desktop release 30 s, web release 45 s, build_dev (all bins) 15 s, build_check 0.6 s warm.
- Build wait is a small share of wall time; no ownership/lifetime errors cost time. The only compile errors were the `gen` keyword and two deprecation warnings (egui 0.37 renamed `show_inside` to `show`).

## P2 (spring supports, member releases, auto-restraint)

Started: Fri Oct 23 23:19:54 2026 (local, `date` at start). Done in roughly 15 minutes of wall time.

- `harness/conformance.py rust p2 --bin <abs frame2d.exe>`: 5/5; p1: 15/15. Unit tests pass. No problems over ~10 minutes.
- Files touched: `src/model.rs` (Spring, Release types, `springs`/`release` fields), `src/engine.rs` (validation `support_conflict`, static condensation in `local_k`/`fixed_end`, spring diagonal add, `auto_restrain` pre-pass, warnings, spring forces in the equilibrium sum), `src/generator.rs` (struct initializers only).
- Design: auto-restraint detects a free rz whose summed condensed rotational diagonal plus kr is <= 1e-12 x the largest such diagonal, before DOF numbering. Reactions are reported at the given restraints only (auto-restrained DOFs report no reaction), as in the reference. Profiles are computed with the auto-restrained DOFs removed (reference computes them with the original restraints; only differs for models with warnings).
- Builds: `build_check` and a cargo release CLI build were run directly (not under measure.sh); the measure.sh attempt failed because the fallback launches the WSL `bash` stub (same harness issue as in P1), so P2 build timings are not recorded.

## P5 optimization pass

Machine: win-arm64, noisy (other agents building concurrently). Before numbers are from run1 or taken the same way just before the change; smoke run `F2D_RUN=run1p5 ... --quick`.

### Changes
- `.cargo/config.toml` (new): `rust-lld` as the MSVC-target linker (dev loop is link-bound: 3 exes relinked per edit); wasm target gets `+simd128`. Targets dev-loop and web solve speed.
- `Cargo.toml` dev profile: `debug = "line-tables-only"`, dependencies `debug = false` (smaller PDBs, faster link). Targets build_dev after an edit.
- `Cargo.toml` release profile: `lto = false` (the hot engine is in our own crate, nothing hot crosses crates), own crate `codegen-units = 1`, dependencies `codegen-units = 16` (parallel codegen of egui/tokio/sqlite). Targets cold release builds (desktop 24.6 s in the smoke run, web 17.5 s incl. bindgen/wasm-opt vs 27.8 / 40.9 s in run1; machine was busy so treat as indicative). Binary sizes about the same (desktop 5.36 MB bundle, web br 1.17 MB, server 2.72 MB).
- `stack.sh build_web_release`: wasm-bindgen + wasm-opt are skipped when cargo produced an identical `.wasm` (sha256 stamp in `target/`); no-op web rebuild 0.47 s instead of redoing bindgen and wasm-opt. Also `--remove-name-section --remove-producers-section` and `wasm-opt --enable-simd`.
- `engine.rs` `dot`: 8 independent accumulators with fused multiply-add where the hardware has it (always on aarch64, `target_feature = "fma"` elsewhere; plain mul+add otherwise, since software fma is slow). Native 100x100 factor 137 -> 100 ms, 50x50 factor 12.9 -> 6.8-8.2 ms; 16 lanes was slower, so 8.
- Server: blocking pool capped at the core count (was tokio's 512) so hundreds of concurrent requests queue instead of each holding a multi-MB skyline; SQLite `journal_mode=WAL`, `synchronous=NORMAL`; removed `unwrap()`/`expect()` on mutex locks (poison-tolerant `AppState::db()`), the header split, the sweep slot and `to_value`.
- Canvas: members and deflected chords are batched into solid-colour quad meshes (`Segments`) instead of one egui `line_segment` (anti-aliased path stroker) per member. Targets web/desktop render and drag frame time. Trade-off: these lines are no longer feathered.
- `solve_current` falls back to a full solve when the selected case is not in the model.

### Smoke before -> after (run1 baseline -> this pass, same machine, 1 run each)
- build_dev after a 1-file edit (own timing loop, 3-5 runs): ~2.4-3.7 s -> ~1.6-1.8 s. build_check edit ~0.5-0.8 s -> ~0.5-0.6 s (already fast). No-op build_dev 0.22 s, check 0.25-0.5 s.
- Web: drag p50 84 -> 48 ms, solve_p50 28 -> 22.6 ms, render p50 252 -> 197 ms, 200x200 wasm solve 11.6 s -> 7.2 s.
- Desktop: drag p50 13.9 -> 12.4 ms, render p50 8.4 -> 8.4 ms (startup 295 ms in this run is noise, 151 ms in run1); 50x50 CLI factor 9.0 -> 6.8 ms; 200x200 solve 1.98 s -> ~1.86 s.
- Server (oha 5 s, quick): rps 294 -> 303, p50 178 -> 215 ms, p99 593 -> 285 ms, peak RSS 1936 -> 550 MB, threads 150 -> 40 (p50 up slightly because excess requests now queue).

### Review defects
- Fixed: unknown `only` case silently returned empty results (now `invalid_ref`); several server `unwrap()/expect()` on locks/slots; tests (5 -> 14: springs, spring conflict, releases + auto-restrain warning, mid-span hinge equilibrium, zero_length, duplicate_id, no_free_dofs, filtered solve, dot tail lengths).
- Rejected: malformed model JSON -> HTTP 400 / CLI exit 1. SPEC 5.3/5.4 reserve 422 / exit 2 for model errors; unparseable JSON is not a model error and falls under "anything else". Left as is.
- Not done: UDL logic duplicated across `solve_case` / `fixed_end` (refactor, no perf gain); drag path still redoes prepare + RCM per frame (symbolic factorization cache would cut ~25% of the 50x50 drag solve); render bench in swiftshader is still dominated by software raster; `panic = "abort"` rejected because the server relies on unwinding for `spawn_blocking` panics -> 500.

### Final conformance
`conformance.py rust p1` 17/17, `p2` 7/7, `server_conformance.sh rust` all passed, `cargo test` 14/14, bench modes (drag, render, startup, ready, boundary) ran on desktop and web in the smoke run. Not committed.

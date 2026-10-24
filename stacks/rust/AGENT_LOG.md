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

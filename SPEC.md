# Frame2D Stack Bake-off — Spec

A single, fixed app built seven times by AI agents, once per language stack, to measure how each stack behaves in an agent-driven dev loop and in production: build-loop time, what builds cost a shared machine, agent friction, code size, maintainability, desktop/web/server performance, and binary size, plus enough under-the-hood data to explain each result.

The app is **Frame2D**, an interactive 2D frame analyzer (direct stiffness method). It's sized to take roughly one agent-day per stack, and it puts pressure on every part of a stack at once: a numeric hot loop, a chatty FFI boundary (drag a node and re-solve every frame), heavy canvas rendering, a large virtualized table, a concurrent server, and a WASM path.

---

## 1. Stacks

| ID | Stack | Desktop UI | Web | Server | Engine lives in |
|----|-------|-----------|-----|--------|-----------------|
| `rust` | Pure Rust | egui / eframe | eframe → WASM | axum + tokio | Rust |
| `go` | Pure Go | Gio | Gio → WASM (`js/wasm`) | `net/http` | Go |
| `zig` | Pure Zig | dvui | dvui web backend → WASM | `std.http` or http.zig | Zig |
| `rust-flutter` | Rust + Flutter | Flutter | Flutter web + Rust → WASM | axum + tokio | Rust |
| `zig-flutter` | Zig + Flutter | Flutter | Flutter web + Zig → WASM | Zig (`std.http` or http.zig) | Zig |
| `go-flutter` | Go + Flutter | Flutter | Flutter web + Go → WASM | `net/http` | Go |
| `go-zig-flutter` | Go + selective Zig + Flutter | Flutter | Flutter web + Zig → WASM | Go, Zig engine via cgo | Zig (after Phase 3) |

Groupings for comparison:

- **Pure stacks** (`rust`, `go`, `zig`): all three use immediate-mode UI, so the comparison is apples-to-apples.
- **Flutter + systems language** (`rust-flutter`, `zig-flutter`, `go-flutter`): same UI layer, different engine and bridge.
- **Hybrid** (`go-zig-flutter`): forked from the finished `go-flutter` run (end of Phase 2). It measures only the cost and payoff of carving out a Zig engine.

Optional:

- **`zig-teak`**: Pure Zig using Teak instead of dvui. Run separately and never substitute it for the `zig` baseline.
- **`rust-tuned`** and **`rust-flutter-tuned`**: not separate agent runs. These re-measure the build loop on the finished Rust code with a tuned build configuration (§9.3).

---

## 2. Ground rules

1. **Same conditions.** Same agent model, same copy of this spec, same fixture files, fresh context for each stack, stacks run in randomized order, same machine.
2. **Pinned toolchains.** Record exact versions in `results/env.md` before starting (§12). No toolchain upgrades mid-run.
3. **Allowed dependencies.** UI framework, HTTP server, JSON, SQLite, the FFI/bridge tooling for the stack (flutter_rust_bridge, ffigen, wasm-bindgen, etc.), and test/bench tooling. **No linear algebra or numeric libraries** (no nalgebra, faer, ndarray, gonum, etc.). The solver is written by hand to the algorithm in §4.4.
4. **Engine placement.** In the Flutter stacks, all analysis logic lives in the systems language. Dart is UI, state and glue only.
5. **No cross-pollination.** An agent never sees another stack's code. The exception is `go-zig-flutter`, which forks from `go-flutter` by design.
6. **Generated code.** Generated bindings live under a `generated/` directory, or are listed in `LOC_EXCLUDE` (§8.2).
7. **Done means green.** A phase is done when the conformance suite (§6) passes in full. If a stack hits the time box without passing, it is scored as incomplete, with whatever passes counted.
8. **Time box.** Phase 1: 8 hours of agent wall time. Phase 2: 2 hours. Phase 3: 3 hours.
9. **Human interventions.** Any human message other than the kickoff prompt and bare "continue" counts as an intervention and is logged.
10. **One agent at a time.** Agent runs happen on an otherwise idle machine, so agent wall time and build-wait time aren't distorted by other agents' builds. Multi-agent load is measured separately and deliberately (§9.6). If you run agents in parallel anyway to save time, record which stacks overlapped and treat §8.1 timings as indicative only.
11. **Every agent run gets its own cgroup** (§9.7), so whole-phase CPU, memory and I/O totals can be attributed to a stack.
12. **No Emscripten unless absolutely needed.** WASM builds use each language's native toolchain (Rust `wasm32-unknown-unknown` + wasm-bindgen, Go `js/wasm`, Zig `wasm32-freestanding`/`wasm32-wasi` targets, Flutter's own web compiler). Emscripten is a last resort: an agent may use it only when no native route works, must say why in `AGENT_LOG.md`, and the stack's report flags it as a deviation, with the Emscripten build time, tool count and output size shown separately (§9.5 `tools`, §8.6).

---

## 3. Phases

| Phase | Stacks | Work |
|-------|--------|------|
| **P1 Build** | all 7 | Implement §4–§5 until the full P1 conformance suite passes. |
| **P2 Change request** | all 7 | Add spring supports and member end releases (§4.7). Measures maintainability: diff size, files touched, time to green. |
| **P3 Port** | `go-zig-flutter` only | Fork `go-flutter` after P2. Profile, then port the solver to Zig. The Zig static library links into the Go server (cgo, `zig cc` as `CC`), the Flutter desktop app (dart:ffi), and the web build (WASM). Go remains for the server only. |
| **P4 Bug hunt** (optional) | all 7 | Seed a fixed bug (§10.4) into each finished codebase. A fresh agent fixes it using only the failing tests. Measures debuggability. |

Measure the build loop (§9.1–9.6) after P2 on every stack, and again after P3 for `go-zig-flutter`. Whole-run accounting (§9.7) and the failure taxonomy (§8.1) are collected for every phase as it happens.

---

## 4. Engine

### 4.1 Analysis model

- Linear elastic, small displacement, 2D frame. Euler–Bernoulli members (no shear deformation).
- 3 DOF per node: `ux`, `uy`, `rz`.
- SI units throughout: m, N, N·m, Pa.
- Global axes: X right, Y up, rotation counter-clockwise positive.
- Member local x runs from node `i` to node `j`. Local y is local x rotated +90°.

### 4.2 Loads

- **Nodal loads:** `fx`, `fy`, `mz` in global axes.
- **Member UDL:** `w` (N/m), uniform over the full length, acting in **member local y**. Gravity on a left-to-right beam is negative.
- Fixed-end forces for a UDL (local, acting on member): `N = 0`, `V_i = V_j = -wL/2`, `M_i = -wL²/12`, `M_j = +wL²/12`.
- Up to 3 load cases per model. **Factor once, solve each load case** with the same factorization.

### 4.3 DOF numbering

1. Reorder nodes with **deterministic RCM** (§4.4).
2. Number only **free** DOFs. Restrained DOFs are eliminated, not kept with penalty values.
3. Walk nodes in RCM order. Within a node, the order is `ux`, `uy`, `rz`, skipping restrained ones.

### 4.4 Solver (mandated)

- **Reverse Cuthill–McKee**, deterministic:
  - Node adjacency comes from members. Ignore duplicate edges.
  - For each connected component, take the unvisited node with minimum degree (ties broken by lowest id). Run George–Liu pseudo-peripheral node search from it (BFS rooted level structure; repeat from a minimum-degree node in the last level while eccentricity increases).
  - Cuthill–McKee BFS from that start. Visit neighbors in ascending (degree, id) order.
  - Process components in ascending order of their minimum node id.
  - Reverse the final order.
- **Skyline (profile) storage**, upper triangle, stored by column.
- **LDLᵀ or Cholesky** factorization in skyline. Implementations must produce the same `profile` statistic (§4.6), which proves equal work.
- **Pivot check:** a pivot ≤ `1e-12 × max diagonal` aborts with error `unstable`, reporting the DOF's node id and component. The tolerance literal must sit on a line marked `BENCH-EDIT:leaf` (§9.2).

### 4.5 Post-processing

- **Reactions** at restrained DOFs, from member end forces summed at each node, minus applied nodal loads.
- **Member end forces**, local, acting on the member: `[N_i, V_i, M_i, N_j, V_j, M_j] = k_local · u_local + f_fixed`.
- **Station diagrams** at 11 equally spaced points (x = 0 … L), with these sign conventions:
  - `N(x) = −N_i` (tension positive)
  - `V(x) = V_i + w·x`
  - `M(x) = −M_i + V_i·x + w·x²/2` (sagging positive)
- **Equilibrium check:** for each load case, sum of reactions plus sum of applied loads (including UDL resultants) must equal zero to a relative tolerance of 1e-8. Report the residual in `stats`.

### 4.6 Validation and errors

Return `{"error": "<code>", "detail": "..."}` and no results for any of these:

| Code | Condition |
|------|-----------|
| `invalid_ref` | A member, support or load references a missing node, member, material or section. |
| `zero_length` | A member's length is below 1e-9 m. |
| `duplicate_id` | Duplicate node or member id. |
| `unstable` | Pivot check failed (§4.4). |
| `no_free_dofs` | Every DOF is restrained. |

### 4.7 P2 change request (not in P1)

- **Spring supports:** `{"node": n, "kx": .., "ky": .., "kr": ..}`. Any of the three may be present. A spring adds stiffness to that free DOF's diagonal. A DOF cannot be both restrained and sprung (new error code `support_conflict`).
- **Member end releases:** on a member, `"release": {"i": ["mz"], "j": ["mz"]}`. Only `mz` releases are required. Implement by **static condensation** of the member stiffness and fixed-end forces.
- **Auto-restraint:** if releases leave a free rotational DOF with zero stiffness (for example, every member at a node released in `mz`, no rotational spring), restrain it automatically and add `{"warning": "auto_restrained", "node": n, "dof": "rz"}` to `warnings`. Do not report `unstable` for this case.
- The conformance suite grows with fixtures F21–F25 (§6.2).

### 4.8 Generator

`gen B S` builds a deterministic B-bay × S-story moment frame:

- Bay width 6.0 m, story height 3.5 m. Nodes on an `(B+1) × (S+1)` grid.
- **Node ids:** row-major from bottom-left, `id = s·(B+1) + b + 1` for story level `s ∈ [0, S]` and column line `b ∈ [0, B]`.
- **Member ids:** all columns first (by column line, then bottom to top), then all beams (by level, then left to right). Columns run bottom to top; beams run left to right.
- **Material:** `steel`, E = 200e9 Pa.
- **Sections:** `COL` (A = 0.015, I = 1.2e-4) for columns, `BM` (A = 0.010, I = 8.0e-5) for beams.
- **Supports:** level-0 nodes fixed (`ux`, `uy`, `rz`).
- **Load cases:**
  - `D`: every beam has `w = −20000`.
  - `L`: every beam has `w = −10000`.
  - `W`: nodal `fx = +15000` at the leftmost node of every level above 0.

| Size | Nodes | Members | DOF (before eliminating supports) |
|------|------:|--------:|----:|
| 10 × 10 | 121 | 210 | 363 |
| 50 × 50 | 2,601 | 5,050 | 7,803 |
| 100 × 100 | 10,201 | 20,100 | 30,603 |
| 200 × 200 | 40,401 | 80,200 | 121,203 |

---

## 5. Interfaces

### 5.1 Model JSON (input)

```json
{
  "materials": [{ "id": "steel", "E": 200e9 }],
  "sections":  [{ "id": "BM", "A": 0.01, "I": 8e-5 }],
  "nodes":     [{ "id": 1, "x": 0.0, "y": 0.0 }],
  "supports":  [{ "node": 1, "ux": true, "uy": true, "rz": true }],
  "members":   [{ "id": 1, "i": 1, "j": 2, "material": "steel", "section": "BM" }],
  "load_cases": [{
    "id": "D",
    "nodal":      [{ "node": 2, "fx": 0, "fy": -10000, "mz": 0 }],
    "member_udl": [{ "member": 1, "w": -5000 }]
  }]
}
```

P2 adds `"springs": [...]` at the top level and an optional `"release"` on members (§4.7).

### 5.2 Results JSON (output)

```json
{
  "load_cases": [{
    "id": "D",
    "displacements": [{ "node": 1, "ux": 0, "uy": 0, "rz": 0 }],
    "reactions":     [{ "node": 1, "fx": 0, "fy": 0, "mz": 0 }],
    "members": [{
      "id": 1,
      "end_forces": [0, 0, 0, 0, 0, 0],
      "stations":   [{ "x": 0.0, "N": 0, "V": 0, "M": 0 }]
    }],
    "equilibrium_residual": 0.0
  }],
  "warnings": [],
  "stats": {
    "nodes": 0, "members": 0, "free_dofs": 0,
    "profile_before": 0, "profile_after": 0,
    "assemble_ms": 0, "factor_ms": 0, "solve_ms": 0,
    "alloc_count": 0, "alloc_bytes": 0, "peak_heap_bytes": 0
  }
}
```

The three allocation fields are required in the **CLI binary** only (`frame2d solve` and `frame2d bench`), and cover one solve, excluding model generation and JSON parsing:

| Stack engine | How to count |
|--------------|--------------|
| Rust | counting wrapper around the global allocator (atomic counters) |
| Zig | counting wrapper around the allocator passed to the engine |
| Go | `runtime.ReadMemStats` delta: `Mallocs`, `TotalAlloc`; `peak_heap_bytes` = max sampled `HeapInuse` (report as approximate) |

Other front ends may report them as `null`.

- Arrays are sorted by node or member id. `displacements` lists every node; `reactions` lists one entry per node with at least one restrained DOF.
- Numbers are printed with round-trip precision (shortest representation that round-trips an f64).
- `profile_before` and `profile_after` are the skyline profile (sum of column heights) under original id order and under RCM order. Both must match the golden files exactly.

### 5.3 CLI

Every stack ships a `frame2d` CLI built from the same engine:

```
frame2d solve <model.json> [-o results.json]   # solve, write results
frame2d gen <B> <S> [-o model.json]            # generate model (§4.8)
frame2d bench <B> <S> [--reps N]               # gen + solve N times; print stats JSON to stdout
```

The CLI exits with code 0 on success, 2 on a model error (JSON error on stdout), and 1 on anything else.

### 5.4 Server

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/health` | — | `{"ok": true}` |
| POST | `/solve` | model | results |
| POST | `/models` | model | `{"id": "<id>"}` (stored in SQLite) |
| GET | `/models/{id}` | — | model |
| POST | `/models/{id}/solve` | — | results |
| POST | `/sweep` | sweep request | sweep result |

Sweep request and result:

```json
{ "model": { ... } | "model_id": "<id>",
  "variants": 1000,
  "beam_I_scale": [0.5, 2.0] }
```

```json
{ "variants": [{ "scale": 0.5, "roof_drift_W": 0.0, "max_abs_M": 0.0 }],
  "envelope": { "max_roof_drift_W": 0.0, "max_abs_M": 0.0 } }
```

- Variant k scales every `BM` section's I by `lo + (hi − lo)·k/(N−1)`.
- `roof_drift_W` is the `ux` of the top-left node under case `W`.
- `max_abs_M` is the largest |M| over all stations, members and load cases.
- The sweep must run variants concurrently across all cores.

Other requirements:

- Listen on the address in `FRAME2D_ADDR` (default `127.0.0.1:8080`).
- Request body limit: 64 MB.
- Model errors return HTTP 422 with the error JSON.

### 5.5 Client (desktop and web)

**Features**

- **Model:** open and save model JSON, plus a "Generate" dialog for B and S.
- **Canvas:** pan and zoom (mouse/trackpad, plus pinch on web). Draw members, supports and node markers.
- **Overlays:** deflected shape with a scale slider, moment diagram toggle, members colored by max |M|, and a load case selector.
- **Drag a node:** the model re-solves continuously with the node's new coordinates and redraws. The solve can run on the UI thread or a worker, but the frame log must record solve time and lag (frames between input and the matching result).
- **Member table:** virtualized, sortable by any column. It must stay smooth with 20,100 rows (the 100 × 100 model).

**Bench modes**

Desktop uses `--bench=<mode>`; web uses `?bench=<mode>`.

- **`drag`:** generate 50 × 50, select node id `S·(B+1) + B/2 + 1` (roof, middle), move it on a circle of radius 0.5 m over 600 frames (one revolution), and solve case `D` plus redraw every frame.
  - Record per frame: `solve_ms`, `frame_ms`, `lag_frames`.
  - Then print one line, `BENCH {"mode":"drag","p50":..,"p95":..,"p99":..,"max":..,"solve_p50":..,"lag_max":..,"rss_mb":..}`, and exit (desktop) or stay idle (web).
- **`render`:** generate 200 × 200, solve once, moment overlay on. Over 600 frames, pan across the full width while zooming 1× → 8× → 1×. Print frame-time percentiles in the same format.
- **`startup`:** generate and solve 50 × 50, render the first frame, then print `BENCH {"mode":"startup","first_frame_ms":..}` measured from process start (desktop) or navigation start (web).
- **`ready`:** web only. Print `BENCH {"mode":"ready","tti_ms":..}` when the app first accepts input.
- **`boundary`:** stacks with a language boundary only (all Flutter stacks on desktop and web, and the WASM engine call path in the pure stacks' web builds). Measures the cost of crossing into the engine, separate from the engine's own work:
  - 1,000,000 calls to an exported no-op, `f2d_noop()` → `noop_ns` per call.
  - 1,000 calls to an exported `f2d_echo(n)` that returns `n` f64 values, with `n = 38,103` (50×50: 2,601 nodes × 3 displacements + 5,050 members × 6 end forces) → `transfer_us` per call, and the mechanism used (zero-copy view, memcpy, serialization).
  - Print `BENCH {"mode":"boundary","noop_ns":..,"transfer_us":..,"mechanism":".."}`.
  - `go-zig-flutter` also runs the same measurement from Go into Zig through cgo (`frame2d bench-boundary` subcommand on the server binary).

On desktop, `BENCH` lines go to stdout. On web, they go to `console.log`, where the Playwright harness reads them.

**Web specifics**

- The web build is a static directory. The engine runs **client-side in WASM**; the client must not call the server for the bench modes.
- Flutter stacks: produce both `flutter build web --wasm` and the default build, and measure both.

### 5.6 Required stack interface

Each stack's root contains `stack.sh`, which defines these shell functions. The harness only ever calls these.

```bash
clean_all          # remove build outputs and compiled deps; keep downloaded sources (§9.1)
build_cli_release  # → prints path to the frame2d binary
build_server_release
build_desktop_release   # → prints path to the app executable or bundle
build_web_release       # → prints path to the static web dir
build_check        # fastest "does it compile" loop: cargo check / go vet ./... + go build / zig build check / dart analyze + native check
build_dev          # the dev-loop build used during development (debug profile; all targets the agent normally rebuilds)
run_server         # foreground; honors FRAME2D_ADDR
test_all           # runs the stack's own unit tests
deps_report        # prints the transitive dependency list, one per line (§8.8)
bounded            # sets env/flags so the stack's builds use at most $BENCH_JOBS parallel jobs (§9.6)
```

Optional: `hot_reload_probe` (Flutter only) — see §9.2.

Each function must work from a fresh shell with only `stack.sh` sourced. Any toolchain flags (RUSTFLAGS, CGO_ENABLED, `-Doptimize`, etc.) are set inside these functions, never left to whoever calls them, so the agent and the harness always build with identical flags.

---

## 6. Conformance

### 6.1 P1 fixtures (closed-form)

Common properties unless stated: E = 200e9 Pa, A = 0.01 m², I = 8e-5 m⁴ (EI = 1.6e7 N·m²), L = 5 m, P = 10,000 N, w = −5,000 N/m (local y).

**Tolerance:** relative 1e-9, with an absolute floor of 1e-12 for values near zero. Displacements are in m and rad; forces in N and N·m; signs follow §4.1 and §4.5.

| ID | Model | Checks |
|----|-------|--------|
| F01 | Cantilever along +X, fixed at x=0, tip `fy = −P` | tip `uy = −0.02604166667`, tip `rz = −0.0078125`; base reaction `fy = +10000`, `mz = +50000` |
| F02 | Cantilever, one member, UDL `w` | tip `uy = −0.0244140625`, tip `rz = −0.006510416667`; base reaction `fy = +25000`, `mz = +62500` |
| F03 | Simply supported, 2 members (node at midspan), pin at left (`ux`, `uy`), roller at right (`uy`), `fy = −P` at mid | mid `uy = −0.001627604167`; `M` at midspan `= +12500`; reactions `fy = +5000` each |
| F04 | Simply supported, 2 members, UDL `w` on both | mid `uy = −0.00254313151`; `M` at midspan `= +15625`; reactions `fy = +12500` each |
| F05 | Fixed–fixed, 2 members, UDL `w` | mid `uy = −0.0005086263021`; left reaction `mz = +10416.66667`, right `mz = −10416.66667`; `M(0)` on member 1 `= −10416.66667`; `M` at midspan `= +5208.333333` |
| F06 | Fixed–fixed, 2 members, `fy = −P` at mid | mid `uy = −0.0004069010417`; left reaction `mz = +6250`; `M` at midspan `= +6250` |
| F07 | Propped cantilever: fixed left, roller right, one member, UDL `w` | left reaction `fy = +15625`, `mz = +15625`; right reaction `fy = +9375` |
| F08 | Axial bar along +X, fixed left, `fx = +P` at right | `ux = 2.5e-5`; `N(x) = +10000` (tension) everywhere |
| F09 | Vertical cantilever (0,0)→(0,5), fixed base, `fx = +P` at top | top `ux = +0.02604166667`, top `rz = −0.0078125`; base reaction `fx = −10000`, `mz = +50000` |
| F10 | Inclined cantilever (0,0)→(4,3), fixed base, `fy = −P` at tip | tip `ux = +0.012488`, `uy = −0.01667566667`, `rz = −0.00625`; base reaction `fy = +10000`, `mz = +40000` |
| F11 | F05 with three load cases (`D` = UDL, `P` = point load at mid, `Z` = no loads) | each case matches its single-case fixture; `Z` returns all zeros; factorization runs once (`factor_ms` reported once is acceptable) |
| F12 | Two disconnected cantilevers in one model | each matches F01; RCM handles both components |
| F13 | Beam with no supports | error `unstable` |
| F14 | Member references node 99 (absent) | error `invalid_ref` |
| F15 | Member with `i` and `j` at the same coordinates | error `zero_length` |

### 6.2 P2 fixtures

| ID | Model | Checks |
|----|-------|--------|
| F21 | F01 plus vertical spring at tip, `ky = 384000` (= 3EI/L³) | tip `uy = −0.01302083333` (half of F01) |
| F22 | One member, both ends fixed, release `mz` at `j`, UDL `w` | identical to F07 reactions |
| F23 | Fixed–fixed, 2 members, release `mz` at the `j` end of member 1 only (internal hinge), `fy = −P` at mid | mid `uy = −0.001627604167`; end reactions `mz = +12500` (left) and `−12500` (right) |
| F24 | As F23, but release `mz` at both member 1 `j` and member 2 `i` | solves; one `auto_restrained` warning for the hinge node `rz`; `ux` and `uy` at every node match F23; hinge node `rz = 0` |
| F25 | F01 with the tip both restrained in `uy` and given a `ky` spring | error `support_conflict` |

### 6.3 Generated-model goldens

There's no closed form for the generated frames, so:

1. The first stack to pass §6.1 generates golden results for `gen 10 10` and `gen 50 50`. Commit them to `fixtures/golden/`.
2. Before trusting them, check them: equilibrium residual < 1e-8, and spot-check one roof `ux` under `W` against a second stack.
3. Every stack must then match the goldens at relative 1e-8 (abs floor 1e-10), and match `profile_before` and `profile_after` **exactly**.

### 6.4 Server conformance

`harness/server_conformance.sh` (§8) hits every endpoint in §5.4, including:

- a 422 for each error fixture;
- a round trip through `/models`;
- `/sweep` with 1,000 variants on `gen 10 10` checked against golden values.

---

## 7. Repository layout

```
frame2d-bakeoff/
├── SPEC.md                    # this file
├── fixtures/
│   ├── p1/F01.json … F15.json # model + "expect" block
│   ├── p2/F21.json … F25.json
│   └── golden/                # gen_10_10.results.json, gen_50_50.results.json, sweep_10_10.json
├── harness/
│   ├── conformance.py         # runs `frame2d solve` on all fixtures, compares
│   ├── server_conformance.sh
│   ├── bench_build.sh         # §9.1–9.3
│   ├── bench_runtime.sh       # §8.3–8.5
│   ├── bench_web.mjs          # Playwright
│   ├── edits/                 # scripted edits, §9.2
│   ├── measure.sh             # per-build cgroup accounting, §9.4
│   ├── shims/link-timer       # linker wrapper, §9.5
│   ├── contention.sh          # 4-copy contention runs, §9.6
│   ├── jobserver.sh           # machine-wide jobserver, §9.6.1
│   ├── wakeup_probe.py        # responsiveness probe, §9.6
│   ├── sample.sh              # 1 Hz cgroup + PSI sampler, §9.7
│   ├── classify_failures.md   # prompt + taxonomy for §8.1 classification
│   └── report.py              # collects results/*.json into results/SUMMARY.md
├── stacks/
│   ├── rust/ … go-zig-flutter/
│   │   ├── stack.sh
│   │   ├── AGENT_LOG.md       # agent fills this in (§8.1)
│   │   └── …
└── results/
    ├── env.md
    └── <stack>/<metric>.json
```

Each fixture file holds the model plus an `expect` block, which is a list of `{ "path": "<JSON pointer into results>", "value": <number> }` or `{ "error": "<code>" }`. `conformance.py` resolves the pointers after sorting the results by id.

---

## 8. Metrics

### 8.1 Agent handling

Pull these from the session logs:

- wall time to green
- agent turns and tool calls
- build invocations, failed builds, and **total time spent waiting on builds** (sum of build-command durations), also as a fraction of wall time
- test runs and failed test runs
- human interventions (count and reason)
- tokens and cost

The agent also keeps `AGENT_LOG.md` with a short note for any problem that took more than about 10 minutes (toolchain issue, FFI issue, missing library). These notes become the qualitative "cracks" section of the report.

**Failure taxonomy.** After each phase, a fresh agent reads the session log and classifies every failed build, failed check, failed test and failed conformance run into one category:

| Category | Examples |
|----------|----------|
| `type` | mismatched types, missing fields, wrong signatures |
| `ownership` | Rust borrow/lifetime errors |
| `concurrency_types` | Rust `Send`/`Sync`/async bounds; Go data race caught by `-race` |
| `comptime_sema` | Zig comptime and semantic analysis errors |
| `strictness` | unused variable/import errors (Go, Zig) and other lint-as-error friction |
| `stale_api` | the agent called an API that doesn't exist at the pinned version (std churn, outdated crate/package API, hallucinated function) |
| `ffi` | binding mismatch, ABI/layout error, ownership across the boundary, WASM interop |
| `link` | unresolved symbols, duplicate symbols, linker configuration |
| `build_config` | build system, toolchain, codegen tool or packaging setup |
| `runtime_crash` | panic, segfault, illegal behavior trap, uncaught exception |
| `wrong_result` | ran fine, produced wrong numbers (caught by unit tests or conformance) |

From this, report per stack:

- count per category, and minutes spent per category (time from the first failure to the next success in that category)
- **where bugs were caught:** share caught at compile/check time vs by the stack's own tests vs late, by the harness. This is the direct test of whether a stricter compiler pays for itself in an agent loop.
- **`stale_api` rate** per 100 builds. This is the cost of a moving language or ecosystem for an agent whose training data lags the toolchain.

### 8.2 Code size

`scc --by-file` with `LOC_EXCLUDE` applied. Report code lines (not blanks or comments), split into:

| Bucket | What goes in it |
|--------|-----------------|
| engine | analysis, solver, JSON model types |
| ui | client app |
| server | HTTP, SQLite, sweep |
| glue | FFI and bridge code, WASM interop, build scripts |
| tests | unit tests in the stack |
| generated | reported separately, never in totals |

### 8.3 Desktop performance

- `frame2d bench B S --reps 5` for 10×10, 50×50, 100×100 and 200×200. Report median `assemble_ms`, `factor_ms` and `solve_ms`, and peak RSS (`/usr/bin/time -v`).
- App: `--bench=drag`, `--bench=render` and `--bench=startup`, 5 runs each. Report the median of each percentile.

### 8.4 Web performance

Served by one shared static server with precompressed brotli (q11) for all stacks. Measured with headless Chromium via Playwright, cache disabled, 5 runs.

- transferred bytes (brotli) and uncompressed bytes
- `tti_ms` (`?bench=ready`)
- `?bench=drag` and `?bench=render` percentiles
- engine-only WASM solve time for 50×50 (from `drag`'s `solve_p50`)

### 8.5 Server performance

- `oha -z 30s -c 64 -m POST -D gen_50_50.json http://…/solve`: requests/s, p50/p99 latency, peak RSS.
- `/sweep` with 1,000 variants on `gen 10 10`, and 200 variants on `gen 50 50`: wall time and peak RSS.
- Idle RSS after startup.
- For both the `oha` run and the sweeps, also record **CPU-seconds** (from the server's cgroup, §9.4), **peak OS thread count** (`Threads:` in `/proc/<pid>/status`, sampled every 100 ms), and **core utilization** = CPU-seconds ÷ (wall × cores). A sweep that doesn't reach most cores is a concurrency-design finding, not just a speed number.
- **CPU-seconds per 1,000 requests** from the `oha` run. This is the closest proxy for hosting cost.

### 8.6 Binary size

Release builds, stripped where the toolchain allows. Record exact flags.

| Artifact | Notes |
|----------|-------|
| `frame2d` CLI | |
| server | static where possible |
| desktop app | full bundle **and** the engine library alone (Flutter's engine dominates all four Flutter bundles, so the engine library is the meaningful comparison) |
| web | total brotli bytes, and the engine `.wasm` alone |

### 8.7 Cross-compile

From the host, build the server and CLI for the other architecture (linux/arm64 if the host is x86_64, or the reverse). Record:

- success or failure
- the steps needed beyond the native build
- cold build time
- whether the binary runs (under QEMU or on real hardware)

For `go-zig-flutter`, this is the test of `zig cc` as the cgo compiler.

### 8.8 Under the hood

These don't feed the score directly. They explain *why* the headline numbers came out the way they did.

**Engine memory behavior** (CLI, 50×50 and 200×200)

- `alloc_count`, `alloc_bytes`, `peak_heap_bytes` from `stats` (§5.2). Few large allocations versus many small ones is the main thing to look for.
- Go only: run `frame2d bench` and the drag bench with `GODEBUG=gctrace=1`. Report GC cycles, total pause and max pause. Line the max pause up against the drag p99.

**Boundary cost** (§5.5 `boundary` mode)

- `noop_ns` and `transfer_us` per stack and per platform (desktop FFI, web WASM, cgo).
- Express the transfer cost as a share of a 50×50 solve: `transfer_us ÷ (solve_p50 × 1000)`. If it's more than a few percent, the bridge design matters as much as the engine language.

**Binary composition**

- `bloaty -d compileunits` (or `-d symbols` when compile units aren't available) on unstripped copies of the release CLI and server (symbols are needed for attribution), plus `-d sections`. Group results into: own code, language runtime/std, third-party dependencies, other.
- WASM: `twiggy top -n 30` (Rust/Zig) or `bloaty` on the `.wasm` for all stacks. Same grouping.
- This shows, for example, how much of the Go WASM payload is the runtime and how much of the Rust server is tokio/axum.

**Dependency footprint**

- Transitive dependency count from `deps_report`.
- Dependency source size: vendor everything (`cargo vendor`, `go mod vendor`, the used packages under `~/.cache/zig/p`, the used packages in the pub cache) and run `scc` over it. Report code lines.
- This is the code you compile cold and implicitly trust. It usually explains most of the cold-build gap between stacks.

---

## 9. Build-loop measurement

During agent work, builds are the slowest part of the loop, and on a shared dev server they also slow down everything else running on the machine. So this section measures both how long builds take (§9.1–9.3) and what they cost the machine (§9.4–9.7).

Every timed build in this section runs through `harness/measure.sh` (§9.4), so wall time always comes with CPU, memory and I/O numbers.

### 9.1 Cold build

`clean_all`, then time each `build_*_release` and `build_dev`, using `hyperfine --runs 3 --prepare 'source stack.sh && clean_all'`.

`clean_all` keeps downloaded sources and removes compiled output:

| Toolchain | Keep | Remove |
|-----------|------|--------|
| Cargo | `~/.cargo/registry`, `~/.cargo/git` | `target/` |
| Go | module cache | `go clean -cache` |
| Zig | `~/.cache/zig/p` (package sources) | the rest of the global cache, plus `.zig-cache/` and `zig-out/` |
| Flutter | pub cache | `flutter clean` |

Each stack's `clean_all` documents what it keeps.

### 9.2 Incremental edits

Each codebase carries marker comments on specific lines. The harness edits `harness/edits/*.sh` toggle a value on the marked line between two states, so every run makes a real semantic change.

| Edit | Marker | Change | Ripple |
|------|--------|--------|--------|
| `leaf` | `BENCH-EDIT:leaf` on the pivot tolerance literal (§4.4) | `1e-12` ↔ `2e-12` | one function body |
| `struct` | `BENCH-EDIT:struct` on a field of the node struct/type | add or remove `bench_pad: u32` (or the stack's equivalent) | every user of the type |
| `server` | `BENCH-EDIT:server` on a response header value | `"x-frame2d: a"` ↔ `"x-frame2d: b"` | one handler |
| `ui` | `BENCH-EDIT:ui` on a toolbar label string | `"Solve"` ↔ `"Solve!"` | one widget |

For each edit, measure both the check loop and the dev build:

```bash
hyperfine --warmup 1 --runs 10 --prepare 'harness/edits/<edit>.sh <stack>' \
  'harness/measure.sh <stack> <edit>-check -- bash -c "source stack.sh && build_check"' \
  'harness/measure.sh <stack> <edit>-dev   -- bash -c "source stack.sh && build_dev"'
```

Agents spend most of their iterations in the check loop, so `build_check` is the number that tracks agent experience most closely; `build_dev` is the cost of actually running something.

Also measure:

- **no-op rebuild:** `build_dev` with nothing changed.
- **Flutter hot reload** (Flutter stacks, `ui` edit only): run `flutter run --machine` and time from the file write to the `app.progress` "reloaded" event. Report this alongside the full `build_dev` time; the stack interface's `hot_reload_probe` wraps it.
- **Engine edit to running app** (Flutter stacks): `leaf` edit → native library rebuilt → app restarted to first frame. This is the true cost an agent pays for an engine change when the UI can't hot-reload native code.

### 9.3 Tuned variants

Re-measure §9.1 and §9.2 on the finished code with tuned build configuration. There's no new agent run.

**`rust-tuned`, `rust-flutter-tuned`**

- workspace split so `engine`, `server`, `cli` and `ui` are separate crates
- `mold` (or `wild`) as the linker
- `[profile.dev] debug = "line-tables-only"`
- `[profile.dev.package."*"] opt-level = 2` (dependencies optimized, own crates at 0)
- Cranelift codegen backend for dev builds (nightly, `-Zcodegen-backend=cranelift`), if it builds the project at the pinned toolchain

Record each change's individual contribution if time allows.

**`zig` and `zig-flutter`**

Measure with and without `-fincremental` (`zig build --watch -fincremental`), if the pinned Zig version and target backend support it. Record "unsupported" otherwise.

**Go**

No tuning variant. Record `GOFLAGS` used, if any.

### 9.4 Resource cost per build

`harness/measure.sh <stack> <label> -- <command>` runs the command in a fresh transient cgroup and writes one JSON record:

```bash
systemd-run --user --scope --unit="f2d-$label-$RANDOM" \
  -p CPUAccounting=yes -p MemoryAccounting=yes -p IOAccounting=yes \
  -- <command>
```

It reads the cgroup files when the command exits. Using the cgroup rather than `/usr/bin/time` matters: `time -v` reports the peak RSS of the single largest process, which badly understates a Cargo build running dozens of rustc and linker processes at once.

| Field | Source | What it tells you |
|-------|--------|-------------------|
| `wall_s` | timer | what the agent waits for |
| `cpu_s` | `cpu.stat` `usage_usec` (user + system, whole process tree) | total compute burned; the cost to everyone else on the machine |
| `parallelism` | `cpu_s ÷ wall_s` | effective cores used |
| `mem_peak_mb` | `memory.peak` | peak memory of the whole build tree |
| `swap_peak_mb` | `memory.swap.peak` | whether this build alone pushed into swap |
| `io_write_mb`, `io_read_mb` | `io.stat` | disk churn (debug info and incremental caches show up here) |
| `procs_peak` | max of `cgroup.procs` line count, sampled every 100 ms | how many processes the toolchain fans out to |

The report shows **`cpu_s` per edit** next to wall time. Two stacks with the same wall time can differ several-fold in `cpu_s`, and `cpu_s` is what determines how many agents a machine can carry.

**Cache footprint**

- Size on disk of all build outputs after a cold `build_dev` (`target/`, `.zig-cache/` and the compiled part of the global Zig cache, the Go build-cache delta, Flutter `build/` and `.dart_tool/`).
- Size again after running the `leaf` + `struct` edit cycle 50 times. Incremental caches that grow without bound show up here.

### 9.5 Where build time goes

For one cold `build_dev` and one `struct` edit per stack, break time down into: `deps`, `frontend` (parse, type check, borrow check, sema), `codegen`, `link`, and `tools` (build scripts, binding generators, `wasm-opt`, Flutter tooling). Use each toolchain's own reporting:

| Toolchain | Tool |
|-----------|------|
| Cargo | `cargo build --timings` (per-crate timeline and critical path); on nightly, `-Zself-profile` for one representative crate if the split between frontend and codegen isn't clear from the timeline |
| Go | `go build -debug-actiongraph=ag.json` (per-package compile and link actions with timings) |
| Zig | `zig build --summary all` (per-step times); `--time-report` if the pinned version supports it |
| Flutter | `flutter build <target> -v` log timestamps (Dart kernel compile, native assets/hooks, CMake/Ninja) |
| Any external linker | `harness/shims/link-timer`, a wrapper set as the linker (`-C linker=` for Rust, `CC`/`-extld` for cgo, CMake linker for Flutter) that logs wall time and peak RSS of each link |

Approximate splits are fine. The point is to see whether a stack's slow edit loop comes from compiling, from linking, or from tooling around the compiler.

### 9.6 Multi-agent contention

This simulates several agents working on one machine at once, which a single-build benchmark can't show.

**Setup:** for each stack, make 4 independent copies of the finished repo (separate directories and build outputs, shared download caches). Each copy runs this loop 20 times, all 4 at once, each in its own cgroup:

```
leaf edit → build_check → build_dev → test_all
```

**Configurations**

| Config | Applies to | Setting |
|--------|------------|---------|
| `default` | all stacks | toolchain defaults |
| `bounded` | all stacks | `bounded` from `stack.sh` with `BENCH_JOBS = cores ÷ 4` (Cargo `CARGO_BUILD_JOBS`, Go `go build -p`, Zig `-j`, Flutter/CMake `CMAKE_BUILD_PARALLEL_LEVEL`) |
| `jobserver` | stacks that build with Cargo or Make/CMake | one machine-wide GNU make jobserver with `cores` tokens, shared by all 4 copies (§9.6.1) |
| `jobserver+cgroup` | same | `jobserver` plus `MemoryMax = RAM ÷ 4` and `CPUWeight = 50` on each copy's cgroup |

**Record**

- per-build `wall_s` p50/p95, and the **slowdown factor** against the same build run alone (§9.2)
- total wall time for all 80 iterations
- machine-wide peak memory and swap activity (`pswpin`/`pswpout` deltas from `/proc/vmstat`)
- **pressure stall information:** max and mean `avg10` from `/proc/pressure/cpu`, `/proc/pressure/memory` and `/proc/pressure/io`, sampled every second. Memory and I/O pressure are the best single measure of "the machine is thrashing".
- **responsiveness probe:** a separate process loops `sleep 10 ms` and records how late each wake-up is. Report p99 and max wake-up latency. This is a direct proxy for how the machine feels to a human (or a fifth agent) during the run.

Optionally, run one mixed round with 4 *different* stacks at once to see which stack hurts its neighbors most.

#### 9.6.1 Shared jobserver

`harness/jobserver.sh` creates one GNU make–style jobserver for the whole machine (a FIFO preloaded with `cores − 1` tokens) and exports it as `MAKEFLAGS="-j<cores> --jobserver-auth=fifo:<path>"` (and `CARGO_MAKEFLAGS` with the same value). Cargo and Make honor an inherited jobserver, so every Rust build on the machine draws from one shared pool instead of each claiming every core.

Verify at the start that the pinned Cargo actually honors the FIFO form (watch `procs_peak` with 4 copies running). If it doesn't, fall back to the classic form: run the 4 copies as recipes of a single top-level `make -j<cores>`, which passes a pipe jobserver to its children.

### 9.7 Whole-run accounting

Each agent run (P1, P2, P3) runs inside its own long-lived cgroup:

```bash
systemd-run --user --scope --unit="f2d-agent-<stack>-<phase>" \
  -p CPUAccounting=yes -p MemoryAccounting=yes -p IOAccounting=yes -- <agent command>
```

At the end of the phase, record:

- total CPU-hours, peak memory, total I/O written
- CPU-hours spent in builds (sum of `cpu_s` from builds the agent ran, if they were routed through `measure.sh`) versus everything else

`harness/sample.sh` also writes a 1 Hz time series to `results/<stack>/<phase>_timeseries.csv`:

```
t, cpu_usage_delta_s, memory_current_mb, procs, psi_cpu_avg10, psi_mem_avg10, psi_io_avg10
```

Plotted together, the seven time series show what each stack's dev loop looks like from the machine's point of view: short spikes, long plateaus, or constant background load.

---

## 10. Maintainability

### 10.1 Change request (P2)

From the P2 diff against the P1 tag, record:

- lines added and removed (excluding generated code)
- files touched
- time to green
- failed builds during P2

### 10.2 Review

A fresh agent with no context reviews each codebase. It gets this rubric and the code, and scores 1–5 on each item with a one-line justification:

1. **Structure:** module boundaries, separation of engine, UI and server.
2. **Naming and readability:** could an engineer new to the codebase follow the solver?
3. **Error handling:** model errors propagate cleanly to CLI exit codes, HTTP 422 and UI messages.
4. **Boundary hygiene:** FFI/WASM ownership, lifetimes and threading are explicit and safe; no unchecked `unsafe` or raw pointers outside the boundary module.
5. **Test quality:** unit tests beyond the harness.
6. **Change resilience:** how many places would need to change to add a new load type?

### 10.3 Readability spot-check

You read the skyline factorization and the UI drag handler in each stack and rank them. This is subjective by design, and it's yours.

### 10.4 Bug hunt (P4, optional)

Seed the same logical bug in every stack: flip the sign of `M_j` in the UDL fixed-end forces. A fresh agent receives the failing test output and the instruction "fix the bug". Record time to fix, files read, and whether the fix is the minimal one.

---

## 11. Scorecard

Raw numbers go in `results/SUMMARY.md` via `report.py`. Suggested weights for a single score (adjust before you look at results):

| Category | Weight | Main inputs |
|----------|-------:|-------------|
| Build loop | 20 | §9.2 `build_check` and `build_dev` medians for leaf/struct/no-op, build-wait fraction (§8.1), §9.1 cold |
| Machine cost | 10 | §9.4 `cpu_s` and `mem_peak_mb` per edit, §9.6 slowdown factor and memory pressure in the best configuration, §9.7 CPU-hours per phase |
| Agent handling | 15 | time to green, failed builds, interventions, `stale_api` rate, share of bugs caught late (§8.1) |
| Maintainability | 15 | §10.1, §10.2 |
| Desktop performance | 10 | §8.3 |
| Web performance | 10 | §8.4 |
| Server performance | 10 | §8.5 |
| Binary size | 5 | §8.6 |
| Code size | 5 | §8.2 |

Within each category, normalize each metric to the best stack (best = 1.0, others = best/value or value/best as appropriate) and average.

`SUMMARY.md` should also include, unweighted:

- the §8.1 failure-taxonomy table and "where bugs were caught" chart
- the §9.5 build-time breakdown, one stacked bar per stack
- the §9.6 contention table (slowdown, PSI, wake-up latency) for every configuration
- the §9.7 time-series plots
- the §8.8 boundary, allocation, binary-composition and dependency tables

---

## 12. Environment record (`results/env.md`)

Fill in before P1 starts:

```
Date:
Host: CPU, cores/threads, RAM, OS, kernel
Disk: model/type (affects cold builds)
Agent: model ID, harness, settings
Rust:      rustc / cargo version, nightly date (if used)
Go:        go version
Zig:       zig version
Flutter:   flutter --version (channel, engine hash, Dart version)
Bridge/FFI: flutter_rust_bridge, ffigen, wasm-bindgen versions
UI libs:   egui/eframe, Gio, dvui (commit), Teak (commit, if run)
Server libs: axum, tokio, http.zig (if used), sqlite bindings
Bench tools: hyperfine, oha, scc, bloaty, twiggy, Playwright, Chromium versions
Static server: name + version, brotli settings
Accounting: cgroup v2 confirmed (`stat -fc %T /sys/fs/cgroup` = cgroup2fs), systemd version,
            PSI enabled (/proc/pressure/* present), swap size and swappiness
Linkers:   system ld, lld, mold/wild versions
GNU make:  version (jobserver FIFO support needs 4.4+)
```

---

## 13. Kickoff prompt (per stack)

> You are implementing **Frame2D** in the **`<stack>`** stack, as defined in `SPEC.md` (read it fully first). Work only in `stacks/<stack>/`. Do not read other `stacks/` directories.
>
> Requirements:
> - Implement Phase 1: engine (§4), CLI, server and client (§5), and `stack.sh` (§5.6).
> - Place the `BENCH-EDIT` markers exactly as described in §9.2.
> - You're done when `harness/conformance.py <stack> p1`, `harness/server_conformance.sh <stack>`, and all bench modes (§5.5) run successfully on desktop and web.
> - Keep `AGENT_LOG.md` as described in §8.1.
> - Build and test only through the functions in `stack.sh` (`build_check`, `build_dev`, `test_all`, etc.), wrapped in `harness/measure.sh`, so every build you run is measured with the same flags the harness uses.
> - Allowed dependencies are in §2.3. Write the solver yourself.
>
> Stack-specific choices: `<UI framework>`, `<server framework>`, `<bridge>`.

For P2, the prompt is the §4.7 text plus "make `harness/conformance.py <stack> p2` pass without breaking P1".

For P3 (`go-zig-flutter`): "Profile the solver, then port the engine (§4) to Zig as a static library. Link it into the Go server via cgo with `zig cc` as `CC`, into the Flutter desktop app via dart:ffi, and into the web build as WASM. Remove the Go engine from the client. Keep all conformance passing. Record before/after numbers for §8.3–§8.6 in `AGENT_LOG.md`."

---

## 14. Pre-registered predictions

Write these down before running, then check them against the results. Starting hypotheses:

| Stack | Expected strength | Expected crack |
|-------|-------------------|----------------|
| `rust` | solve speed, server throughput, safety; most bugs caught at compile time | build loop (stock config); highest `cpu_s` and `mem_peak_mb` per edit and worst default contention; egui table and web polish |
| `go` | fastest build loop, lowest `cpu_s` per edit, simplest server | GC pauses in drag p99; large WASM payload, mostly runtime |
| `zig` | smallest binaries and WASM, fast solve, low allocation count | highest `stale_api` rate; most agent turns (std churn, server); UI maturity (text, virtualized table) |
| `rust-flutter` | UI quality, Rust safety in engine | two-toolchain build loop; Flutter web first load |
| `zig-flutter` | cleanest FFI, tiny engine library | Zig server; WASM interop glue on web |
| `go-flutter` | ops simplicity | Go → WASM from Flutter web (size and interop); c-shared on desktop |
| `go-zig-flutter` | best ops + hot-path speed; `zig cc` cross-compile | cgo call overhead on chatty paths; three toolchains |

---

## 15. Machines, runs and tooling decisions

### 15.1 Run identity

Every result set is tagged with a **run id** and a **machine id**, and lives under `results/<run-id>/<machine-id>/`. A run id is the toolchain generation, e.g. `run1`. The exact versions of each toolchain for a run are frozen in `results/<run-id>/versions.md` before P1 starts (§2.2), and each machine records its own `results/<run-id>/<machine-id>/env.md` (§12 template, plus the fields below). Numbers from different machines are never mixed in one comparison table; cross-machine tables compare each stack's ratio to a baseline stack on the same machine.

### 15.2 Machine matrix

| Machine id | OS / arch | Role | Notes |
|------------|-----------|------|-------|
| `win-arm64` | Windows 11, ARM64 (Snapdragon laptop) | **run 1 dev + test machine** | No cgroups/PSI/systemd: §9.4–9.7 are Linux-only (see 15.4) |
| `linux-aarch64` | Linux, aarch64 | planned | Full §9 accounting; also the §8.7 cross-compile target |
| `win-x64` | Windows 11, x86_64 | planned | |
| `linux-x64` | Linux, x86_64 | planned | Full §9 accounting |

Each `env.md` records: CPU model, physical cores / logical threads, RAM, **GPU model and driver version**, disk model and type, OS build (and kernel, on Linux), and power mode (plugged in, performance profile; laptops throttle).

### 15.3 GPU and browser

The GPU matters: egui (wgpu), Gio (GPU rendering), dvui (backend dependent), Flutter (Impeller/Skia) and the browser canvas all draw on it, so `drag`/`render` frame times depend on it. Record the GPU and driver per machine, and state in each desktop result which renderer was active (hardware or software).

Web measurements use **Chromium via Playwright** on every machine, so the browser build is identical wherever Playwright publishes one. Record: Playwright version, Chromium build number (`browser.version()`), launch flags, and the GPU/WebGL/WebGPU status from `chrome://gpu` (headless Chromium can silently fall back to software rendering). Use the same flags on every machine. Only if a Playwright Chromium isn't published for a platform, use the system Chrome and record its build number.

### 15.4 Windows and the Linux-only sections

§9.4 (per-build cgroups), §9.6 (contention, PSI) and §9.7 (whole-run accounting) need cgroup v2, systemd and `/proc/pressure`. On Windows machines these are skipped, except that `measure.sh` may report `wall_s` and peak working set via a Job Object where practical. The Windows results cover build wall times, runtime, binary size and code size; the machine-cost category is scored on Linux machines only.

### 15.5 Browser tooling for agents

- **Benchmarks and conformance in the browser:** Playwright + Chromium (pinned, headless). It's cross-platform, reads `console.log` `BENCH` lines, and pins the browser build.
- **Interactive diagnostics while building:** any browser tool the agent has (a built-in browser pane or Claude in Chrome) is fine for looking at the UI, but its numbers never go in results.
- **Not used:** Lightpanda and other non-rendering headless browsers. There's no canvas, WebGL or real frame pacing, so `drag`/`render` can't be measured.

### 15.6 UI framework fallback (Zig)

Before the `zig` P1 run, a time-boxed smoke test (about 2 hours, throwaway code, not scored) checks dvui at the pinned Zig version on the run's machine: open a window, draw a pannable/zoomable canvas, show a virtualized scrolling list, and build to WASM. If dvui passes, the baseline is dvui.

If it fails, record why in `results/<run-id>/versions.md` and fall back in this order: **Teak** (pure Zig, labeled `zig-teak`), then **Dear ImGui via cimgui** (labeled `zig-imgui`, not pure Zig). The fallback run is reported as a deviation from §1 and is never silently merged with a dvui result. Where dvui works, `zig-teak` may still run as the optional extra stack.

**Teak as the baseline (dogfooding).** If Teak is used, it may be fixed and extended along the way and new Teak releases cut, but it is not the point of the bake-off. Rules: pin the run to a Teak release tag (or commit) recorded in `versions.md`; Teak changes stay minimal and only unblock Frame2D; time spent on Teak work (not on Frame2D) is logged separately in `AGENT_LOG.md` and excluded from the stack's agent-handling and build-loop numbers, but the extra lines of Teak code are reported, not hidden.

If the `zig-imgui` fallback needs Emscripten for its web build, that counts as the §2.12 deviation and is one more reason to prefer Teak.

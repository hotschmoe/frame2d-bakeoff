# Review: rust (SPEC 10.2)

| Item | Score | Justification |
|---|---|---|
| Structure | 4 | Clean lib/bin split: model.rs, engine.rs (no UI/IO deps), generator.rs, alloc_count.rs, feature-gated app/, thin bins; engine.rs is one 815-line file mixing validation, RCM, skyline, element math and post-processing. |
| Naming | 4 | SPEC-aligned section banners and doc comments (prepare, rcm, bfs_levels, column_tops, Skyline::factor, condense, solve_case); terse names and dense factor indexing cost some effort. |
| Errors | 4 | ModelError codes flow to CLI exit 2 (Failure::Model), HTTP 422 (ApiError::Model) and UI red status (run_solve, Io::parse); malformed JSON is 400/exit 1, unknown `only` case silently gives empty results. |
| Boundary | 4 | No FFI; unsafe limited to the GlobalAlloc wrapper (alloc_count.rs) and one commented Win32 call (app/bench.rs); server threading explicit (spawn_blocking, thread::scope, atomic counter, per-slot Mutex). |
| Tests | 2 | Only 5 unit tests, all in engine.rs; no tests for springs, releases, auto-restrain, zero_length, duplicate_id, no_free_dofs, RCM components, server, CLI, generator. |
| Change resilience | 3 | New load type: engine changes concentrated in one file but UDL is hard-coded in several spots of solve_case plus fixed_end. |

## Load-type touch points
- src/model.rs:LoadCase (new field + struct)
- src/engine.rs:CaseData
- src/engine.rs:prepare
- src/engine.rs:fixed_end
- src/engine.rs:solve_case (load vector)
- src/engine.rs:solve_case (end forces / stations)
- src/engine.rs:solve_case (equilibrium sums)
- src/generator.rs:generate (optional)
- src/app/canvas.rs:draw_scene (optional; loads not drawn today)
- new tests

## Generated / excluded
target/ (incl. bindgen.rs), Cargo.lock, frame2d.db

## Notable
- Strength: engine is UI/IO-free with SPEC-aligned sections; BENCH-EDIT:leaf marker present.
- Strength: ModelError carries SPEC codes end to end; ApiError maps 422/400/404/500; spawn_blocking and scoped-thread sweep.
- Risk: thin test coverage (5 tests, one file).
- Risk: unknown `only` case returns empty Ok; malformed JSON is 400/exit 1; several unwrap/expect in the server.
- Risk: UDL logic repeated in solve_case and fixed_end; drag re-runs full prepare/RCM per frame on the UI thread.

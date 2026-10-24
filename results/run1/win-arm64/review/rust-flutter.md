# rust-flutter review (SPEC 10.2)

| Item | Score | Justification |
|---|---|---|
| Structure | 5 | Workspace split engine / cli / server / bridge; engine has no I/O; Dart engine/state/ui with native+web impls behind one `Engine` interface. |
| Naming and readability | 4 | Small documented modules (skyline.rs, topology.rs); `solve_case` in analysis.rs is long and index-arithmetic heavy. |
| Error handling | 4 | `ModelError` -> CLI exit 2 JSON, HTTP 422 (`ApiError::Model`), `code|detail` -> `EngineError.from` -> UI banner; malformed JSON in CLI is exit 1, string parsing brittle, failed drag solve leaves bad node position. |
| Boundary hygiene | 4 | Only unsafe is the counting allocator in cli/alloc.rs; single plain-Rust api.rs wrapped by FRB and wasm-bindgen, owned flat copies, Mutex session with poison handling, web views freed; unchecked i64->i32 / u64->u32 casts, global singleton. |
| Test quality | 3 | Good engine closed-form/RCM/skyline-vs-dense tests, bridge lifecycle, sweep tests; releases/springs/condense untested, Dart tests thin. |
| Change resilience | 2 | New load type touches ~10-13 places (below). |

## Load-type touch points
- crates/engine/src/model.rs: LoadCase
- crates/engine/src/topology.rs: Topology::build (reference validation)
- crates/engine/src/analysis.rs: solve_case (rhs, end forces, equilibrium), CaseResult
- crates/bridge/src/api.rs: ModelView / model_view
- crates/bridge/src/web.rs: js_view!(ModelView)
- crates/bridge/src/frb_generated.rs + app/lib/generated/*: regenerate
- app/lib/engine/engine.dart: ModelData; engine_native.dart: _model; engine_web.dart: _ModelView/_model
- app/lib/ui/scene.dart: load drawing
- crates/server/src/sweep.rs (only if varied)

## Generated / excluded
frb_generated.rs, app/lib/generated/*.dart, app/web/engine/frame2d_engine.js and .wasm, .idea, .metadata, lockfiles, frame2d.db*.

## Notable
- Topology separated from coordinates/loads, so drag re-solves skip RCM and layout.
- output.rs streams stations from end forces; one ModelError type shared by CLI/server/bridge.
- Risk: engine_move_and_solve commits the new node position before solving; zero_length/unstable leaves it in the session.
- Risk: unchecked id/profile narrowing casts at the boundary; global Mutex session singleton.
- Risk: store.rs `Mutex::unwrap`; no numeric tests for releases/springs.

# Review: go

| item | score | justification |
|---|---|---|
| structure | 4 | Clean split: engine/ (model, rcm, solve, gen) as a pure library consumed by cmd/frame2d, cmd/server and cmd/app; solve.go at 766 lines mixes validation, numbering, skyline, loads and post-processing in one file. |
| naming | 4 | Doc-commented functions with SPEC section refs (prepare, numberDOFs, heights, condense, factor, buildLoads, postProcess) make the pipeline in Analyze easy to follow; skyline indexing in at()/factor() is terse and the 100-line postProcess is dense. |
| errors | 4 | Typed engine.ModelError with SPEC codes maps to exit 2 (cmd/frame2d run), HTTP 422 (server fail) and UI status text (state.solve); gaps: JSON syntax/unknown OnlyCase errors are not model errors, sweep model_id parse/lookup errors collapse to 404, and sweep does not bound 'variants'. |
| boundary | 4 | No FFI or unsafe: UI calls the engine in-process; the server shares one *sql.DB (MaxOpenConns 1) and sweep workers write disjoint slice slots with a mutex only for firstErr; js.FuncOf callbacks in platform_js.go openFile are never Released and the select-with-default silently drops a second file. |
| tests | 2 | Only engine/engine_test.go (6 tests: closed-form cantilever and fixed-fixed UDL, profile 10x10, error codes, OnlyCase, a weak RCM permutation check); no tests for springs, releases, auto-restraint, server handlers, CLI exit codes or the UI. |
| change_resilience | 3 | A new load type touches the Model JSON types, validation, load assembly, fixed-end forces, equilibrium residual, station diagrams and the canvas; Solution carries only a scalar per-member W, so the pipeline is hard-wired to UDL. |

## Load type touch points
- engine/model.go:LoadCase (new JSON field and type)
- engine/solve.go:prepare (reference validation loop over load cases)
- engine/solve.go:buildLoads (free-DOF load vector / equivalent nodal loads)
- engine/solve.go:fixedEndLocal and memberFixedEnd (member fixed-end forces, release condensation)
- engine/solve.go:postProcess (end forces include fixed-end terms; equilibrium residual add() resultants)
- engine/solve.go:CaseSolution.W and StationAt (station N/V/M for the load shape)
- engine/solve.go:Solution.Results (output shaping if stations change)
- cmd/app/canvas.go:moment diagram drawing via cs.W[k] (and load glyph drawing if added)
- cmd/server/main.go:solveVariant (only if sweeps must scale it)
- engine/gen.go:Generate (only if generated models should use it)

## Generated/excluded
- build/ (not read)
- go.sum (dependency lockfile, not read)

## Notable
- Strength: Analyze factors once and reuses the skyline for all cases, and dot/axpy are unrolled with bounds-check hints; the algorithm tracks SPEC 4.4 closely and tests pin profile 10221/7575/330.
- Strength: single ModelError type and errors.As in both CLI and server give consistent exit-2/HTTP-422 mapping; pivot tolerance sits on a BENCH-EDIT:leaf line.
- Risk: Analyze with OnlyCase naming an unknown case silently returns a Solution with zero cases (selectCases returns nil), no error; state.current() then falls back or returns nil.
- Risk: server sweep has no cap on 'variants' (allocates n variants and an unbuffered job loop) and a body JSON error returns 400 while an unknown model_id parse error path differs; sweep envelope max_roof_drift_W uses signed drift, not abs.
- Weakness: thin tests (no release/spring/auto-restraint/server/CLI tests), so SPEC 4.7 code (condense, zeroRotations) is covered only by external conformance; also ui/state share mutable engine.Model sorted in place by setModel.

# Review: go-flutter

| Item | Score | Justification |
|---|---|---|
| structure | 4 | Clean layering: engine/ (model, prepare, rcm, solve, sweep) has no I/O; bridge/session is the single marshalling layer shared by bridge/native (cgo) and bridge/wasm; cmd/frame2d and cmd/server are thin; Dart hides FFI/WASM behind engine/engine.dart with conditional imports. |
| naming | 3 | Short comments reference SPEC sections and names like Prepared/skyline/colPtr/top are sensible, but Prepare is one ~120-line function, SolveCase is a ~200-line function mixing assembly, load vector, post-processing and equilibrium, and factor/localK use terse single-letter indices with inline 6x6 rotation arithmetic. |
| errors | 3 | ModelError{Code,Detail} flows cleanly to CLI exit 2 (cmd/frame2d fail), HTTP 422 (cmd/server replyErr) and the UI banner (home.dart _errorBanner via f2d_last_error), but session.ErrCode omits support_conflict (falls to -1), Session.Solve silently coerces a bad case index to 0, SetNode silently ignores a bad index, and non-model JSON errors lose the code. |
| boundary | 3 | Pinned Go buffers with a documented lifetime and Dart zero-copy views are deliberate, and the unsafe code stays in bridge/native and bridge/wasm, but f2d_last_error/f2d_geometry/f2d_result return raw pointers with no length or null checks on the Dart side (asTypedList on a null pointer for a stale handle), Free unpins memory Dart may still view, and Session state plus global lastErr are unsynchronized (only the map has a mutex). |
| tests | 2 | Small but real engine tests (engine_test.go: cantilever closed form, gen 10x10 profile 7575, five error codes, sweep monotonicity), plus session_test.go and two Dart state tests with a fake engine; no tests for springs, releases/auto-restraint, RCM in isolation, UDL fixed-end forces, CLI exit codes, the HTTP server, or the FFI/WASM layers. |
| change_resilience | 3 | A new load type (e.g. trapezoid or thermal member load) touches about 7 places in Go: LoadCase struct, preparedCase, Prepare load loop, SolveCase load-vector/fixed-end block, equilibrium sum, Stations, and the per-case copy in session.Solve; the Dart UI needs no change since it only reads flat result buffers, so the blast radius is mostly confined to engine/. |

## Load type touch points
- engine/model.go:LoadCase (new JSON field and type)
- engine/prepare.go:preparedCase (store per-case data)
- engine/prepare.go:Prepare (validate refs, accumulate loads)
- engine/solve.go:fixedEnd/fixedEndM (equivalent nodal forces)
- engine/solve.go:SolveCase (load vector, end forces ffix)
- engine/solve.go:SolveCase equilibrium block (resultant sum)
- engine/solve.go:Stations (N/V/M diagram contributions)

## Generated/excluded
- app/lib/generated/engine_bindings.dart (ffigen output)
- app/ffigen/frame2d_engine.h and build/frame2d_engine.h (cgo-generated header)
- app/build/, app/windows/ (flutter create runner, ephemeral), app/web/icons, app/.idea, app/.dart_tool
- app/lib/ui/canvas_view.dart, member_table.dart, home.dart, bench.dart only skimmed

## Notable
- Strength: Prepare/solve split lets drag-edit reuse topology and RCM (SetCoord + SolveCase), and Sweep reuses engine code across NumCPU goroutines with per-variant Prepared state.
- Strength: single session package serves both cgo and wasm bridges, so the C ABI and JS API stay in step; flat float64 buffers keep the boundary simple.
- Risk: session.ErrCode has no case for support_conflict, so spring/support conflicts reach the UI as generic code -1 (message still shown via last_error).
- Risk: Session fields and global lastErr have no locking; native f2d_* calls from multiple threads or a stale handle after Free (Dart still holds a view of unpinned memory) are unsafe.
- Weakness: server and CLI have no tests; engine tests skip releases, springs and UDL fixed-end forces; also Sweep reports bad variants count as invalid_ref (misleading code) and the sweepReq field is misspelled BeamIScle.

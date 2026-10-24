# Code review: zig (run1, win-arm64)

| Item | Score | Justification |
|---|---|---|
| Structure | 4 | OS-free engine (engine/solver/model/report) shared by cli, server and UI; store.zig and platform.zig isolate SQLite and web/native glue. |
| Naming and readability | 3 | Good helper names and doc comments, but `solver.zig:solve()` is ~230 lines and Geometry fields are terse (mi, mj, ea, ei, c, s). |
| Error handling | 4 | `ErrorInfo`/`Code` flows to CLI exit 2, HTTP 422 (`respondModelError`) and UI text (`state.zig setError`); small gaps (silent exit 1 on bad JSON/args, `.?` lookups relying on prior validation). |
| Boundary hygiene | 4 | Unsafe confined to store.zig SQLite externs (transient binds, serialized mode, finalize via defer) and small wasm exports; threads share only App/gpa/store; globals `clock_ns`, `g_io`. |
| Test quality | 2 | Three Zig tests only (F01 cantilever, unstable beam, generator sizes); no unit tests for RCM, skyline, condensation, springs, store. |
| Change resilience | 3 | New load type touches ~7 places; nodal/UDL logic is repeated in `solve()` for rhs, reactions and residual. |

## Load-type touch points
model.zig LoadCase, write, generate; solver.zig buildGeometry (validation), solve (rhs; reactions/residual), station/maxAbsM; report.zig writeResults; canvas.zig draw; sweep.zig run.

## Generated or excluded
zig-pkg/, .zig-cache/, .zig-global/, zig-out/, SQLite amalgamation (fetched).

## Notable
- Engine is pure Zig with an injectable clock (`solver.clock_ns`); same engine for CLI, server, wasm.
- One error type maps to exit code 2, 422 and UI text.
- `solve()` is one ~230-line function with duplicated load loops.
- Only three unit tests; internals rely on harness fixtures.
- `respondError` interpolates detail into JSON unescaped (static strings today); malformed JSON gives 400 while model errors give 422.

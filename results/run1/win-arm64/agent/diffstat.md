# Change request metrics (SPEC 10.1)

P2 = diff `p1-done-<stack>..p2-done-<stack>` restricted to `stacks/<stack>/`; go-zig-flutter row is P3 (`fork-go-zig-flutter..p3-done-go-zig-flutter`).
Excluded from counts: the stack's `LOC_EXCLUDE`, generic generated patterns (*frb_generated*, *.g.dart, *.freezed.dart, *engine_bindings*.dart, */generated/*, generated/*, *.lock, go.sum, pubspec.lock, Cargo.lock, */ffigen/*, ffigen/*, .tools/*, *.png, *.ico, *.jpg), and `AGENT_LOG.md`. Raw git numstat totals are shown in the last columns.
Time to green = agent transcript wall time, stall-corrected (raw in brackets). Failed builds = failed build/check commands in that phase (metrics.py heuristics).

| stack | phase | lines added | lines removed | files touched | time to green | failed builds / builds | failed tests | failed conformance | excluded files | raw +/- (all files) |
|---|---|---|---|---|---|---|---|---|---|---|
| rust | P2 | 147 | 13 | 3 | 1.9 min (raw 1.9) | 1 / 4 | 0 | 0 | 0 | +156/-13 (4 files) |
| zig | P2 | 162 | 12 | 3 | 1.7 min (raw 1.7) | 1 / 3 | 0 | 0 | 0 | +170/-12 (4 files) |
| go | P2 | 158 | 18 | 2 | 1.1 min (raw 1.1) | 0 / 1 | 0 | 0 | 0 | +169/-18 (3 files) |
| rust-flutter | P2 | 158 | 6 | 5 | 2.1 min (raw 2.1) | 1 / 2 | 0 | 0 | 0 | +167/-6 (6 files) |
| zig-flutter | P2 | 195 | 14 | 4 | 3.0 min (raw 3.0) | 1 / 3 | 0 | 0 | 0 | +204/-14 (5 files) |
| go-flutter | P2 | 137 | 17 | 3 | 1.6 min (raw 1.6) | 0 / 3 | 0 | 0 | 0 | +146/-17 (4 files) |
| go-zig-flutter | P3 | 3096 | 1938 | 35 | 47.3 min (raw 436.9) | 2 / 10 | 0 | 0 | 3 | +3480/-2140 (39 files) |

## Files touched

- **rust P2**: src/engine.rs (+120/-12), src/generator.rs (+2/-1), src/model.rs (+25/-0)
- **zig P2**: src/model.zig (+23/-2), src/report.zig (+6/-1), src/solver.zig (+133/-9)
- **go P2**: engine/model.go (+27/-10), engine/solve.go (+131/-8)
- **rust-flutter P2**: crates/engine/src/analysis.rs (+73/-6), crates/engine/src/generate.rs (+2/-0), crates/engine/src/model.rs (+39/-0), crates/engine/src/topology.rs (+43/-0), crates/engine/tests/engine.rs (+1/-0)
- **zig-flutter P2**: src/engine/model.zig (+5/-0), src/engine/model_json.zig (+60/-5), src/engine/results_json.zig (+6/-1), src/engine/solver.zig (+124/-8)
- **go-flutter P2**: engine/model.go (+27/-10), engine/prepare.go (+50/-1), engine/solve.go (+60/-6)
- **go-zig-flutter P3**: .gitignore (+2/-0), app/ffigen.yaml (+1/-1), app/lib/app_state.dart (+1/-1), app/lib/engine/engine.dart (+3/-3), app/lib/engine/engine_ffi.dart (+1/-1), app/lib/engine/engine_web.dart (+1/-1), app/lib/io/platform_io.dart (+1/-1), app/web/f2d_loader.js (+65/-12), bridge/native/main.go (+0/-127), bridge/native/proc_other.go (+0/-5), bridge/native/proc_windows.go (+0/-19), bridge/session/session.go (+0/-259), bridge/session/session_test.go (+0/-55), bridge/wasm/main.go (+0/-53), bridge/zig/zig.go (+255/-0), bridge/zig/zig_test.go (+73/-0), cmd/frame2d/main.go (+21/-101), cmd/server/main.go (+51/-24), engine/engine_test.go (+0/-102), engine/gen.go (+0/-40), engine/model.go (+0/-174), engine/prepare.go (+0/-256), engine/rcm.go (+0/-127), engine/solve.go (+0/-409), engine/sweep.go (+0/-113), stack.sh (+102/-54), zig/include/frame2d_engine.h (+46/-0), zig/src/engine.zig (+874/-0), zig/src/json.zig (+195/-0), zig/src/lib.zig (+362/-0), zig/src/model.zig (+372/-0), zig/src/results.zig (+205/-0), zig/src/session.zig (+139/-0), zig/src/tests.zig (+160/-0), zig/src/util.zig (+166/-0)
  - excluded as generated/non-code: app/ffigen/frame2d_engine.h (+22/-79), app/lib/generated/engine_bindings.dart (+259/-122), app/web/index.html (+0/-1)

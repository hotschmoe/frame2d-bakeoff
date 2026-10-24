# frame2d-bakeoff

A language-stack bake-off. One fixed app, **Frame2D** (an interactive 2D frame analyzer using the direct stiffness method), built by AI agents once per stack, to put real numbers behind future technology choices: build-loop time, machine cost, agent friction, code size, maintainability, desktop/web/server performance and binary size.

The full definition is in [SPEC.md](SPEC.md).

## Stacks

| ID | Stack |
|----|-------|
| `rust` | Rust, egui/eframe, axum |
| `go` | Go, Gio, net/http |
| `zig` | Zig, dvui |
| `rust-flutter` | Rust engine + Flutter |
| `zig-flutter` | Zig engine + Flutter |
| `go-flutter` | Go engine + Flutter |
| `go-zig-flutter` | Go server, Zig engine, Flutter (forked from `go-flutter` after P2) |

## Layout

- `fixtures/`: conformance fixtures (P1, P2) and golden results
- `harness/`: conformance, build/runtime/web benchmarks, accounting
- `stacks/<stack>/`: one directory per stack, each with a `stack.sh`
- `results/`: `env.md` and per-stack metric JSON

## Status

Scaffold only. Next: fixtures, harness, and `results/env.md`, all before any stack run starts.

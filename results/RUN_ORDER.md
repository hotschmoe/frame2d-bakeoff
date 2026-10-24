# Run order

Shuffled with Python `random.Random(1814947984)` on 2026-10-24 (SPEC 2.1). `go-zig-flutter` is always last: it forks from `go-flutter` after P2.

1. `zig-flutter`
2. `zig`
3. `rust`
4. `rust-flutter`
5. `go-flutter`
6. `go`
7. `go-zig-flutter`

Committed before any stack run starts. Do not reorder; if a run is repeated, record it as a rerun, not a new position.

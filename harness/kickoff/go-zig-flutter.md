# Kickoff prompts: `go-zig-flutter`

This stack has no P1. It is forked from the finished `go-flutter` repo after that stack's P2 (SPEC 1, 3): copy `stacks/go-flutter/` to `stacks/go-zig-flutter/`, tag it, then run P3.

## P3 prompt

> Profile the solver, then port the engine (§4) to Zig as a static library. Link it into the Go server via cgo with `zig cc` as `CC`, into the Flutter desktop app via dart:ffi, and into the web build as WASM. Remove the Go engine from the client. Keep all conformance passing. Record before/after numbers for §8.3–§8.6 in `AGENT_LOG.md`.
>
> Work only in `stacks/go-zig-flutter/`. Build and test only through `stack.sh`, wrapped in `harness/measure.sh`. No Emscripten unless absolutely needed (§2.12).

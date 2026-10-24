# run1 toolchain versions (frozen)

Frozen on 2026-10-24 for run1 (SPEC 2.2). No toolchain upgrades mid-run. Full machine detail: `win-arm64/env.md`.
PATH ordering for these pins is set by `harness/machine-env.sh` (`f2d_check_pins` warns if Zig is not 0.17.0).

| Tool | Version | Notes |
|------|---------|-------|
| Rust | rustc / cargo 1.99.1 (58cf8f9c3 2026-10-13), rustup 1.29.2 | host `aarch64-pc-windows-msvc`; targets add `wasm32-unknown-unknown`; no nightly |
| Go | 1.27.0 windows/arm64 | `js/wasm` supported |
| Zig | **0.17.0** (official aarch64-windows) | includes the Windows ARM64 fix. The self-patched 0.16.0 at `C:\zig\aarch64-patched` is NOT used |
| Flutter | 3.47.8 stable, framework 737ba8f885, engine cf636b1dfb | Dart 3.13.7, DevTools 2.60.0; Dart and engine run as x64 under emulation on this machine |
| flutter_rust_bridge_codegen | 2.13.0 | 2.14.0-beta.2 exists, not used |
| wasm-bindgen / -cli | 0.2.129 | |
| wasm-pack / wasm-opt (binaryen) | 0.15.0 / version_133 | |
| ffigen | per project | latest on pub.dev is 23.0.0 |
| dvui | pinned at P1 start | main requires Zig 0.17.0 (`minimum_zig_version`); record the commit when the smoke test (SPEC 15.6) passes |
| Teak | pinned only if used | pin release tag/commit here. Teak targets Zig 0.16, see hotschmoe/teak#131 |
| Playwright / Chromium | 1.64.1 / 156.0.8078.4 | Chromium is x64 (emulated) on ARM64 Windows |
| hyperfine / oha / scc / brotli | 2.0.0 / 1.16.0 / 4.1.0 / 1.2.1 | |
| Node | 24.22.1 | |
| Python | 3.12.10 (arm64) | psutil installed for `measure_fallback.py` |
| MSVC Build Tools | 17.14.35 (toolset 14.44.35207) | |
| LLVM | 22.1.8 | `ring`-based cargo builds need clang on PATH |

## Not available on win-arm64

GNU make 4.4+ (jobserver), bloaty, mold/wild, and all cgroup/PSI tooling. Machine-cost results come from the Linux machines (SPEC 15.4).

## Known comparability caveats

- Flutter stacks build x64 Windows desktop apps under emulation on this machine; pure stacks build native ARM64. Do not compare Flutter-stack and pure-stack desktop numbers directly from this machine.
- Chromium is x64 emulated here, so web numbers from win-arm64 are indicative only.

# Environment record: Windows 11 x86_64 desktop (SPEC.md section 12, 15.2 `win-x64`)

Date: 2026-10-27
Scope: build-loop only (SPEC 9.1 cold, 9.2 edits) with the run1p5 reduced protocol
(`harness/buildloop/run.sh <stack> cold edits --cold-runs 2 --runs 3 --warmup 1`). No runtime/web/server benches,
no hot reload / engine sections (they open app windows), no agent runs. Stack code is the repo HEAD (P5 state).

## Host

```
Host:   ASRock B860I Lightning WiFi (mini-ITX desktop), Intel Core Ultra 7 270K Plus,
        24 cores / 24 threads (no SMT), 31.4 GiB RAM
OS:     Windows 11 Pro 10.0.26300 (x64)
Disk:   Samsung SSD 990 PRO 1TB, NVMe
GPU:    Intel Arc Pro B50 (driver 32.0.101.8976) + Intel iGPU (driver 32.0.101.5869)
Power:  desktop, mains; power plan "High performance"
AV:     Windows Defender real-time protection ON, no exclusions, deliberately (human decision 2026-10-27:
        measure the default Windows dev environment most users have). Not recorded on win-arm64.
DevMode: Windows Developer Mode ON (enabled 2026-10-27, required by Flutter plugin symlinks)
Agent:  Claude Code (Opus 5.5), setup + campaign only
```

## Toolchains (run1p5 pins, all native x64)

| Tool | Version | Notes |
|---|---|---|
| Rust | rustc / cargo 1.99.1 (58cf8f9c3 2026-10-13), rustup 1.29.0 | host x86_64-pc-windows-msvc; + wasm32-unknown-unknown. A Rust 1.96 MSI install is also on PATH; machine-env.sh puts ~/.cargo/bin first |
| Go | 1.27.0 windows/amd64 | winget GoLang.Go |
| Zig | 0.17.0 x86_64-windows | winget zig.zig; package dir put on PATH by machine-env.sh (no WinGet Links shim) |
| Flutter | 3.47.8 stable, Dart 3.13.7 | zip SDK at ~/dev/flutter; native x64 (no emulation, unlike win-arm64) |
| flutter_rust_bridge_codegen | 2.13.0 | cargo install --locked |
| wasm-bindgen / -cli | 0.2.129 | |
| wasm-pack / wasm-opt (binaryen) | 0.15.0 / version_133 | binaryen x86_64-windows tarball at ~/dev/tools/binaryen |
| hyperfine / oha / scc / brotli | 2.0.0 / 1.16.0 / 4.1.0 / 1.2.0 | |
| Node | 24.22.1 | |
| Python | 3.12.10 (x64) + psutil 7.2.2 | 3.11 also installed; machine-env.sh puts 3.12 first |
| MSVC Build Tools | 2022 17.14.37328.6 (toolset 14.44.35207), Windows SDK 10.0.26100.0 | same toolset as win-arm64 |
| LLVM | 22.1.8 | |

## Notes

- `harness/machine-env.sh` now sets `F2D_MACHINE_ID=win-x64` when `PROCESSOR_ARCHITECTURE=AMD64` and adds the winget package dirs
  for zig/hyperfine/oha and Python 3.12 to PATH.
- Flutter Windows builds of stacks that use plugins (zig-flutter, rust-flutter) need Developer Mode (symlink support).
  go-flutter and go-zig-flutter build without it.
- All downloads (crates, Go modules, zig packages, pub packages, Flutter engine artifacts) were primed with one build of every
  target before measuring; logs in `_prime/`.
- **Defender blocks `go` `build_server_release` on every clean build**: it quarantines the freshly linked
  `%TEMP%\go-build*\b001\exe\a.out.exe` as `Behavior:Win32/DefenseEvasion.A!ml` (ML false positive), so `go build` fails.
  Reproduced twice (campaign 14:12, rerun 14:22); records in `_logs/`. go-flutter and go-zig-flutter servers were not flagged.
  The human then added ONE Defender path exclusion, `%TEMP%\go-build*`, and only `go cold --cold-targets server` was rerun with it
  (first run 32.7 s one-off scan stall, then 6.6-6.8 s; the kept record is the final 2-run rerun). Every other measurement in
  this directory ran with no exclusions. See SUMMARY.md footnote [1].
- Windows accounting limits are the same as win-arm64: psutil-sampled `cpu_s`/`mem_peak_mb` (50 ms), no io/swap, no cgroups.

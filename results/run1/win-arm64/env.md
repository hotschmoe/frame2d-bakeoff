# Environment record: Windows 11 ARM64 laptop (SPEC.md section 12)

Date: 2026-10-23
Note: SPEC assumes Linux. This machine is a Windows dev/sanity box; cgroup/PSI/systemd accounting is not available natively (see "Unavailable on Windows").

## Host

```
Host:   ASUS Zenbook A16 UX3607OA, Snapdragon X2 Elite Extreme (X2E94100), Qualcomm Oryon CPU,
        18 cores / 18 threads (no SMT), 47.6 GiB RAM
OS:     Windows 11 Home, 10.0.28000 (ARM 64-bit); flutter reports 10.0.28000.3231 / "26H1"
Disk:   SAMSUNG MZVL81T0HFLB-00BTW, NVMe SSD (~1 TB class)
GPU:    Qualcomm Adreno X2-90, driver 32.0.172.1 (2026-08-26)
NPU:    Qualcomm Hexagon NPU driver 1.2.4667.8400 (not relevant)
Browsers installed: Chrome 155.0.8059.85 (winget has 156.0.8078.48, not upgraded - user browser),
        Edge 156.0.4314.42 (flutter doctor sees Edge 155.0.4283.62)
WSL:    present but no distro installed
Agent:  (fill in at run time)
```

## Toolchains

```
Rust:      rustc 1.99.1 (58cf8f9c3 2026-10-13), cargo 1.99.1, rustup 1.29.2
           host aarch64-pc-windows-msvc; targets: aarch64-pc-windows-msvc, wasm32-unknown-unknown
           nightly: none installed
Go:        go1.27.0 windows/arm64 (GOARCH=arm64); js/wasm listed in `go tool dist list`
Zig:       0.17.0 (official aarch64-windows zip via winget, ziglang.org, released 2026-10-02)
           -> %LOCALAPPDATA%\Microsoft\WinGet\Links\zig.exe
           ALSO on PATH first: C:\zig\aarch64-patched\zig.exe = 0.16.0 (self-patched ARM64 build);
           C:\zig\x86_64-prism\zig.exe = upstream 0.16.0 x64 under Prism (via zig86.cmd).
           PATH was NOT modified: bare `zig` still resolves to the patched 0.16.0. Use the full
           WinGet\Links path, or reorder PATH, to get 0.17.0.
           Latest stable = 0.17.0. dvui main build.zig.zon: minimum_zig_version = "0.17.0" (dvui 0.6.0-dev).
           => latest stable == dvui-required. (dvui releases/tags pinned to older Zig were not checked.)
Flutter:   3.47.8, channel stable, framework 737ba8f885 (2026-10-22), engine cf636b1dfb
           (engine hash dfd2e6cb7d319db05e3bf1503f3e2ac60f6288a2), Dart 3.13.7, DevTools 2.60.0
           installed via git clone -b stable to C:\Users\hotschmoe\dev\flutter (NOT on PATH)
           Dart SDK and Flutter engine artifacts are windows_x64 -> run under x64 emulation (no ARM64 Windows Flutter SDK).
           Windows desktop target: enabled (builds windows-x64 only); web: enabled; `flutter build web --wasm` supported.
           doctor: only Android toolchain missing (not needed). VS Build Tools 2022 17.14 + Win10 SDK 26100 OK.
Bridge/FFI: flutter_rust_bridge_codegen 2.13.0 (latest stable; 2.14.0-beta.2 exists), wasm-bindgen / -cli 0.2.129,
           wasm-pack 0.15.0 (cargo-installed; old broken npm wasm-pack shim still shadows it, see notes),
           wasm-opt (binaryen) version_133 native arm64-windows at C:\Users\hotschmoe\dev\tools\binaryen\binaryen-version_133\bin,
           cargo-binstall 1.26.0, twiggy 0.8.0, ffigen (pub.dev) latest 23.0.0 (not installed; per-project dev dep)
UI libs:   (per project) egui/eframe, Gio, dvui (commit), Teak
Server libs: (per project)
Bench tools: hyperfine 2.0.0, oha 1.16.0, scc 4.1.0, bloaty N/A, twiggy 0.8.0,
           Playwright 1.64.1 (npm, at C:\Users\hotschmoe\dev\tools\playwright), Chromium 156.0.8078.4 (chromium-1248)
Static server: not chosen/installed
Accounting: N/A on Windows (no cgroup v2, systemd, /proc/pressure). Windows equivalents would be Job Objects/perf counters.
Linkers:   MSVC link.exe (VS Build Tools 2022 17.14, toolset 14.44.35207); LLVM 22.1.8 clang + lld-link at C:\Program Files\LLVM\bin (not on PATH);
           mold/wild: N/A (Linux/macOS only); system ld: N/A
GNU make:  NOT INSTALLED. winget only offers GnuWin32.Make 3.81 (< 4.4 needed for jobserver FIFO). Not installed.
```

## Version table

| Tool | Before | Now | Latest stable | Arch | Notes |
|---|---|---|---|---|---|
| rustup | 1.29.0 | 1.29.2 | 1.29.2 | native arm64 | |
| rustc / cargo | 1.96.0 | 1.99.1 | 1.99.1 | native arm64 | host aarch64-pc-windows-msvc |
| wasm32-unknown-unknown | installed | installed | n/a | n/a | no nightly present, none installed |
| Go | missing | 1.27.0 | 1.27.0 | native arm64 | windows/arm64; js/wasm supported |
| Zig (winget) | missing | 0.17.0 | 0.17.0 | native arm64 | official aarch64-windows build; includes ARM64 fix |
| Zig (C:\zig\aarch64-patched) | 0.16.0 | 0.16.0 | - | native arm64 (self-patched) | still first on PATH; legacy |
| Zig required by dvui main | - | 0.17.0 | - | - | build.zig.zon minimum_zig_version |
| Flutter | missing | 3.47.8 stable | 3.47.8 | x64 emulated | engine cf636b1dfb; not on PATH |
| Dart | missing | 3.13.7 | 3.13.7 | x64 emulated | bundled with Flutter |
| flutter_rust_bridge_codegen | missing | 2.13.0 | 2.13.0 (2.14.0-beta.2 pre) | native arm64 (built from source) | |
| ffigen | - | not installed | 23.0.0 | n/a (Dart pkg) | |
| wasm-bindgen / cli | 0.2.129 | 0.2.129 | 0.2.129 | native arm64 | |
| wasm-pack | npm shim, broken | 0.15.0 (cargo) | 0.15.0 | native arm64 | cargo build needed clang on PATH (ring) |
| wasm-opt / binaryen | missing | version_133 | version_133 | native arm64 | official arm64-windows tarball; not on PATH |
| cargo-binstall | missing | 1.26.0 | 1.26.0 | native arm64 | |
| twiggy | missing | 0.8.0 | 0.8.0 | native arm64 | |
| hyperfine | missing | 2.0.0 | 2.0.0 | likely x64 emulated (winget zip, not verified) | |
| oha | missing | 1.16.0 | 1.16.0 | likely x64 emulated (not verified) | |
| scc | missing | 4.1.0 | 4.1.0 | likely x64 emulated (not verified) | |
| bloaty | missing | N/A | v1.1 | - | no Windows build/package |
| Node.js LTS | 24.19.0 | 24.22.1 | 24.22.1 | check (winget LTS installer) | |
| Playwright | missing | 1.64.1 | 1.64.1 | node pkg | |
| Chromium (Playwright) | missing | 156.0.8078.4 | same | x64 emulated | Playwright ships only chrome-win64 (PE machine 0x8664); no Windows ARM64 Chromium |
| Python | 3.12.10 arm64 | 3.12.10 | 3.14.x | native arm64 | not upgraded (3.12 sufficient); winget Python.Launcher 3.14.7 exists |
| GNU make | missing | missing | 4.4+ | - | BLOCKED/skipped: only GnuWin32 3.81 on winget |
| brotli CLI | missing | 1.2.1 | 1.2.1 | check | Google.Brotli winget |
| git | 2.55.0 | 2.56.0.windows.2 | 2.56.0 | check | upgraded via winget (UAC accepted) |
| gh | 2.96.0 | 2.103.2 | 2.103.2 | native arm64 | msi windows_arm64 |
| 7-Zip | 26.02 arm64 | 26.05 arm64 | 26.05 | native arm64 | `C:\Program Files\7-Zip\7z.exe`, not on PATH |
| curl | 8.21.0 | 8.21.0 | - | - | Windows system curl.exe (PowerShell `curl` is an alias) |
| LLVM/clang | 22.1.8 arm64 | 22.1.8 | 23.1.4 | native arm64 | winget upgrade refused (installer technology differs; needs uninstall/reinstall); left alone; not on PATH |
| MSVC Build Tools 2022 | 17.14.35 | 17.14.35 | 17.14.42 available | native arm64 | not upgraded (installer-managed) |
| lld / mold | - | lld-link in LLVM | - | - | mold N/A on Windows |
| winget | 1.29.380 | same | - | - | |

"check"/"likely emulated" = architecture not verified; only Flutter, Dart and Chromium were confirmed x64 (PE header or `dart --version` "windows_x64").

## Unavailable on Windows (spec Linux tooling)

- cgroup v2 / `systemd-run` per-run accounting (SPEC 2.11, 9.4, 9.7): no equivalent; PSI (`/proc/pressure/*`), swappiness N/A.
- `/usr/bin/time -v` (peak RSS, page faults): N/A; PowerShell `Measure-Command` / Job Object stats are only approximate.
- bloaty: no Windows build. twiggy covers WASM only.
- mold / wild linkers; system `ld`: N/A (MSVC link.exe / lld-link used instead).
- GNU make 4.4 jobserver FIFO (SPEC 9.6.1): not installed.
- Flutter Linux desktop target, Linux ELF cross-compile checks: not built here.
- Flutter Windows desktop builds are x64 only (emulated host toolchain), so Flutter-stack desktop numbers are not comparable to native ARM64 pure stacks.

## Notes / surprises

- PATH untouched (no system settings changed). New winget tools got aliases; Flutter, LLVM, 7-Zip, binaryen and Playwright are not on PATH.
- Bare `zig` resolves to the self-patched 0.16.0; 0.17.0 is only reachable via the WinGet Links path until PATH order is changed.
- The pre-existing npm `wasm-pack` shim is broken (missing run.js) and appears on PATH as wasm-pack.ps1; the cargo-installed wasm-pack.exe in ~/.cargo/bin is the working one (PATH order decides; remove the npm one if it shadows).
- cargo install of crates using `ring` (wasm-pack, cargo-binstall) fails on aarch64-windows unless clang is on PATH; worked with C:\Program Files\LLVM\bin appended for that command.
- Chrome 155 is behind winget's 156; not upgraded since it is the user's browser.

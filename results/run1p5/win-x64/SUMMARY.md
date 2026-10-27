# Frame2D bake-off: run1p5 build loop on win-x64

Build-loop only (SPEC 9.1 cold, 9.2 edits) on an x86_64 Windows 11 desktop (Core Ultra 7 270K Plus, 24 cores, 31 GB, NVMe; `env.md`),
with the same reduced protocol and stack code (repo HEAD, P5 state) as `results/run1p5/win-arm64`:
`harness/buildloop/run.sh <stack> cold edits --cold-runs 2 --runs 3 --warmup 1`. Raw records: `buildloop/<stack>/`.

## Caveats (read first)

- **Default Windows environment, on purpose.** Defender real-time protection is ON with no exclusions (human decision): these are the
  build times a typical Windows developer gets. The single exception is footnote [1].
- **Native x64 everywhere.** Unlike win-arm64, Flutter/Dart and every toolchain run natively, so Flutter stacks gain the most from this machine.
- **Small n.** Cold = mean of 2 runs; edits = p50 of 3 runs after 1 warmup. "edit check/dev (mean)" = mean of the p50 over the
  four edits (leaf, struct, server, ui).
- **Resources.** `cpu_s` and peak memory come from psutil sampling (50 ms). For Flutter stacks it misses most of the Dart/MSBuild/CMake
  children (e.g. go-flutter cold desktop: 7.6 CPU-s in 28.9 s wall), so treat their CPU/memory as a floor. Wall times are reliable.
- Not measured here: hot reload, engine-edit-to-app (both open app windows), footprint, breakdown, runtime/web/server benches.

## Wall time, p50: win-x64 (win-arm64 in brackets)

| stack | cold cli | cold server | cold desktop | cold web | cold dev | edit check (mean) | edit dev (mean) | no-op dev |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rust | 7.52 s (7.45 s) | 19.1 s (15.8 s) | 24.3 s (23.5 s) | 41.5 s (36.2 s) | 15.8 s (16.0 s) | 0.58 s (0.79 s) | 1.85 s (1.90 s) | 0.28 s (0.51 s) |
| zig | 64.7 s (44.1 s) | 78.8 s (51.4 s) | 127.0 s (87.5 s) | 95.7 s (60.4 s) | 92.8 s (68.2 s) | 0.94 s (1.04 s) | 3.91 s (3.03 s) | 0.34 s (0.51 s) |
| go | **2.70 s** (3.65 s) | **6.79 s** (8.33 s) [1] | **4.50 s** (5.70 s) | **3.77 s** (5.39 s) | **10.2 s** (11.7 s) | **0.39 s** (0.63 s) | **1.15 s** (0.96 s) | 0.33 s (0.67 s) |
| rust-flutter | 10.7 s (9.32 s) | 21.0 s (18.3 s) | 35.9 s (43.9 s) | 50.1 s (73.4 s) | 33.9 s (42.2 s) | 1.85 s (2.02 s) | 3.94 s (5.41 s) | 0.45 s (0.90 s) |
| zig-flutter | 70.1 s (59.3 s) | 69.4 s (61.0 s) | 100.0 s (96.9 s) | 90.8 s (88.5 s) | 79.5 s (79.9 s) | 3.31 s (3.05 s) | 6.65 s (9.53 s) | 0.39 s (0.85 s) |
| go-flutter | 2.68 s (5.47 s) | 7.06 s (24.1 s) | 28.9 s (46.0 s) | 26.9 s (47.1 s) | 25.5 s (37.9 s) | 1.84 s (2.23 s) | 3.45 s (6.11 s) | **0.28 s** (0.79 s) |
| go-zig-flutter | 28.5 s (51.4 s) | 33.0 s (53.1 s) | 29.9 s (43.5 s) | 29.8 s (48.6 s) | 25.3 s (38.0 s) | 1.62 s (1.94 s) | 5.54 s (6.93 s) | 0.56 s (1.65 s) |

zig-flutter also has cold web_wasm 91.5 s (93.2 s).

[1] **Blocked by Windows Defender in the default environment.** Every clean `go` `build_server_release` failed: Defender quarantined the
freshly linked `%TEMP%\go-build*\b001\exe\a.out.exe` as `Behavior:Win32/DefenseEvasion.A!ml` (ML false positive), so `go build`
exits 1 (reproduced twice; `_logs/go-cold-server-attempt{1,2}-defender.*`). The number shown was measured with **one** Defender path
exclusion, `%TEMP%\go-build*`, added by the human for this target only. The first build with the exclusion still took 32.7 s
(28 CPU-s, i.e. ~26 s waiting; `_logs/go-cold-server-attempt3-excl.jsonl`) versus 6.6-6.8 s for every later one, consistent with
Defender's first-sight scan of the new binary in the (not excluded) repo folder. win-arm64 recorded the same one-off stall on the same
target (35.3 s). go-flutter and go-zig-flutter servers were never flagged.

## Resources (psutil; Flutter stacks under-counted, see caveats)

| stack | cold dev CPU-s | cold dev peak MB | edit dev CPU-s (mean) | edit dev peak MB (max p50) |
|---|---:|---:|---:|---:|
| rust | 99.8 | 3145 | 2.2 | 729 |
| zig | 347.3 | 4189 | 6.1 | 614 |
| go | 56.2 | 1346 | 1.3 | 563 |
| rust-flutter | 59.5 | 1825 | 2.1 | 458 |
| zig-flutter | 139.4 | 2339 | 5.1 | 959 |
| go-flutter | 51.1 | 1237 | 2.0 | 449 |
| go-zig-flutter | 137.7 | 1721 | 6.9 | 618 |

## Findings

1. **Go is fastest and lightest on every axis** here too: 2.7-10 s cold, 0.4 s check / ~1.2 s dev per edit, least CPU and memory.
2. **Zig cold builds are ~45% slower on this x64 desktop than on the Snapdragon laptop** (cli 64.7 s vs 44.1 s; desktop 127 s vs 87.5 s).
   They are close to single-threaded (cold cli: 65 CPU-s in 65 s wall), so single-core speed decides, not the 24 cores. Zig incremental
   checks are unchanged (~1 s). The Zig engine is also why zig-flutter and go-zig-flutter have the slowest cold builds of the Flutter stacks.
3. **Rust is a wash between machines** (cargo parallelises well: cold desktop 280 CPU-s in 24 s).
4. **Flutter stacks are 20-70% faster than on win-arm64**, where Dart and the engine ran under x64 emulation (go-flutter cold server
   7.1 s vs 24.1 s, ui-edit `build_dev` 6.5 s vs 11.5 s). Flutter UI edits are still the slowest edit loop (4.5-5 s check, 7-17 s dev).
5. **The default Windows environment is an obstacle**: Defender blocks one Go release build outright and adds a one-off ~26 s
   first-scan stall to a new binary; Flutter plugin builds (zig-flutter, rust-flutter) fail until Windows Developer Mode is enabled.

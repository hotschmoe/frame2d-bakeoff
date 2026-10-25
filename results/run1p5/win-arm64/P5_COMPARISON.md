# P5 optimization pass vs run1 baseline (win-arm64)

run1 = code as the P1-P3 agents left it (tag `run1-baseline`). run1p5 = the same code after one fresh Sonnet optimization session per stack (`harness/kickoff/P5.md`, tags `p5-done-<stack>`). Both measured serially on a quiet machine with identical trimmed options (`TIMELINE.md` Deviations). Agent-handling and review scores in run1p5 are carried over from run1 (P5 reran neither); full numbers in `SUMMARY.md`.

**Scores are relative within a run** (each metric is normalised to that run's best stack). A stack can improve in absolute terms and still lose score when the others improve more (zig, for example). Compare raw numbers for absolute change.

## Leaderboard

| stack | human-priority run1 → P5 | SPEC-weight overall run1 → P5 | excl. agent handling run1 → P5 |
|---|---|---|---|
| rust | 0.657 → **0.653** (1st, was 2nd) | 0.695 → **0.706** | 0.707 → **0.721** |
| zig | **0.684** → 0.649 (2nd, was 1st) | 0.663 → 0.639 | **0.723** → 0.694 |
| go | 0.502 → 0.608 | 0.648 → 0.697 | 0.605 → 0.664 |
| rust-flutter | 0.387 → 0.439 | 0.499 → 0.541 | 0.510 → 0.560 |
| zig-flutter | 0.325 → 0.403 | 0.486 → 0.519 | 0.484 → 0.523 |
| go-zig-flutter | 0.299 → 0.365 | (0.510 → 0.560, P3 only) | 0.510 → 0.560 |
| go-flutter | 0.286 → 0.330 | 0.473 → 0.515 | 0.456 → 0.505 |

Rust and zig swap first place; the top three remain within noise of each other (≤ 0.05). The Flutter stacks gain the most but stay well behind the pure stacks. go-zig-flutter overtakes go-flutter on human priorities.

## What moved (medians; run1 → P5)

| stack | leaf edit check / dev (s) | no-op dev (s) | cold dev (s) | desktop drag p50 (ms) | web drag p50 (ms) | CLI 200x200 (ms) | server rps · p99 (ms) · peak RSS (MB) · idle RSS (MB) |
|---|---|---|---|---|---|---|---|
| rust | 0.79 / 2.66 → 0.84 / 2.14 | 0.51 → 0.51 | 18.3 → 16.0 | 13.9 → 10.2 | 84 → 43 | 2114 → 1479 | 294 → 319 · 593 → 262 · 1936 → 539 · 8.6 → 8.6 |
| zig | 1.20 / 6.25 → 1.19 / 3.67 | 0.56 → 0.51 | 68 → 68 | 8.7 → 9.1 | 39 → 40 | 1514 → 1502 | 251 → 316 · 641 → 504 · 1163 → 697 · 6.4 → 6.5 |
| go | 1.18 / 1.96 → 0.67 / 0.96 | 1.17 → 0.67 | 16.5 → 11.7 | 25.9 → 25.6 | 281 → 174 | 2597 → **3562** | 169 → 174 · 1468 → 436 · 3074 → 453 · 55.8 → 13.0 |
| rust-flutter | 6.5 / 12.3 → 1.34 / 3.66 | 8.86 → 0.90 | 50 → 42 | 33.0 → 25.1 | 47 → 47 | 2106 → 1444 | 300 → 295 · 716 → 289 · 1016 → 383 · 8.6 → 8.3 |
| zig-flutter | 6.7 / 35.4 → 2.78 / 3.46 | 33.3 → 0.85 | 101 → 80 | 27.2 → 24.8 | 66 → 80 | 1449 → 1445 | 249 → 297 · 683 → 367 · 1611 → 723 · 6.5 → 6.4 |
| go-flutter | 7.7 / 14.6 → 1.37 / 4.74 | 13.1 → 0.79 | 41 → 38 | 46.4 → 25.0 | 124 → 75 | 6366 → 2511 | 155 → 185 · 1575 → 599 · 2805 → 3029 · 55.5 → 12.7 |
| go-zig-flutter | 11.7 / 29.0 → 0.90 / 6.28 | 28.9 → 1.65 | 64 → 38 | 30.5 → 29.8 | 24 → 25 | 1715 → 1706 | 180 → 226 · 1123 → 503 · 2553 → 3481 · 62.5 → 12.7 |

Other notable changes: go web render p50 487 → 101 ms; rust web render 252 → 192 ms; zig-flutter WASM 1.73 → 0.26 MB (web download 2.65 → 2.31 MB brotli) and desktop bundle −1.2 MB; go-flutter and go-zig-flutter desktop bundles −1.0 MB (`--split-debug-info`). A Dart (UI) edit still costs 11.5-28.5 s `build_dev` in the Flutter stacks.

## Takeaways

- **The Flutter dev-loop gap was mostly `stack.sh`, not Flutter.** Non-UI edits dropped from 12-35 s to 3.5-6.3 s once builds skip unchanged work. UI edits remain Flutter-bound (11-29 s), where the pure stacks take 1-3.5 s.
- **The servers had the same mistake everywhere:** unbounded concurrency (a 512-thread tokio blocking pool, thread-per-connection, unlimited goroutines) and fully buffered 16 MB responses. Capping concurrency and streaming roughly halved p99 and cut peak RSS 2-7×. In go-flutter and go-zig-flutter, peak RSS under load did *not* drop (2.8 → 3.0 GB, 2.6 → 3.5 GB); neither agent capped server concurrency.
- **Go's idle RSS fell from ~56 MB to ~13 MB** in all three Go servers (not targeted by any agent; cause not verified).
- **Solver micro-optimization (multiple accumulators in `dot`) helped Rust (−30%) and go-flutter (−60%; its run1 code was unusually slow), but made go *slower* at 200×200 (2597 → 3562 ms; rechecked 3020 ms).** The go agent only measured 50×50. This is a real regression.
- **zig barely moved at runtime.** It was already near the front; its gains are server throughput and resources and a faster dev build.

## Caveats

- One run of P5 per stack; smoke numbers in AGENT_LOGs were taken with 3 agents running and are superseded by these.
- rust desktop drag/render in the campaign read ~257 ms (all 3 runs, solve normal at 15 ms), versus 9.7 ms in an immediate one-run recheck. It was re-measured with 3 runs (drag p50 10.2 ms); the bad record is in `_superseded/rust/desktop.json`. Likely a display/compositor throttle during that window, not a code effect.
- go 200×200 CLI recheck (`recheck/go/cli.json`) confirms the regression direction.
- rust's P5 draws members as non-anti-aliased quads (a visual-fidelity trade-off, flagged in its AGENT_LOG).
- Correctness: go-flutter gives wrong results for an `mz` release at a member's i end (also after P5); conformance F21-F25 does not cover it. See `TIMELINE.md`.

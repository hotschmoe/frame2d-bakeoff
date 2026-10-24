## zig-flutter

- start: Sat Oct 24 10:16:06 USMST 2026
- ORCHESTRATOR INSTRUCTION (human-approved reduced protocol): runtime `run.sh zig-flutter --runs 3` (keep sections already finished at 5 runs); buildloop `run.sh zig-flutter all --cold-runs 2 --runs 3 --warmup 1 --cycles 10 --engine-runs 3 --hot-reps 3 --zig-reps 3`.
- Received during the first full runtime run (started 10:16). Sections meta, build, loc, cli, desktop had finished with 5 runs (kept). I killed that run by PID mid-web (alt/wasm build bench), then server/binsize/... started and were killed too (rc=1 SECTION FAILED lines are from the kill). Minor slip: used `taskkill /IM oha.exe` once to clean up my own oha (no other oha existed).
- Re-running `run.sh zig-flutter web server binsize hood xcompile --runs 3`.
- Buildloop started Sat Oct 24 10:41:06 USMST 2026: run.sh zig-flutter all --cold-runs 2 --runs 3 --warmup 1 --cycles 10 --engine-runs 3 --hot-reps 3 --zig-reps 3
- ORCHESTRATOR INSTRUCTION #2 (supersedes section list): runtime only build meta loc cli desktop web server binsize with --runs 3 --no-alt; buildloop only cold edits hotreload engine. Status: runtime had already finished all sections incl. hood, xcompile and web alt (3 runs for web/server/binsize/hood/xcompile, 5 runs cli/desktop) - kept. Buildloop: cold done, edits running at 11:10; will let hotreload+engine run and stop the run (SIGTERM to run.sh) when footprint begins; footprint/breakdown/zigincr/contention recorded as dropped.
- Runtime final: runs recorded 5 (cli, desktop; done before instruction #1) and 3 (web incl. alt, server, binsize/hood/xcompile rerun). hood and xcompile exist (ran before instruction #2) - kept. No harness fixes needed.
- Anomalies: web alt (wasm) drag max 2.2 s / render max 1.9 s (startup outliers, p50 97/77 ms); web default drag p50 65 ms. Desktop drag p50 27 ms (no throttling). Server 50x50 oha: all 200, no errors.
- Buildloop: cold(2 runs), edits(3 runs), engine(3 reps) ok; hotreload not-implemented (no hot_reload_probe); footprint stopped at its first step (11:16, SIGTERM ignored while child ran, killed by PID) and its partial output deleted; footprint/breakdown/zigincr/contention DROPPED per instruction #2. git status --porcelain stacks empty.
- end: Sat Oct 24 ~11:20

## zig

- start: Sat Oct 24 11:18 USMST 2026; end: Sat Oct 24 11:39 USMST 2026
- Runtime: `harness/runtime/run.sh zig build meta loc cli desktop web server binsize --runs 3 --no-alt`. First attempt: `cli` and `desktop` FAILED (rc=2): `run.sh` forwarded `--runs 3 --no-alt` to cli_bench.py (accepts `--reps`) and desktop_bench.py (no `--no-alt`). Other sections (build, meta, loc, web, server, binsize) ran fine in that attempt.
- Harness fix: `harness/runtime/run.sh` now routes options per section (cli: `--runs N` -> `--reps N`; desktop: `--runs N`; web: `--runs N` and `--no-alt`). Rerun: `harness/runtime/run.sh zig cli desktop --runs 3 --no-alt` (ok; cli 3 reps, desktop 3 runs).
- Sanity: desktop drag p50 8.7 ms, render p50 1.4 ms, startup 64 ms (no throttling). Web: tti 175-205 ms, drag p50 ~39 ms, render p50 ~19 ms, no outliers. Server 50x50 oha: 7501 x 200, 0 errors (64 "aborted due to deadline" are in-flight at the end of the 30 s run). Sweeps ok (1000 x 10x10, 200 x 50x50).
- Buildloop: `harness/buildloop/run.sh zig cold edits hotreload engine --cold-runs 2 --runs 3 --warmup 1 --engine-runs 3 --hot-reps 3`. cold ok (2 runs x cli/server/desktop/web/dev, all exit 0), edits ok (all exit 0). hotreload/engine: skipped (not a Flutter stack). No reruns needed.
- `git status --porcelain stacks` lists model.zig/solver.zig/ui.zig as M after the edits section although `git diff` (worktree and HEAD) is empty: content is identical to HEAD, only eol/stat noise (autocrlf) from the edit scripts' rewrites; not resolved by `git update-index --refresh`.

## rust

- start: Sat Oct 24 11:39 USMST 2026; end: Sat Oct 24 12:02 USMST 2026
- Runtime: `harness/runtime/run.sh rust build meta loc cli desktop web server binsize --runs 3 --no-alt` (11:39-11:55, rc=0, no reruns). Sanity: desktop drag p50 13.9 ms (matches AGENT_LOG ~14 ms; no throttling), render p50 8.4 ms, startup 149-254 ms (first run 254 ms cold). Web: tti 371-399 ms, drag p50 78-86 ms, render p50 ~251 ms, no outliers apart from drag max ~385 ms. Server 50x50 oha: 8802 x 200, 0 errors (64 aborted-at-deadline in flight). Sweeps ok (1000 x 10x10, 200 x 50x50).
- Buildloop: `harness/buildloop/run.sh rust cold edits hotreload engine --cold-runs 2 --runs 3 --warmup 1 --engine-runs 3 --hot-reps 3` (11:55-12:01, rc=0). All cold/edit/no-op runs exit 0. hotreload/engine skipped (not a Flutter stack).
- No harness fixes, no reruns. `git status --porcelain stacks` empty.

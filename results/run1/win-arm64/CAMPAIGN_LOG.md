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

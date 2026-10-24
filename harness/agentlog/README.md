# harness/agentlog: agent session logs to SPEC 8.1 / 10.1 metrics

Python 3 stdlib only. Reads the xz-compressed Claude Code subagent transcripts in
`results/<run>/<machine>/transcripts/` directly (nothing is decompressed into the repo).
Run everything from the repo root:

```
python harness/agentlog/metrics.py     # -> results/run1/win-arm64/agent/metrics.{json,md}
python harness/agentlog/digest.py      # -> .../agent/digests/<stack>-<phase>.{md,json}
python harness/agentlog/diffstat.py    # -> .../agent/diffstat.{json,md}   (needs metrics.json and the git tags)
python harness/agentlog/aggregate.py   # -> .../agent/taxonomy.{json,md}   (needs classified/*.json)
```

Options: `--run run1 --machine win-arm64`; `metrics.py --price-file prices.json`; `digest.py --max-kb 55`;
`aggregate.py --agent-dir DIR` (used to test with fake data in a temp dir).
`common.py` holds the transcript parser, command classifier and failure detector shared by all four.

## Transcript facts the parser relies on

- One JSON object per line. `assistant` lines carry one content block each (thinking / text / tool_use); several lines share one
  `message.id` and repeat the same `usage`. **Turns = distinct assistant `message.id`**; tokens are taken once per id.
- `tool_use` blocks are matched to `tool_result` blocks (in `user` lines) by id. `is_error` is true only for a non-zero exit of the
  *whole* shell command, so `cmd | tail` hides failures (see heuristics).
- Commands that exceed the 120 s foreground limit, or use `run_in_background`, are "moved to the background"; the real end time and
  status come from a later `queued_command` attachment holding a `<task-notification>` (`tool-use-id`, `status`). Their output file is
  not in the transcript; if the agent read `<task-id>.output` later, that read is appended as the output.
- Interventions: the first user message is the kickoff. Any later `user` text, or non-task `queued_command` (for example an
  "Orchestrator notice"), is an intervention. `[SYSTEM NOTIFICATION...]` and `<task-notification>` events are not.

## Heuristics (all approximate)

**Command kinds** (`common.classify_text`). The command is stripped of heredoc bodies and split into simple commands on `&& || ; |`
and newlines outside quotes. `measure.sh <stack> <label> -- X` and `bash -c "X"` are unwrapped recursively, and each simple command is
mapped by its program:

- `build`: `build_*` / `codegen` (stack.sh functions), `cargo build`, `go build`, `zig build` (not the test step), `zig build-exe|lib`,
  `flutter build`, `dart compile`, `dart run ffigen|build_runner`, `flutter_rust_bridge_codegen`, `wasm-bindgen`, `wasm-pack`, cmake/ninja/make.
- `check`: `build_check`, `cargo check|clippy`, `go vet`, `flutter analyze`, `dart analyze`.
- `test`: `test_all` / `test_*`, `cargo test`, `go test`, `zig build test`, `zig test`, `flutter test`, `dart test`, `pytest`.
- `conformance`: `conformance.py` (any stack argument, including `reference`), `server_conformance.py|.sh`.
- `run` (failures only): a command of none of the above that runs a program and whose output has a crash marker (`panic:`, `panicked at`,
  `Segmentation fault`, `Unhandled exception`, exit code `0xC...`, ...). Also flagged on build/test commands that ran a program afterwards.

A command that chains kinds (`go vet && go build && python conformance.py`) counts once in every kind it contains.
`cat harness/conformance.py`, `grep build_check` and heredoc bodies do not count (only the program of each simple command is looked at).
Not counted as builds: `flutter pub get`, `zig fetch`, `npm`, running the produced binaries, `gofmt`, `cargo run`.

**Failure** (`common.detect_failure`):

- (a) `is_error` / `Exit code N`; (b) a background task with `status=failed`.
- (c) *inferred* from output text, because pipes and `;` chains mask exit codes: a printed `rc=N` / `EXIT=N`; the WSL "no installed
  distributions" stub message (also in its UTF-16 spaced form); and per-kind marker lines: compiler diagnostics (`error:`, `error[E..]`,
  `file.go:L:C:`, dart/frb `Error:`, zig `Build Summary ... failed`, linker errors), test markers (`--- FAIL`, `FAIL`,
  `test result: FAILED`, `panicked at`), conformance markers (`FAIL <name>` lines, `N/M passed` with N<M, `FAILED (n failures)`,
  Python tracebacks, missing binary).
- If every inferred marker is weak and a success banner (`17/17 passed`, `all passed (0 failures)`, `test result: ok`, `No issues found`)
  is present, the command is treated as passed. Lines containing `BENCH-EDIT` are ignored (the edit-toggle scripts print file:line text).
  `<tool_use_error>` results (blocked or invalid tool call) are never failures.

Inferred failures can be false positives (digests say so; classifiers answer `false_positive`). A failure whose output was never shown
(background command whose output file was not read, output redirected to a file) can be missed.

**Wall time**: first to last timestamp in the transcript. A *stall* is any gap > 30 min between consecutive events (`common.STALL_S`);
`wall_corrected = raw - sum(stalls)`. Stalls are also clipped out of build-wait.

**Build wait**: sum of tool_use to tool_result (background: to task notification) time of build+check commands (`build_wait_s`). This is an
upper bound: it includes the bench/test parts of composite shell calls and background build time during which the agent kept working.
`pure_build_wait_s` counts only commands made of build/check calls plus trivial glue (cd, sed, python edit scripts, ...), and only the time
the agent was actually blocked (initial result, not background completion); prefer it. The measure.sh records in `results/adhoc/` are the
authoritative per-build timings where present, but they are missing before the 23:23 harness fix (see TIMELINE), so they are not used here.

**Cost**: `common.PRICES_PER_MTOK` is an ASSUMED Sonnet-class list-price table (input 3, output 15, cache read 0.30, 5-minute cache write
3.75, 1-hour write 6.00 USD per Mtok). The real prices of claude-sonnet-5-5 were not verified; override with `--price-file`.
Tokens of the advisor model (`advisorModel` field in assistant lines) are not in the transcripts and are not costed.

**Diffs (10.1)**: `git diff --numstat p1-done-X p2-done-X -- stacks/X` (P3: `fork-go-zig-flutter..p3-done-go-zig-flutter`). Excluded: the stack's
`LOC_EXCLUDE` (prefix or glob), generic generated patterns (frb_generated, `*.g.dart`, `generated/`, `ffigen/`, lockfiles, `go.sum`, `.tools/`,
images) and `AGENT_LOG.md`.

## Output schema

`metrics.json`: `{run, machine, prices_usd_per_mtok, records: [{stack, phase, start, end, wall_raw_s, stall_s, wall_corrected_s, stalls[],
turns, tool_calls, tool_calls_by_tool{}, build_invocations, build_invocations_by_kind{build,check}, failed_builds, build_wait_s,
build_wait_fraction_of_corrected_wall, pure_build_invocations, pure_build_wait_s, pure_build_wait_fraction_of_corrected_wall, test_runs,
failed_test_runs, conformance_runs, failed_conformance_runs, failures_total, runtime_crash_markers, background_commands, interventions,
intervention_detail[], agent_log_human_interventions_section,
tokens{input,output,cache_read,cache_creation,cache_write_5m,cache_write_1h}, est_cost_usd}]}`

`digests/<stack>-<phase>.json`: `{stack, phase, build_check_commands, n_failures, failures: [{id: "F1", ts, minutes_since_phase_start,
kinds[], primary_kind, reasons[], signature, next_success: {ts, command, kinds, minutes_after_failure} | null}]}`. The `.md` has the same
ids plus the command, trimmed output (first ~40 relevant lines), the agent's text before and after, and the next success of the same kind.
`primary_kind` is the first kind whose own markers fail (for chained commands), else the first kind in the command.

`taxonomy.json`: per stack `count{category}`, `minutes{category}`, `caught_count`, `caught_minutes`, `caught_share_count`,
`caught_share_minutes`, `builds`, `stale_api_per_100_builds`, `false_positive`; plus `coverage[]` and `problems[]`.

## Classification protocol (SPEC 8.1 failure taxonomy)

One **fresh** classifier agent per stack (7 agents; the zig dvui smoke digest is optional and not scored). It reads only
`results/run1/win-arm64/agent/digests/<stack>-*.md` (P1 and P2; P3 for go-zig-flutter) and may read that stack's `AGENT_LOG.md`;
it must not read other stacks. For every `F<n>` it writes `results/run1/win-arm64/agent/classified/<stack>-<phase>.json`, a list with one
entry per failure id:

```
[{"id": "F3", "category": "strictness", "caught_at": "compile", "minutes_to_fix": 0.5, "note": "unused local constant"}]
```

- `category`: exactly one of `type, ownership, concurrency_types, comptime_sema, strictness, stale_api, ffi, link, build_config, runtime_crash,
  wrong_result` (SPEC 8.1 definitions), or `false_positive` when the flagged item is not a failure of the stated kind (excluded from all counts).
  Classify by root cause, not symptom: a Python traceback because the harness got a relative `--bin` path is `build_config`; a shell-quoting
  slip that stops a command from running is `build_config`; a zig "no field named Debug" is `stale_api`.
- `caught_at`: `compile` (compiler, checker, linker, codegen), `own_tests` (unit/integration tests the agent wrote), `harness`
  (`conformance.py`, `server_conformance`, goldens), `runtime_manual` (found by running the app or bench, or by manual inspection).
- `minutes_to_fix`: minutes from the failure to the next success of that kind (the digest gives it). The classifier may shorten it when
  several unrelated errors share one success. Omit it to fall back to the digest value.
- `note`: one line with the root cause.

Then `python harness/agentlog/aggregate.py` builds `taxonomy.json` / `taxonomy.md`: counts and minutes per category, caught-at shares,
`stale_api` per 100 builds, coverage and validation problems.

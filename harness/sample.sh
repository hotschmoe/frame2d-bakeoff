#!/usr/bin/env bash
# Whole-run accounting and time-series sampling (SPEC 9.7, and the machine-wide sampler for 9.6). LINUX ONLY (SPEC 15.4):
# on other platforms every mode prints "skipped: Linux-only (SPEC 15.4)" and exits 0.
#
#   harness/sample.sh run <stack> <phase> -- <agent command...>
#       Runs the command inside its own long-lived transient cgroup scope (via harness/measure.sh, so the scope is
#       named f2d-agent-<stack>-<phase>-NNN and the cgroup totals are recorded: cpu_s, mem_peak_mb, io_write_mb ...),
#       with a 1 Hz sampler running inside that scope. Output (under $RESULTS_DIR, default
#       results/$F2D_RUN/$F2D_MACHINE_ID/accounting):
#         <stack>/agent-<stack>-<phase>.jsonl      one measure.sh record (the whole-run totals)
#         <stack>/<phase>_timeseries.csv           t, cpu_usage_delta_s, memory_current_mb, procs, psi_*_avg10 (+ machine extras)
#       CPU-hours spent in builds = sum of cpu_s over the build records the agent routed through measure.sh (RESULTS_DIR of
#       that run); everything else = total minus that.
#   harness/sample.sh system <out.csv>        sample machine-wide until killed (used by the contention driver)
#   harness/sample.sh cgroup <path> <out.csv> sample one cgroup directory until killed
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$(uname -s)" != Linux ]; then echo "sample.sh: skipped: Linux-only (SPEC 15.4)" >&2; exit 0; fi
source "$HERE/machine-env.sh"
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi
SAMPLER="$HERE/buildloop/sampler.py"

case "${1:-}" in
  system)  exec "$PY" "$SAMPLER" series --out "${2:?out.csv}" --cgroup system ;;
  cgroup)  exec "$PY" "$SAMPLER" series --out "${3:?out.csv}" --cgroup "${2:?cgroup dir}" ;;
  _inner)  # inside the scope: _inner <csv> -- cmd...
    CSV="$2"; shift 3
    "$PY" "$SAMPLER" series --out "$CSV" --cgroup self & SP=$!
    "$@"; RC=$?
    kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
    exit $RC ;;
  run)
    STACK="${2:?stack}"; PHASE="${3:?phase}"; shift 3
    [ "${1:-}" = "--" ] && shift
    export RESULTS_DIR="${RESULTS_DIR:-$HERE/../results/${F2D_RUN:-run1}/${F2D_MACHINE_ID:-linux}/accounting}"
    mkdir -p "$RESULTS_DIR/$STACK"
    exec bash "$HERE/measure.sh" "$STACK" "agent-$STACK-$PHASE" -- bash "$0" _inner "$RESULTS_DIR/$STACK/${PHASE}_timeseries.csv" -- "$@" ;;
  *) sed -n '2,20p' "$0"; exit 64 ;;
esac

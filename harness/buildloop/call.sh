#!/usr/bin/env bash
# call.sh <stack-dir> <function> [args...]      run one stack.sh function from a fresh shell (SPEC 5.6)
# call.sh <stack-dir> --has <function>          exit 0 if stack.sh defines <function>
#
# Environment knobs (all optional):
#   BL_LOG=<file>        send stdout+stderr of the function to this file (kept for the last run only)
#   BL_BOUNDED=1         call the stack's `bounded` first (BENCH_JOBS applies; SPEC 9.6)
#   BL_TRACE_DIR=<dir>   section 9.5: shim cargo/go/zig/flutter so the stack's own functions emit timing data
#                        (cargo --timings, go -debug-actiongraph, zig --summary all, flutter -v). No stack file changes:
#                        the shims are bash functions defined before stack.sh is sourced.
#   BL_ZIG_INCREMENTAL=1 add -fincremental to `zig build` (SPEC 9.3)
SD="$1"; FN="$2"; shift 2 || exit 64
if [ "$FN" = "--has" ]; then
  ( source "$SD/stack.sh" >/dev/null 2>&1; [ "$(type -t "${1:?function}")" = function ] )
  exit $?
fi
if [ -n "${BL_LOG:-}" ]; then mkdir -p "$(dirname "$BL_LOG")"; exec >"$BL_LOG" 2>&1; fi

if [ -n "${BL_ZIG_WATCH:-}" ]; then
  # zigwatch.py: BL_ZIG_WATCH=plain|incremental; `zig build --watch` never exits, the driver kills it
  zig() { case "${1:-}" in build) shift; command zig build --watch --summary all $([ "$BL_ZIG_WATCH" = incremental ] && echo -fincremental) "$@" ;; *) command zig "$@" ;; esac; }
elif [ -n "${BL_TRACE_DIR:-}" ]; then
  mkdir -p "$BL_TRACE_DIR"
  exec > >(tee -a "$BL_TRACE_DIR/$FN.out") 2>&1
  cargo()   { case "${1:-}" in build|check) local s=$1; shift; command cargo "$s" --timings "$@" ;; *) command cargo "$@" ;; esac; }
  go()      { case "${1:-}" in build) shift; command go build "-debug-actiongraph=$BL_TRACE_DIR/ag-$(date +%s%N)-$RANDOM.json" "$@" ;; *) command go "$@" ;; esac; }
  zig()     { case "${1:-}" in build) shift; command zig build --summary all ${BL_ZIG_INCREMENTAL:+-fincremental} "$@" ;; *) command zig "$@" ;; esac; }
  flutter() { command flutter -v "$@"; }
elif [ -n "${BL_ZIG_INCREMENTAL:-}" ]; then
  zig() { case "${1:-}" in build) shift; command zig build -fincremental "$@" ;; *) command zig "$@" ;; esac; }
fi

source "$SD/stack.sh" || exit 97
[ "$(type -t "$FN")" = function ] || { echo "call.sh: $SD/stack.sh does not define $FN" >&2; exit 98; }
[ -n "${BL_BOUNDED:-}" ] && bounded
"$FN" "$@"

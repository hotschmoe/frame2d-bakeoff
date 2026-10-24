#!/usr/bin/env bash
# usage: measure.sh <stack> <label> -- <command...>      (SPEC 9.4)
# Runs the command and writes one JSON record to $RESULTS_DIR/<stack>/<label>.jsonl (default results/adhoc).
# The command's own stdout/stderr pass through; the exit code is preserved.
#
# Linux with systemd --user: the command runs in a fresh transient cgroup scope and the cgroup counters
# are read from INSIDE the scope after the command exits (the scope is deleted when it ends).
# Elsewhere (Windows, macOS, no systemd): falls back to harness/measure_fallback.py (wall time, plus CPU
# and peak memory of the process tree when psutil is installed). Linux-only fields are null there.
set -u
# python3 or python (Linux often has only python3; Windows Git bash often has only python)
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [ "${1:-}" = "--inner" ]; then
  # inside the scope: $2 = out file, then the command
  OUT="$2"; shift 2
  CG="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"
  ( max=0; while :; do n=$(wc -l < "$CG/cgroup.procs" 2>/dev/null || echo 0); [ "$n" -gt "$max" ] && { max=$n; echo "$max" > "$OUT.procs"; }; sleep 0.1; done ) &
  MAXER=$!
  T0=$(date +%s.%N)
  "$@"; RC=$?
  T1=$(date +%s.%N)
  kill $MAXER 2>/dev/null
  cpu=$(awk '/usage_usec/{print $2}' "$CG/cpu.stat")
  mempeak=$(cat "$CG/memory.peak" 2>/dev/null || echo 0)
  swappeak=$(cat "$CG/memory.swap.peak" 2>/dev/null || echo 0)
  io=$(awk '{for(i=2;i<=NF;i++){split($i,a,"=");if(a[1]=="rbytes")r+=a[2];if(a[1]=="wbytes")w+=a[2]}}END{print r+0, w+0}' "$CG/io.stat" 2>/dev/null)
  procs=$(cat "$OUT.procs" 2>/dev/null || echo 0)
  $PY - "$OUT" "$RC" "$T0" "$T1" "$cpu" "$mempeak" "$swappeak" "$io" "$procs" <<'PY'
import json, sys
out, rc, t0, t1, cpu, mem, swap, io, procs = sys.argv[1:10]
r, w = (int(x) for x in io.split())
wall = float(t1) - float(t0)
cpu_s = int(cpu) / 1e6
json.dump({"wall_s": wall, "cpu_s": cpu_s, "parallelism": cpu_s / wall if wall else None,
           "mem_peak_mb": int(mem) / 2**20, "swap_peak_mb": int(swap) / 2**20,
           "io_read_mb": r / 2**20, "io_write_mb": w / 2**20, "procs_peak": int(procs),
           "exit_code": int(rc), "method": "cgroup"}, open(out + ".rec", "w"))
PY
  rm -f "$OUT.procs"
  exit "$RC"
fi

STACK="${1:?stack}"; LABEL="${2:?label}"; shift 2
[ "${1:-}" = "--" ] && shift
OUTDIR="${RESULTS_DIR:-$ROOT/results/adhoc}/$STACK"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/.$LABEL.$$"

if [ "$(uname -s)" = "Linux" ] && command -v systemd-run >/dev/null 2>&1 \
   && [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ] && systemctl --user is-active --quiet default.target 2>/dev/null; then
  systemd-run --user --scope --quiet --unit="f2d-$LABEL-$RANDOM" \
    -p CPUAccounting=yes -p MemoryAccounting=yes -p IOAccounting=yes \
    -- bash "$0" --inner "$OUT" "$@"
  RC=$?
  REC="$OUT.rec"
else
  $PY "$HERE/measure_fallback.py" "$OUT.rec" "$@"
  RC=$?
  REC="$OUT.rec"
fi
if [ -f "$REC" ]; then
  $PY - "$REC" "$STACK" "$LABEL" >> "$OUTDIR/$LABEL.jsonl" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1])); rec.update(stack=sys.argv[2], label=sys.argv[3]); print(json.dumps(rec))
PY
  rm -f "$REC"
fi
exit "$RC"

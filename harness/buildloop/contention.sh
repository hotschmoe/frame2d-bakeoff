#!/usr/bin/env bash
# contention.sh <stack-name> <stack-dir> <record-dir>      SPEC 9.6 multi-agent contention.  LINUX ONLY (SPEC 15.4).
#
# Exit 3 with a "skipped" record when not on Linux with systemd --user + cgroup v2 + PSI. NOT TESTED on Windows by design;
# written for linux-aarch64 / linux-x64 runs, keep it simple.
#
# What it does:
#   1. Makes COPIES (default 4) independent copies of the finished stack, each laid out as
#        $WORK/cN/stacks/<stack>   (+ symlinks $WORK/cN/harness and $WORK/cN/fixtures to the repo's)
#      so the stack's relative ../../harness paths keep working. Download caches (cargo registry, pub cache, Go module
#      cache) are shared because they live in $HOME.
#   2. Runs ONE copy alone for 3 iterations: the "solo" baseline for the slowdown factors.
#   3. For each config (default bounded jobserver jobserver+cgroup), runs all copies at once, each looping
#        leaf edit -> build_check -> build_dev -> test_all   ITERS times (default 20)
#      each copy inside its own cgroup scope (measure.sh). While they run: sample.sh-style 1 Hz machine-wide CSV
#      (PSI cpu/mem/io avg10, memory, swap counters) and a 10 ms wake-up latency probe.
#   4. bl.py contention summarizes everything into contention_summary.json.
#
# Env: BL_CONT_COPIES=4 BL_CONT_ITERS=20 BL_CONT_CONFIGS="default bounded jobserver jobserver+cgroup" BL_CONT_KEEP=1 (keep copies)
#      BL_CONT_WORK=<dir for copies; default <record-dir>/contention/work, needs a few GB per copy for Flutter stacks>
set -u
STACK="$1"; SD="$2"; OUT="$3/contention"
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$(cd "$HERE/.." && pwd)"
mkdir -p "$OUT"

skip() { echo "{\"skipped\":\"$1\",\"stack\":\"$STACK\"}" > "$OUT/skipped.json"; echo "contention: skipped: $1" >&2; exit 3; }
[ "$(uname -s)" = Linux ] || skip "Linux-only (SPEC 15.4)"
command -v systemd-run >/dev/null 2>&1 || skip "Linux-only (SPEC 15.4): systemd-run not found"
[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = cgroup2fs ] || skip "Linux-only (SPEC 15.4): cgroup v2 not mounted"
[ -r /proc/pressure/cpu ] || skip "Linux-only (SPEC 15.4): no /proc/pressure (PSI)"
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi

COPIES="${BL_CONT_COPIES:-4}"; ITERS="${BL_CONT_ITERS:-20}"
CONFIGS="${BL_CONT_CONFIGS:-default bounded jobserver jobserver+cgroup}"
WORK="${BL_CONT_WORK:-$OUT/work}"
CORES="$(nproc)"; RAM_KB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
BOUND=$(( CORES / COPIES )); [ "$BOUND" -ge 1 ] || BOUND=1
TOOLS=""; [ -f "$SD/Cargo.toml" ] && TOOLS+="cargo "; [ -f "$SD/app/pubspec.yaml" ] && TOOLS+="flutter "

echo "contention: $STACK copies=$COPIES iters=$ITERS configs=[$CONFIGS] cores=$CORES" >&2
for i in $(seq 1 "$COPIES"); do
  rm -rf "$WORK/c$i"; mkdir -p "$WORK/c$i/stacks"
  cp -a "$SD" "$WORK/c$i/stacks/$STACK"
  ln -s "$HARNESS" "$WORK/c$i/harness"; [ -e "$HARNESS/../fixtures" ] && ln -s "$(cd "$HARNESS/../fixtures" && pwd)" "$WORK/c$i/fixtures"
done
cdir() { echo "$WORK/c$1/stacks/$STACK"; }

# ---- solo baseline: one copy, nothing else running, 3 iterations
echo "contention: solo baseline" >&2
bash "$HERE/contention_loop.sh" "$(cdir 1)" 3 "$OUT/solo-run" >/dev/null 2>&1
"$PY" - "$OUT" <<'PYEOF'
import json, sys
o = sys.argv[1]
with open(o + "/solo.jsonl", "w") as f:
    for l in open(o + "/solo-run/iter.jsonl"):
        f.write(l)
PYEOF

for cfg in $CONFIGS; do
  cd_="$OUT/$cfg"; rm -rf "$cd_"; mkdir -p "$cd_"
  unset MAKEFLAGS CARGO_MAKEFLAGS BL_BOUNDED BENCH_JOBS MEASURE_SCOPE_PROPS
  case "$cfg" in
    default) ;;
    bounded) export BL_BOUNDED=1 BENCH_JOBS="$BOUND" ;;
    jobserver|jobserver+cgroup)
      if [ -z "$TOOLS" ]; then echo '{"skipped":"stack builds with neither Cargo nor Make/CMake"}' > "$cd_/skipped.json"; continue; fi
      source "$HARNESS/jobserver.sh" "$CORES"
      [ "$cfg" = "jobserver+cgroup" ] && export MEASURE_SCOPE_PROPS="-p MemoryMax=$(( RAM_KB * 1024 / COPIES )) -p CPUWeight=50" ;;
    *) echo "contention: unknown config $cfg" >&2; continue ;;
  esac
  echo "contention: config $cfg" >&2
  "$PY" "$HERE/sampler.py" series --out "$cd_/timeseries.csv" --cgroup system & SAMPLER=$!
  "$PY" "$HERE/sampler.py" latency --out "$cd_/latency.json" & PROBE=$!
  sleep 2
  T0=$(date +%s.%N); PIDS=()
  for i in $(seq 1 "$COPIES"); do
    mkdir -p "$cd_/copy$i"
    RESULTS_DIR="$cd_/measure" bash "$HARNESS/measure.sh" "c$i" loop -- \
      bash "$HERE/contention_loop.sh" "$(cdir "$i")" "$ITERS" "$cd_/copy$i" >/dev/null 2>&1 &
    PIDS+=($!)
  done
  for p in "${PIDS[@]}"; do wait "$p"; done
  T1=$(date +%s.%N)
  echo "{\"config\":\"$cfg\",\"copies\":$COPIES,\"iters\":$ITERS,\"wall_s\":$(awk "BEGIN{print $T1 - $T0}")}" >> "$cd_/total.jsonl"
  sleep 2
  kill "$SAMPLER" "$PROBE" 2>/dev/null; wait "$SAMPLER" "$PROBE" 2>/dev/null     # only the PIDs we started
  type jobserver_stop >/dev/null 2>&1 && jobserver_stop
done

"$PY" "$HERE/bl.py" contention "$OUT"
[ -n "${BL_CONT_KEEP:-}" ] || rm -rf "$WORK"
exit 0

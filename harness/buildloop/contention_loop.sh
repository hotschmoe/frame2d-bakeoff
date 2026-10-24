#!/usr/bin/env bash
# contention_loop.sh <stack-copy-dir> <iterations> <out-dir>      (SPEC 9.6; started by contention.sh, one per copy)
# Loop: leaf edit -> build_check -> build_dev -> test_all, `iterations` times. Appends to <out-dir>/iter.jsonl:
#   {"iter":i,"step":"check|dev|test","wall_s":..,"exit_code":..}
# Per-step wall time only; the cgroup totals for the whole loop come from the measure.sh scope that wraps this script.
HERE="$(cd "$(dirname "$0")" && pwd)"
SD="$1"; N="$2"; OUT="$3"
mkdir -p "$OUT"; : > "$OUT/iter.jsonl"
step() { # step <iter> <name> <fn>
  local t0 t1 rc
  t0=$(date +%s.%N)
  bash "$HERE/call.sh" "$SD" "$3" > "$OUT/last-$2.log" 2>&1; rc=$?
  t1=$(date +%s.%N)
  echo "{\"iter\":$1,\"step\":\"$2\",\"wall_s\":$(echo "$t1 - $t0" | bc -l 2>/dev/null || awk "BEGIN{print $t1 - $t0}"),\"exit_code\":$rc}" >> "$OUT/iter.jsonl"
}
for i in $(seq 1 "$N"); do
  bash "$HERE/edit.sh" "$SD" leaf
  step "$i" check build_check
  step "$i" dev build_dev
  step "$i" test test_all
done
bash "$HERE/edit.sh" "$SD" --restore

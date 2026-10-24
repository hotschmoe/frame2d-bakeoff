#!/usr/bin/env bash
# Section implementations for run.sh (SPEC 9). Sourced by run.sh after lib.sh; expects these variables:
#   BL_STACK BL_SD BL_OUT            stack name, stack dir (native path form), record dir
#   BL_QUICK, BL_COLD_RUNS, BL_RUNS, BL_WARMUP, BL_CYCLES, BL_SIZE_EVERY, BL_COLD_TARGETS,
#   BL_ENGINE_RUNS, BL_HOT_REPS, BL_HOT_WARMUP, BL_ZIG_INCR, BL_LINK_TIMER, BL_ZIGWATCH_REPS
# Each sec_* sets SEC_STATUS (ok|failed|skipped|unsupported|not-implemented) and SEC_REASON; run.sh records them.

EDITS="leaf struct server ui"

# ------------------------------------------------------------------------------------------ 9.1 cold build
sec_cold() {
  local t fn label failed=""
  for t in $BL_COLD_TARGETS; do
    case "$t" in dev) fn=build_dev ;; *) fn="build_${t}_release" ;; esac
    if ! stack_has "$fn"; then log "cold: $fn not defined, skipping $t"; continue; fi
    log "cold: $t ($fn) x$BL_COLD_RUNS, clean_all before each run"
    hf "cold-$t" "$BL_COLD_RUNS" 0 clean_all "cold-$t=$fn" || failed+="$t "
  done
  [ -z "$failed" ] || { SEC_STATUS=failed; SEC_REASON="cold targets failed: $failed (see logs/)"; }
}

# ------------------------------------------------------------------------------------------ 9.2 incremental edits
# Prime both builds (untimed by hyperfine; recorded as prime-*), then the no-op rebuilds, then each edit.
sec_edits() {
  local e failed="" na=""
  log "edits: priming build_check and build_dev"
  rm -f "$BL_OUT/prime-check.jsonl" "$BL_OUT/prime-dev.jsonl"
  tm prime-check build_check || { SEC_STATUS=failed; SEC_REASON="prime build_check failed"; return; }
  tm prime-dev build_dev || { SEC_STATUS=failed; SEC_REASON="prime build_dev failed"; return; }
  log "edits: no-op rebuilds"
  hf noop "$BL_RUNS" "$BL_WARMUP" "" noop-check=build_check noop-dev=build_dev || failed+="noop "
  for e in $EDITS; do
    if ! edit "$e" 2>/dev/null; then log "edits: no BENCH-EDIT:$e marker in $BL_STACK, skipping"; na+="$e "; continue; fi
    log "edits: $e  (hyperfine warmup=$BL_WARMUP runs=$BL_RUNS; check then dev)"
    hf "edit-$e" "$BL_RUNS" "$BL_WARMUP" "edit:$e" "edit-$e-check=build_check" "edit-$e-dev=build_dev" || failed+="$e "
  done
  restore_edits
  [ -z "$na" ] || echo "$na" > "$BL_OUT/edits-not-applicable.txt"
  [ -z "$failed" ] || { SEC_STATUS=failed; SEC_REASON="failed: $failed"; }
}

# ------------------------------------------------------------------------------------------ 9.2 Flutter hot reload
sec_hotreload() {
  if ! is_flutter; then SEC_STATUS=skipped; SEC_REASON="not a Flutter stack"; return; fi
  if ! stack_has hot_reload_probe; then
    SEC_STATUS=not-implemented; SEC_REASON="stack.sh defines no hot_reload_probe (SPEC 9.2: recorded, not added to stacks)"; return
  fi
  local probe; probe="$(bash "$BL_DIR/call.sh" "$BL_SD" hot_reload_probe | tail -n 1)"
  log "hotreload: $probe"
  rm -f "$BL_OUT/hotreload.jsonl"
  # the app needs a built debug engine + app tree first
  tm hotreload-prep build_dev || { SEC_STATUS=failed; SEC_REASON="build_dev before hot reload failed"; return; }
  "$PY" "$BL_DIR/hotreload.py" "$BASHX" "$BL_SD" "$probe" "$(wpath "$BL_DIR")/edit.sh" "$(wpath "$BL_OUT")/hotreload.jsonl" \
        "$BL_HOT_REPS" "$BL_HOT_WARMUP" 900
  local rc=$?
  # hotreload.py toggled the ui edit warmup+reps times through edit.sh (counted); restore below
  restore_edits
  [ $rc = 0 ] || { SEC_STATUS=failed; SEC_REASON="flutter run --machine driver failed (see hotreload.jsonl)"; }
}

# ------------------------------------------------------------------------------------------ 9.2 engine edit -> running app
sec_engine() {
  if ! is_flutter; then SEC_STATUS=skipped; SEC_REASON="not a Flutter stack"; return; fi
  local i
  rm -f "$BL_OUT/engine-build.jsonl" "$BL_OUT/engine-launch.jsonl" "$BL_OUT/engine-e2e.jsonl"
  tm engine-prime build_dev || { SEC_STATUS=failed; SEC_REASON="prime build_dev failed"; return; }
  for i in $(seq 1 "$BL_ENGINE_RUNS"); do
    edit leaf
    log "engine: rep $i leaf edit -> build_dev -> app --bench=startup"
    tm engine-build build_dev
    "$PY" "$BL_DIR/engine.py" launch "$BL_SD" "$(wpath "$BL_OUT")/engine-launch.jsonl" 180
  done
  restore_edits
  "$PY" "$BL_DIR/engine.py" combine "$BL_OUT/engine-build.jsonl" "$BL_OUT/engine-launch.jsonl" "$BL_OUT/engine-e2e.jsonl"
  if grep -q '"ok": false' "$BL_OUT/engine-e2e.jsonl"; then
    SEC_STATUS=failed; SEC_REASON="app did not report BENCH startup (see engine-launch.jsonl)"
  fi
}

# ------------------------------------------------------------------------------------------ 9.4 cache footprint
fp() { "$PY" "$BL_DIR/bl.py" footprint "$BL_SD" "$@"; }   # prints JSON on stdout

sec_footprint() {
  local n every="$BL_SIZE_EVERY" cyc="$BL_CYCLES" f="$BL_OUT/footprint"
  mkdir -p "$f"
  rm -f "$BL_OUT"/footprint-*.jsonl
  tm footprint-clean clean_all
  fp > "$f/after-clean.json"
  log "footprint: cold build_dev"
  tm footprint-cold-dev build_dev || { SEC_STATUS=failed; SEC_REASON="cold build_dev failed"; return; }
  fp --baseline "$f/after-clean.json" > "$f/cycle-0.json"
  log "footprint: $cyc leaf+struct cycles (each: edit, build_check, build_dev, for leaf then struct)"
  for n in $(seq 1 "$cyc"); do
    edit leaf;   tm footprint-cycle-leaf-check build_check;   tm footprint-cycle-leaf-dev build_dev
    edit struct; tm footprint-cycle-struct-check build_check; tm footprint-cycle-struct-dev build_dev
    if [ $((n % every)) = 0 ] || [ "$n" = "$cyc" ]; then fp --baseline "$f/after-clean.json" > "$f/cycle-$n.json"; fi
  done
  restore_edits
  "$PY" - "$(wpath "$f")" "$cyc" <<'PYEOF'
import glob, json, os, re, sys
d, cyc = sys.argv[1], int(sys.argv[2])
pts = []
for p in glob.glob(os.path.join(d, "cycle-*.json")):
    j = json.load(open(p)); j["cycles"] = int(re.search(r"cycle-(\d+)\.json", p).group(1)); pts.append(j)
pts.sort(key=lambda j: j["cycles"])
out = {"cycles_requested": cyc,
       "after_clean": json.load(open(os.path.join(d, "after-clean.json"))),
       "cold_dev": pts[0] if pts else None,
       "after_cycles": pts[-1] if pts else None,
       "growth_bytes": (pts[-1]["total_bytes"] - pts[0]["total_bytes"]) if pts else None,
       "series": [{"cycles": j["cycles"], "total_bytes": j["total_bytes"]} for j in pts]}
json.dump(out, open(os.path.join(os.path.dirname(d), "footprint.json"), "w"), indent=1)
print("footprint: cold %.0f MB -> after %d cycles %.0f MB" % (pts[0]["total_bytes"] / 2**20, cyc, pts[-1]["total_bytes"] / 2**20))
PYEOF
}

# ------------------------------------------------------------------------------------------ 9.5 where build time goes
sec_breakdown() {
  local tools; tools="$(stack_toolchains)"
  local d="$BL_OUT/breakdown" which t since tr
  mkdir -p "$d"
  local linkenv=()
  if [ -n "$BL_LINK_TIMER" ]; then
    if [ -n "$BL_WIN" ]; then
      echo '{"link_timer":"unsupported on Windows: rustc only discovers the MSVC environment when it runs link.exe itself"}' > "$d/link-timer.json"
    elif [[ " $tools " == *" cargo "* ]]; then
      local triple; triple="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p' | tr 'a-z-' 'A-Z_')"
      linkenv=("CARGO_TARGET_${triple}_LINKER=$HARNESS/shims/link-timer" "LINK_TIMER_REAL=${LINK_TIMER_REAL:-cc}")
    fi
  fi
  for which in cold-dev struct-dev; do
    tr="$d/$which-trace"; rm -rf "$tr"; mkdir -p "$tr"
    if [ "$which" = cold-dev ]; then
      bash "$BL_DIR/call.sh" "$BL_SD" clean_all >/dev/null 2>&1
    else
      edit struct
    fi
    since=$(( $(date +%s) - 1 ))
    log "breakdown: $which (toolchains: $tools)"
    rm -f "$BL_OUT/breakdown-$which.jsonl"
    ( [ ${#linkenv[@]} -gt 0 ] && export "${linkenv[@]}"
      export LINK_TIMER_LOG="$(wpath "$tr")/links.jsonl" BL_TRACE_DIR="$(wpath "$tr")"
      tm "breakdown-$which" build_dev )
    for t in $tools; do
      "$PY" "$BL_DIR/bl.py" breakdown "$t" "$(wpath "$tr")" "$BL_SD" "$since" > "$d/$which-$t.json" 2>"$d/$which-$t.err" \
        || log "breakdown: parser for $t failed (see $d/$which-$t.err)"
    done
  done
  restore_edits
}

# ------------------------------------------------------------------------------------------ 9.3 Zig incremental probe
sec_zigincr() {
  if [[ " $(stack_toolchains) " != *" zig "* ]]; then SEC_STATUS=skipped; SEC_REASON="no Zig in this stack"; return; fi
  local mode
  rm -f "$BL_OUT"/zigwatch-*.json
  tm zigincr-prime build_check
  for mode in plain incremental; do
    log "zigincr: zig build --watch ($mode), build_check"
    "$PY" "$BL_DIR/zigwatch.py" "$BASHX" "$BL_SD" "$(wpath "$BL_DIR")/call.sh" "$(wpath "$BL_DIR")/edit.sh" \
          "$mode" build_check "$(wpath "$BL_OUT")/zigwatch-$mode.json" "$BL_ZIGWATCH_REPS" 600
  done
  restore_edits
  if grep -q '"supported": false' "$BL_OUT/zigwatch-incremental.json"; then
    SEC_STATUS=unsupported; SEC_REASON="zig build --watch -fincremental produced no rebuild summary (see zigwatch-incremental.json)"
  fi
}

# ------------------------------------------------------------------------------------------ 9.6 / 9.7 (Linux only)
sec_contention() {
  bash "$BL_DIR/contention.sh" "$BL_STACK" "$BL_SD" "$BL_OUT"
  local rc=$?
  if [ $rc = 3 ]; then SEC_STATUS=skipped; SEC_REASON="Linux-only (SPEC 15.4)"; elif [ $rc != 0 ]; then SEC_STATUS=failed; SEC_REASON="contention.sh exit $rc"; fi
}

#!/usr/bin/env bash
# Build-loop measurement driver (SPEC 9).  Linux and Git bash on Windows.
#
#   harness/buildloop/run.sh <stack|dir> [section ...] [options]
#
# Sections (default: cold edits hotreload engine footprint breakdown; "all" adds zigincr and contention):
#   cold        9.1  clean_all + each build_*_release and build_dev, hyperfine --runs 3
#   edits       9.2  no-op + leaf/struct/server/ui edits, build_check and build_dev, hyperfine --warmup 1 --runs 10
#   hotreload   9.2  Flutter hot reload via the stack's hot_reload_probe (recorded "not-implemented" if absent)
#   engine      9.2  Flutter: leaf edit -> build_dev -> app --bench=startup first frame
#   footprint   9.4  build-output size after cold build_dev and after N leaf+struct cycles
#   breakdown   9.5  deps/frontend/codegen/link/tools split for one cold build_dev and one struct edit
#   zigincr     9.3  Zig only: zig build --watch with and without -fincremental (recorded "unsupported" if it does not work)
#   contention  9.6  multi-agent contention (Linux only; on Windows records "skipped: Linux-only (SPEC 15.4)")
#   (9.7 whole-run accounting is harness/sample.sh, run around an agent session; see README)
#
# Options:
#   --quick              smoke settings: 1 run, no warmup, 2 cache cycles, 1 engine / hot-reload rep, cold targets cli + dev
#   --cold-runs N (3)  --runs N (10)  --warmup N (1)  --cycles N (50)  --size-every N (10)
#   --engine-runs N (3)  --hot-reps N (10)  --zig-reps N (5)
#   --cold-targets "cli server desktop web [web_wasm] dev"   (default: all that stack.sh defines)
#   --link-timer         wire harness/shims/link-timer in as the Rust linker during `breakdown` (Linux)
#   --out-root DIR       records root (default results/$F2D_RUN/$F2D_MACHINE_ID/buildloop; smoke: .../buildloop-smoke)
#
# Env: F2D_RUN (run1)  F2D_MACHINE_ID (set by harness/machine-env.sh on Windows; else linux-<arch>)
#      F2D_BUILDLOOP_ROOT (same as --out-root)
# Records land in <root>/<stack>/ ; see harness/buildloop/README.md for the schema.
set -u
BL_HERE="$(cd "$(dirname "$0")" && pwd)"
STACK_ARG="${1:-}"
[ -n "$STACK_ARG" ] && [ "${STACK_ARG#-}" = "$STACK_ARG" ] || { sed -n '2,28p' "$0"; exit 64; }
shift

BL_QUICK=; BL_COLD_RUNS=3; BL_RUNS=10; BL_WARMUP=1; BL_CYCLES=50; BL_SIZE_EVERY=10
BL_ENGINE_RUNS=3; BL_HOT_REPS=10; BL_HOT_WARMUP=1; BL_ZIGWATCH_REPS=5; BL_COLD_TARGETS=; BL_LINK_TIMER=
SECTIONS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) BL_QUICK=1 ;;
    --cold-runs) BL_COLD_RUNS="$2"; shift ;;
    --runs) BL_RUNS="$2"; shift ;;
    --warmup) BL_WARMUP="$2"; shift ;;
    --cycles) BL_CYCLES="$2"; shift ;;
    --size-every) BL_SIZE_EVERY="$2"; shift ;;
    --engine-runs) BL_ENGINE_RUNS="$2"; shift ;;
    --hot-reps) BL_HOT_REPS="$2"; shift ;;
    --zig-reps) BL_ZIGWATCH_REPS="$2"; shift ;;
    --cold-targets) BL_COLD_TARGETS="$2"; shift ;;
    --link-timer) BL_LINK_TIMER=1 ;;
    --out-root) export F2D_BUILDLOOP_ROOT="$2"; shift ;;
    --*) echo "unknown option $1" >&2; exit 64 ;;
    *) SECTIONS+=("$1") ;;
  esac
  shift
done
if [ -n "$BL_QUICK" ]; then   # explicit options given earlier on the command line are overridden only where --quick is stricter
  BL_COLD_RUNS=1; BL_RUNS=1; BL_WARMUP=0; BL_CYCLES=2; BL_SIZE_EVERY=1; BL_ENGINE_RUNS=1; BL_HOT_REPS=1; BL_HOT_WARMUP=0; BL_ZIGWATCH_REPS=1
fi

source "$BL_HERE/lib.sh"
resolve_stack "$STACK_ARG" || exit 2
BL_OUT="$BL_ROOT/$BL_STACK"; mkdir -p "$BL_OUT/logs" "$BL_OUT/sections"
export BL_STACK BL_SD BL_OUT BL_ROOT

if [ -z "$BL_COLD_TARGETS" ]; then
  BL_COLD_TARGETS="cli server desktop web"; stack_has build_web_wasm_release && BL_COLD_TARGETS+=" web_wasm"
  BL_COLD_TARGETS+=" dev"
  [ -n "$BL_QUICK" ] && BL_COLD_TARGETS="cli dev"
fi
[ ${#SECTIONS[@]} -gt 0 ] || SECTIONS=(cold edits hotreload engine footprint breakdown)
if [ "${SECTIONS[0]}" = all ]; then SECTIONS=(cold edits hotreload engine footprint breakdown zigincr contention); fi

command -v hyperfine >/dev/null || { echo "buildloop: hyperfine not found on PATH" >&2; exit 127; }
source "$BL_HERE/sections.sh"

# ---- meta.json (what was measured, with what settings, where)
"$PY" - "$(wpath "$BL_OUT")" <<PYEOF
import json, os, platform, subprocess, sys, time
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception: return None
d = sys.argv[1]
meta = {"stack": "$BL_STACK", "stack_dir": "$BL_SD", "run": "$F2D_RUN", "machine": "$F2D_MACHINE_ID", "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "quick": bool("$BL_QUICK"), "sections": "${SECTIONS[*]}".split(), "toolchains": "$(stack_toolchains)".split(),
        "params": {"cold_runs": $BL_COLD_RUNS, "runs": $BL_RUNS, "warmup": $BL_WARMUP, "cycles": $BL_CYCLES, "size_every": $BL_SIZE_EVERY,
                   "engine_runs": $BL_ENGINE_RUNS, "hot_reps": $BL_HOT_REPS, "cold_targets": "$BL_COLD_TARGETS".split()},
        "platform": platform.platform(), "cpu_count": os.cpu_count(), "hyperfine": sh("hyperfine --version"),
        "repo_commit": sh("git -C '$REPO' rev-parse --short HEAD"), "goflags": os.environ.get("GOFLAGS", ""),
        "measure_method": "cgroup" if (sys.platform == "linux") else "psutil-fallback"}
json.dump(meta, open(os.path.join(d, "meta.json"), "w"), indent=1)
PYEOF

# Always leave the stack exactly as found, even on ^C
trap 'restore_edits' EXIT
trap 'log "interrupted"; exit 130' INT TERM

for s in "${SECTIONS[@]}"; do
  if ! declare -f "sec_$s" >/dev/null; then echo "unknown section: $s" >&2; continue; fi
  SEC_STATUS=ok; SEC_REASON=""
  log "=== $BL_STACK: section $s (quick=${BL_QUICK:-0}) ==="
  t0=$(date +%s)
  "sec_$s"
  t1=$(date +%s)
  printf '{"section":"%s","status":"%s","reason":"%s","wall_s":%d,"finished":"%s"}\n' \
    "$s" "$SEC_STATUS" "${SEC_REASON//\"/\'}" $((t1 - t0)) "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$BL_OUT/sections/$s.json"
  log "section $s: $SEC_STATUS${SEC_REASON:+ ($SEC_REASON)} in $((t1 - t0)) s"
  "$PY" "$BL_DIR/bl.py" summary "$(wpath "$BL_OUT")" >/dev/null
done

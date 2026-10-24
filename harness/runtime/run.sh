#!/usr/bin/env bash
# Runtime / size harness driver (SPEC 8.2-8.8). usage:
#   harness/runtime/run.sh <stack> [sections...] [--quick] [--no-alt] [--runs N]
# sections: meta build loc cli desktop web binsize server hood xcompile   (default: all, in that order; binsize always runs before server)
# --quick : 1 run each, oha 5 s, small sweeps; output goes to results/<run>/<machine>/runtime-smoke/<stack>/ instead of .../runtime/<stack>/
# env     : F2D_RUN (run1) F2D_MACHINE_ID (from machine-env.sh) F2D_PLAYWRIGHT_DIR F2D_PW_ARGS F2D_PORT F2D_RESULTS_SUBDIR PYTHON
# Builds only via stack.sh build_*_release (section `build`); the other sections read artifacts.json written there.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STACK="${1:-}"; [ -n "$STACK" ] || { sed -n '2,8p' "$0"; exit 2; }; shift
case "$STACK" in rust|go|zig|rust-flutter|zig-flutter|go-flutter|go-zig-flutter) ;; *) echo "unknown stack $STACK" >&2; exit 2;; esac

SECTIONS=(); QUICK=""; NOALT=""; RUNS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1;;
    --no-alt) NOALT=1;;
    --runs) RUNS="$2"; shift;;
    meta|build|loc|cli|desktop|web|server|binsize|xcompile|hood) SECTIONS+=("$1");;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac; shift
done
[ ${#SECTIONS[@]} -gt 0 ] || SECTIONS=(meta build loc cli desktop web binsize server hood xcompile)
# binsize must run before server: some stacks' run_server rebuilds a dev binary over the release one
if [[ " ${SECTIONS[*]} " == *" server "* && " ${SECTIONS[*]} " == *" binsize "* ]]; then
  _s=(); for s in "${SECTIONS[@]}"; do [ "$s" = binsize ] || _s+=("$s"); [ "$s" = server ] && { _s=("${_s[@]:0:${#_s[@]}-1}" binsize server); }; done
  SECTIONS=("${_s[@]}"); unset _s
fi

# toolchain PATH pins + machine id (Windows); nothing on Linux
source "$ROOT/harness/machine-env.sh"
export F2D_RUN="${F2D_RUN:-run1}"
if [ -z "${PYTHON:-}" ]; then
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) PYTHON=python;; *) PYTHON="$(command -v python3 || command -v python)";; esac
fi
# native Windows python must not see the WSL `bash` stub: hand it the bash that is running us
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export F2D_BASH="$(cygpath -m "$BASH")";; *) export F2D_BASH="$BASH";; esac
if [ -n "${F2D_PLAYWRIGHT_DIR:-}" ]; then export F2D_PLAYWRIGHT_DIR; fi
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
QARG=(); [ -n "$QUICK" ] && QARG=(--quick)

OUT="$("$PYTHON" -c "import sys; sys.path.insert(0,r'$(cd "$HERE" && (cygpath -m "$PWD" 2>/dev/null || pwd))'); import f2d; print(f2d.out_dir('$STACK', bool('$QUICK')))")"
echo "[$STACK] sections: ${SECTIONS[*]}  quick=${QUICK:-0}  out=$OUT"
TIMING="$OUT/timing.json"; [ -f "$TIMING" ] || echo "{}" > "$TIMING"   # merged across invocations
rc_all=0
for s in "${SECTIONS[@]}"; do
  t0=$(date +%s)
  case "$s" in
    meta)     script=meta.py;;
    build)    script=build.py;;
    loc)      script=loc.py;;
    cli)      script=cli_bench.py;;
    desktop)  script=desktop_bench.py;;
    web)      script=web_bench.py;;
    server)   script=server_bench.py;;
    binsize)  script=binsize.py;;
    xcompile) script=xcompile.py;;
    hood)     script=hood.py;;
  esac
  extra=()
  case "$s" in
    cli)     [ -n "$RUNS" ] && extra=(--reps "$RUNS");;
    desktop) [ -n "$RUNS" ] && extra=(--runs "$RUNS");;
    web)     [ -n "$RUNS" ] && extra=(--runs "$RUNS"); [ -n "$NOALT" ] && extra+=(--no-alt);;
  esac
  "$PYTHON" "$HERE/$script" "$STACK" "${QARG[@]}" "${extra[@]}" --out "$OUT" 2>&1 | tee -a "$OUT/logs/driver.log"
  rc=${PIPESTATUS[0]}
  t1=$(date +%s)
  "$PYTHON" - "$TIMING" "$s" "$((t1 - t0))" "$rc" <<'PY'
import json, sys
p, s, secs, rc = sys.argv[1:5]
d = json.load(open(p)); d[s] = {"wall_s": int(secs), "rc": int(rc)}; json.dump(d, open(p, "w"), indent=2)
PY
  if [ "$rc" -ne 0 ]; then rc_all=1; echo "[$STACK] SECTION $s FAILED (rc=$rc)" >&2; [ "$s" = build ] && break; fi
done
echo "[$STACK] done rc=$rc_all  records in $OUT"
exit $rc_all

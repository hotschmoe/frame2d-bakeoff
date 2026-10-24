#!/usr/bin/env bash
# Shared setup for the build-loop harness (SPEC 9). Source it; it defines paths and helpers, runs nothing.
# Works on Linux and under Git bash on Windows.

BL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$BL_DIR/.." && pwd)"
REPO="$(cd "$HARNESS/.." && pwd)"
source "$HARNESS/machine-env.sh"          # pinned PATH on Windows; sets F2D_MACHINE_ID there

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) BL_WIN=1 ;; *) BL_WIN= ;; esac
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi

export F2D_RUN="${F2D_RUN:-run1}"
if [ -z "${F2D_MACHINE_ID:-}" ]; then
  case "$(uname -m)" in aarch64|arm64) _a=aarch64 ;; *) _a=x64 ;; esac
  export F2D_MACHINE_ID="linux-$_a"; unset _a
fi
# Records root. The real campaign uses the default; smoke tests set F2D_BUILDLOOP_ROOT.
BL_ROOT="${F2D_BUILDLOOP_ROOT:-$REPO/results/$F2D_RUN/$F2D_MACHINE_ID/buildloop}"

# Native-looking path for programs that are not MSYS-aware (Python, hyperfine): C:/... on Windows.
wpath() { if [ -n "$BL_WIN" ]; then cygpath -m "$1"; else echo "$1"; fi; }
# The bash that hyperfine (--shell=none) must use. A bare "bash" on Windows can be the WSL stub.
if [ -n "$BL_WIN" ]; then
  BASHX="$(cygpath -ms /)"; BASHX="${BASHX%/}/bin/bash.exe"; [ -x "$BASHX" ] || BASHX="C:/PROGRA~1/Git/bin/bash.exe"
else
  BASHX=bash
fi
export F2D_BASH="${F2D_BASH:-$BASHX}"

# sq a b c  ->  a b c   hyperfine's --prepare goes through cmd.exe on Windows, whose quote stripping breaks any command line
# with more than two quote characters. So no quoting at all: every argument must be free of spaces and shell characters.
# Windows paths are therefore passed in their 8.3 short form (cygpath -ms) where they may contain spaces (Program Files).
sq() { local o="" a; for a in "$@"; do o+="$a "; done; printf '%s' "${o% }"; }

# Resolve a stack argument (name under stacks/, or any directory) to BL_STACK (name) and BL_SD (dir, native form).
resolve_stack() {
  local s="$1" d
  if [ -d "$REPO/stacks/$s" ]; then d="$REPO/stacks/$s"
  elif [ -d "$s" ]; then d="$(cd "$s" && pwd)"
  else echo "buildloop: no such stack: $s" >&2; return 1; fi
  [ -f "$d/stack.sh" ] || { echo "buildloop: $d/stack.sh missing" >&2; return 1; }
  BL_STACK="$(basename "$d")"; BL_SD="$(wpath "$d")"
}

# Does stack.sh define function $1?  (checked in a subshell; sourcing stack.sh cd's, so never source it in the driver)
stack_has() { "$BASHX" "$BL_DIR/call.sh" "$BL_SD" --has "$1" >/dev/null 2>&1; }

# Toolchains used by a stack, from its files: cargo go zig flutter
stack_toolchains() {
  local d="$BL_SD" t=""
  [ -f "$d/Cargo.toml" ] && t+="cargo "
  [ -f "$d/go.mod" ] && t+="go "
  [ -f "$d/build.zig" ] && t+="zig "
  [ -f "$d/app/pubspec.yaml" ] && t+="flutter "
  echo $t
}
is_flutter() { [ -f "$BL_SD/app/pubspec.yaml" ]; }

# tm <label> <fn> [args]   one measured (not hyperfine) run of a stack function; appends a record to
#                          $BL_OUT/<label>.jsonl via measure.sh. Output goes to $BL_OUT/logs/<label>.log.
tm() {
  local label="$1"; shift
  mkdir -p "$BL_OUT/logs"
  RESULTS_DIR="$BL_ROOT" BL_LOG="$(wpath "$BL_OUT")/logs/$label.log" \
    bash "$HARNESS/measure.sh" "$BL_STACK" "$label" -- bash "$(wpath "$BL_DIR")/call.sh" "$BL_SD" "$@"
}

# Edit helpers (toggles are counted so every edit can be undone exactly; see edit.sh)
edit() { bash "$BL_DIR/edit.sh" "$BL_SD" "$1"; }
restore_edits() { bash "$BL_DIR/edit.sh" "$BL_SD" --restore; }

log() { echo "[buildloop $(date +%H:%M:%S)] $*" >&2; }

# hf <name> <runs> <warmup> <prepare> <label>=<fn> ...
#   One hyperfine invocation measuring one or more stack functions, each wrapped in measure.sh (SPEC 9.1/9.2).
#   <prepare> is a stack function (e.g. clean_all), "edit:<name>" (toggle a harness edit) or "" (none).
#   Records: $BL_OUT/<label>.jsonl (warmup records are moved to <label>.warmup.jsonl), $BL_OUT/hyperfine/<name>.json
hf() {
  local name="$1" runs="$2" warm="$3" prep="$4"; shift 4
  command -v hyperfine >/dev/null || { echo "buildloop: hyperfine not found" >&2; return 127; }
  mkdir -p "$BL_OUT/hyperfine" "$BL_OUT/logs"
  local args=(--runs "$runs" --warmup "$warm" --shell=none --style basic --export-json "$(wpath "$BL_OUT")/hyperfine/$name.json")
  case "$prep" in
    "") ;;
    edit:*) args+=(--prepare "$(sq "$BASHX" "$(wpath "$BL_DIR")/edit.sh" "$BL_SD" "${prep#edit:}")") ;;
    *)      args+=(--prepare "$(sq "$BASHX" "$(wpath "$BL_DIR")/call.sh" "$BL_SD" "$prep")") ;;
  esac
  local lf fn label labels=()
  for lf in "$@"; do
    label="${lf%%=*}"; fn="${lf#*=}"; labels+=("$label")
    rm -f "$BL_OUT/$label.jsonl" "$BL_OUT/$label.warmup.jsonl"
    # measure.sh's fallback resolves a bare "bash" to Git bash on Windows (measure_fallback.py)
    args+=(--command-name "$label" "$(sq "$BASHX" "$(wpath "$HARNESS")/measure.sh" "$BL_STACK" "$label" -- bash "$(wpath "$BL_DIR")/call.sh" "$BL_SD" $fn)")
  done
  RESULTS_DIR="$(wpath "$BL_ROOT")" BL_LOG="$(wpath "$BL_OUT")/logs/$name.log" hyperfine "${args[@]}"
  local rc=$?
  for label in "${labels[@]}"; do "$PY" "$BL_DIR/bl.py" trim "$(wpath "$BL_OUT")/$label.jsonl" "$warm"; done
  return $rc
}

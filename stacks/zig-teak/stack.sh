#!/usr/bin/env bash
# stack.sh for stacks/zig-teak/ (SPEC 5.6). Source this file; call the functions. Everything is relative
# to this file's directory. All toolchain flags live here, never in the caller.
# Each build_* prints the path of its artifact on the LAST line of stdout.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

_EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) _EXE=".exe" ;; esac
_JOBS=()
[ -n "${F2D_ZIG_JOBS:-}" ] && _JOBS=(-j"$F2D_ZIG_JOBS")

_zig() { (cd "$STACK_DIR" && zig build "${_JOBS[@]}" "$@"); }

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Kept: zig-pkg/ (Zig 0.17 project-local package sources: teak, zunk, sqlite, wgpu-native) and
#   the global cache's p/ (package archives). Removed: .zig-cache/, zig-out/, dist/, and the
#   compiled part of the global cache (o/, h/, z/, tmp/).
clean_all() {
  rm -rf "$STACK_DIR/.zig-cache" "$STACK_DIR/zig-out" "$STACK_DIR/dist"
  local g; g="$(zig env 2>/dev/null | sed -n 's/.*"global_cache_dir": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -z "$g" ] && g="${LOCALAPPDATA:-$HOME/.cache}/zig"
  for d in o h z tmp; do rm -rf "$g/$d"; done
}

build_cli_release() {
  _zig cli -Doptimize=ReleaseFast --prefix "$STACK_DIR/zig-out/release" >&2 || return 1
  echo "$STACK_DIR/zig-out/release/bin/frame2d$_EXE"
}
build_server_release() {
  _zig server -Doptimize=ReleaseFast --prefix "$STACK_DIR/zig-out/release" >&2 || return 1
  echo "$STACK_DIR/zig-out/release/bin/frame2d-server$_EXE"
}
build_desktop_release() {
  _zig desktop -Doptimize=ReleaseFast --prefix "$STACK_DIR/zig-out/release" >&2 || return 1
  echo "$STACK_DIR/zig-out/release/bin/frame2d-app$_EXE"
}
build_web_release() {
  _zig web -Doptimize=ReleaseFast >&2 || return 1
  echo "$STACK_DIR/dist"
}

build_check() { _zig check; }   # compile every target, no install
build_dev()   { _zig cli server desktop; }   # Debug profile, the targets the agent rebuilds

run_server() {
  _zig server -Doptimize=ReleaseFast --prefix "$STACK_DIR/zig-out/release" >&2 || return 1
  exec "$STACK_DIR/zig-out/release/bin/frame2d-server$_EXE"
}
test_all() { _zig test --summary all; }
deps_report() {
  # direct + transitive packages fetched into zig-pkg/ (teak pulls zunk and its deps, wgpu-native)
  ls -1 "$STACK_DIR/zig-pkg" 2>/dev/null
}

# bounded: limit parallel build jobs to ${BENCH_JOBS:-nproc/4} (zig build -j).
bounded() {
  local n; n="$(nproc 2>/dev/null || echo 4)"
  export F2D_ZIG_JOBS="${BENCH_JOBS:-$(( n / 4 > 0 ? n / 4 : 1 ))}"
  _JOBS=(-j"$F2D_ZIG_JOBS")
}

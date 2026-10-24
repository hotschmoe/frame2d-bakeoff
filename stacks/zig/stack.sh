#!/usr/bin/env bash
# stack.sh for stacks/zig (SPEC 5.6). Source this file; call the functions. Everything is relative
# to this file's directory. All toolchain flags live here, never in the caller.
# Each build_* prints the path of its artifact on the LAST line of stdout.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

# The Zig global cache lives inside the stack dir so clean_all can drop compiled output without
# touching other stacks or the machine-wide cache. Package sources stay in .zig-global/p.
export ZIG_GLOBAL_CACHE_DIR="$STACK_DIR/.zig-global"

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;; *) EXE="" ;; esac

# Release flags: ReleaseFast everywhere (native and wasm), binaries stripped by build.zig.
ZIG_RELEASE=(-Doptimize=ReleaseFast)
ZIG_JOBS=()      # filled by `bounded`

_zb() { zig build "${ZIG_JOBS[@]}" "$@" >&2; }

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Kept: .zig-global/p (fetched package sources: dvui, SDL3, freetype, sqlite, ...).
#   Removed: zig-out/, .zig-cache/, and .zig-global/{o,h,z,tmp} (compiled artifacts).
clean_all() {
  rm -rf "$STACK_DIR/zig-out" "$STACK_DIR/.zig-cache" \
         "$STACK_DIR/.zig-global/o" "$STACK_DIR/.zig-global/h" "$STACK_DIR/.zig-global/z" "$STACK_DIR/.zig-global/tmp"
}

build_cli_release()     { _zb cli "${ZIG_RELEASE[@]}" && echo "$STACK_DIR/zig-out/bin/frame2d$EXE"; }
build_server_release()  { _zb server "${ZIG_RELEASE[@]}" && echo "$STACK_DIR/zig-out/bin/frame2d-server$EXE"; }
build_desktop_release() { _zb desktop "${ZIG_RELEASE[@]}" && echo "$STACK_DIR/zig-out/bin/frame2d-app$EXE"; }
build_web_release()     { _zb web "${ZIG_RELEASE[@]}" && echo "$STACK_DIR/zig-out/web"; }

# build_check: compile every target (cli, server, desktop, web) without emitting binaries.
build_check() { _zb check; }
# build_dev: debug build of every target the agent rebuilds.
build_dev()   { _zb install; }

run_server() {   # foreground; honors FRAME2D_ADDR (default 127.0.0.1:8080)
  _zb server "${ZIG_RELEASE[@]}" || return 1
  exec "$STACK_DIR/zig-out/bin/frame2d-server$EXE"
}
test_all()   { _zb test; }

# deps_report: the packages zig fetched (transitive set), one per line.
deps_report() {
  { grep -E '^\s+\.[a-z0-9_]+ = \.\{' "$STACK_DIR/build.zig.zon" | sed -E 's/^\s+\.([a-z0-9_]+).*/\1/'
    ls "$STACK_DIR/.zig-global/p" 2>/dev/null; } | sort -u
}

# bounded: limit parallel build jobs to ${BENCH_JOBS:-$(nproc)/4}.
bounded() {
  local n="${BENCH_JOBS:-$(( $(nproc 2>/dev/null || echo 4) / 4 ))}"
  [ "$n" -lt 1 ] && n=1
  ZIG_JOBS=("-j$n")
}

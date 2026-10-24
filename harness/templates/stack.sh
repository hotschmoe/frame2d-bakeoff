#!/usr/bin/env bash
# stack.sh for stacks/<stack>/ (SPEC 5.6). Source this file; call the functions. Everything is relative
# to this file's directory. All toolchain flags live here, never in the caller.
# Each build_* prints the path of its artifact on the LAST line of stdout.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Document here what is kept, e.g. cargo registry, go module cache, ~/.cache/zig/p, pub cache.
clean_all() { echo "TODO clean_all" >&2; return 1; }

build_cli_release()     { echo "TODO" >&2; return 1; }   # -> path to frame2d binary
build_server_release()  { echo "TODO" >&2; return 1; }   # -> path to server binary
build_desktop_release() { echo "TODO" >&2; return 1; }   # -> path to app executable or bundle
build_web_release()     { echo "TODO" >&2; return 1; }   # -> path to static web dir

build_check() { echo "TODO" >&2; return 1; }   # fastest "does it compile" loop
build_dev()   { echo "TODO" >&2; return 1; }   # dev-loop build: debug profile, all targets the agent rebuilds

run_server() { echo "TODO" >&2; return 1; }    # foreground; honors FRAME2D_ADDR (default 127.0.0.1:8080)
test_all()   { echo "TODO" >&2; return 1; }    # the stack's own unit tests
deps_report() { echo "TODO" >&2; return 1; }   # transitive dependency list, one per line

# bounded: limit parallel build jobs to ${BENCH_JOBS:-$(nproc)/4}. Export the toolchain's own setting,
# e.g. CARGO_BUILD_JOBS, GOMAXPROCS + `go build -p`, zig `-j`, CMAKE_BUILD_PARALLEL_LEVEL.
bounded() { echo "TODO" >&2; return 1; }

# Optional (Flutter stacks): hot_reload_probe() { ...; }

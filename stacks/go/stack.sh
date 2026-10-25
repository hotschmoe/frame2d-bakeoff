#!/usr/bin/env bash
# stack.sh for stacks/go (SPEC 5.6). Source this file; call the functions. Everything is relative
# to this file's directory. All toolchain flags live here, never in the caller.
# Each build_* prints the path of its artifact on the LAST line of stdout.
#
# Layout: cmd/frame2d (CLI), cmd/server (net/http + SQLite), cmd/app (Gio client, desktop + js/wasm),
# engine/ (solver). Outputs go to build/{release,dev}/.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

# CGO is off everywhere: Gio needs no cgo on Windows, SQLite is the pure-Go modernc driver, so every
# binary is static and cross-compiles without a C toolchain. (Gio on Linux/macOS needs CGO_ENABLED=1
# for the desktop app; _go_desktop_env handles that.)
export CGO_ENABLED=0
# One `go env` call for all three (each spawn costs 50-150 ms, and these used to run on every build).
{ read -r _EXE; read -r _GOOS; read -r _GOROOT; } < <(go env GOEXE GOOS GOROOT)
# -buildvcs=false: skip the per-build `git status` stamp (slow in a big monorepo and useless for these binaries).
_BASE_FLAGS=(-buildvcs=false)
_REL_FLAGS=("${_BASE_FLAGS[@]}" -trimpath -ldflags "-s -w")
_JS=(env GOOS=js GOARCH=wasm CGO_ENABLED=0)

_go_desktop_env() { case "$_GOOS" in windows|js) CGO_ENABLED=0 "$@";; *) CGO_ENABLED=1 "$@";; esac; }

# clean_all: remove build outputs and the Go build cache. KEEPS the module cache (downloaded sources).
clean_all() {
  rm -rf "$STACK_DIR/build"
  go clean -cache
}

build_cli_release() {
  go build "${_REL_FLAGS[@]}" -o "build/release/frame2d$_EXE" ./cmd/frame2d || return 1
  echo "$STACK_DIR/build/release/frame2d$_EXE"
}

build_server_release() {
  go build "${_REL_FLAGS[@]}" -o "build/release/server$_EXE" ./cmd/server || return 1
  echo "$STACK_DIR/build/release/server$_EXE"
}

# Windows keeps the console subsystem on purpose: BENCH lines are read from stdout.
build_desktop_release() {
  _go_desktop_env go build "${_REL_FLAGS[@]}" -o "build/release/app$_EXE" ./cmd/app || return 1
  echo "$STACK_DIR/build/release/app$_EXE"
}

build_web_release() {
  local out="$STACK_DIR/build/release/web"
  mkdir -p "$out"
  "${_JS[@]}" go build "${_REL_FLAGS[@]}" -o "$out/main.wasm" ./cmd/app || return 1
  cp "$_GOROOT/lib/wasm/wasm_exec.js" "$out/wasm_exec.js" && cp web/index.html "$out/index.html" || return 1
  echo "$out"
}

# _all: run the given command strings in parallel (each evaluated in a background subshell) and fail
# if any failed. Used so independent targets (host, js/wasm) overlap instead of queueing.
_all() {
  local pids=() rc=0 p
  for cmd in "$@"; do
    ( eval "$cmd" ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  return $rc
}

# build_check: vet (which type-checks every package and test file) for the host, plus vet of the js/wasm
# client (the web target compiles different files, so host-only checks miss errors in platform_js.go).
# The two run in parallel; a separate `go build ./...` is redundant with vet's type check and is not run.
build_check() {
  _all 'go vet ./...' '"${_JS[@]}" go vet ./cmd/app'
}

# _sync: copy src to dst only when the content differs (keeps mtimes stable on no-op builds).
_sync() { cmp -s "$1" "$2" 2>/dev/null || cp "$1" "$2"; }

# build_dev: debug-friendly (no strip) builds of every target the agent rebuilds. The CLI+server, the
# desktop app and the wasm client are independent go build invocations that run in parallel.
build_dev() {
  mkdir -p build/dev/web
  _all 'CGO_ENABLED=0 go build "${_BASE_FLAGS[@]}" -o build/dev/ ./cmd/frame2d ./cmd/server' \
       '_go_desktop_env go build "${_BASE_FLAGS[@]}" -o "build/dev/app$_EXE" ./cmd/app' \
       '"${_JS[@]}" go build "${_BASE_FLAGS[@]}" -o build/dev/web/main.wasm ./cmd/app' || return 1
  _sync "$_GOROOT/lib/wasm/wasm_exec.js" build/dev/web/wasm_exec.js && _sync web/index.html build/dev/web/index.html
}

run_server() {
  mkdir -p build/dev
  go build "${_BASE_FLAGS[@]}" -o "build/dev/server$_EXE" ./cmd/server || return 1
  export FRAME2D_DB="${FRAME2D_DB:-$STACK_DIR/build/dev/frame2d.sqlite}"
  rm -f "$FRAME2D_DB"
  exec "$STACK_DIR/build/dev/server$_EXE"
}

test_all() { go test ./...; }

# deps_report: transitive non-stdlib packages of all binaries, one per line.
deps_report() {
  go list -deps -f '{{if not .Standard}}{{.ImportPath}}{{end}}' ./cmd/... | sort -u
}

# bounded: cap parallel build jobs at ${BENCH_JOBS:-cores/4} (go build -p via GOFLAGS, and GOMAXPROCS).
bounded() {
  local cores jobs
  cores="$(nproc 2>/dev/null || echo 4)"
  jobs="${BENCH_JOBS:-$((cores / 4))}"
  [ "$jobs" -ge 1 ] || jobs=1
  export GOFLAGS="-p=$jobs" GOMAXPROCS="$jobs"
}

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
_EXE="$(go env GOEXE)"
_REL_FLAGS=(-trimpath -ldflags "-s -w")
_JS=(env GOOS=js GOARCH=wasm CGO_ENABLED=0)

_go_desktop_env() { case "$(go env GOOS)" in windows|js) CGO_ENABLED=0 "$@";; *) CGO_ENABLED=1 "$@";; esac; }

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
  cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" "$out/wasm_exec.js" && cp web/index.html "$out/index.html" || return 1
  echo "$out"
}

# build_check: vet + compile everything for the host, plus vet of the js/wasm client (the web target
# compiles different files, so host-only checks miss errors in platform_js.go).
build_check() {
  go vet ./... || return 1
  go build ./... || return 1
  "${_JS[@]}" go vet ./cmd/app
}

# build_dev: debug-friendly (no strip) builds of every target the agent rebuilds.
build_dev() {
  mkdir -p build/dev/web
  go build -o "build/dev/frame2d$_EXE" ./cmd/frame2d || return 1
  go build -o "build/dev/server$_EXE" ./cmd/server || return 1
  _go_desktop_env go build -o "build/dev/app$_EXE" ./cmd/app || return 1
  "${_JS[@]}" go build -o build/dev/web/main.wasm ./cmd/app || return 1
  cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" build/dev/web/wasm_exec.js && cp web/index.html build/dev/web/index.html
}

run_server() {
  mkdir -p build/dev
  go build -o "build/dev/server$_EXE" ./cmd/server || return 1
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

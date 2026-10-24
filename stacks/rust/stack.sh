#!/usr/bin/env bash
# stack.sh for stacks/rust/ (SPEC 5.6). Source this file; call the functions. Everything is relative
# to this file's directory. All toolchain flags live here, never in the caller.
# Each build_* prints the path of its artifact on the LAST line of stdout.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

# One crate, three binaries: frame2d (CLI, no extra deps), frame2d-server (feature "server"),
# frame2d-app (feature "ui", desktop and wasm32).
FEATURES="server,ui"
WASM_TARGET="wasm32-unknown-unknown"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe" ;; *) EXE="" ;; esac

# clean_all: removes target/ (all compiled output incl. compiled deps and the web dist dir).
#   KEEPS ~/.cargo/registry and ~/.cargo/git (downloaded crate sources).
clean_all() { cargo clean; }

build_cli_release() {
  cargo build --release --bin frame2d >&2 || return 1
  echo "$STACK_DIR/target/release/frame2d$EXE"
}

build_server_release() {
  cargo build --release --bin frame2d-server --features server >&2 || return 1
  echo "$STACK_DIR/target/release/frame2d-server$EXE"
}

build_desktop_release() {
  cargo build --release --bin frame2d-app --features ui >&2 || return 1
  echo "$STACK_DIR/target/release/frame2d-app$EXE"
}

# Web: cargo -> wasm32-unknown-unknown -> wasm-bindgen (no Emscripten, no trunk) -> static dir.
# wasm-opt is run when available (size only; failure is not fatal).
build_web_release() {
  cargo build --release --bin frame2d-app --features ui --target "$WASM_TARGET" >&2 || return 1
  local out="$STACK_DIR/target/web-dist"
  rm -rf "$out" && mkdir -p "$out"
  wasm-bindgen --target web --no-typescript --out-dir "$out" --out-name frame2d \
    "$STACK_DIR/target/$WASM_TARGET/release/frame2d-app.wasm" >&2 || return 1
  if command -v wasm-opt >/dev/null 2>&1; then
    wasm-opt -O3 --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext --enable-mutable-globals --enable-multivalue --enable-reference-types \
      -o "$out/frame2d_bg.opt.wasm" "$out/frame2d_bg.wasm" >&2 && mv "$out/frame2d_bg.opt.wasm" "$out/frame2d_bg.wasm"
  fi
  cp "$STACK_DIR/web/index.html" "$out/index.html"
  echo "$out"
}

build_check() { cargo check --all-targets --features "$FEATURES"; }

build_dev() { cargo build --features "$FEATURES"; }

run_server() {
  local bin
  bin="$(build_server_release | tail -n 1)" || return 1
  exec "$bin"
}

test_all() { cargo test --features "$FEATURES"; }

deps_report() {
  { cargo tree --features "$FEATURES" -e normal,build --prefix none --format "{p}"
    cargo tree --features "$FEATURES" -e normal,build --prefix none --format "{p}" --target "$WASM_TARGET"
  } | sed 's/ (.*//; s/ (\*)//' | sort -u
}

# bounded: limit parallel build jobs to ${BENCH_JOBS:-$(nproc)/4}.
bounded() {
  local n="${BENCH_JOBS:-$(( $(nproc 2>/dev/null || echo 4) / 4 ))}"
  [ "$n" -lt 1 ] && n=1
  export CARGO_BUILD_JOBS="$n"
}

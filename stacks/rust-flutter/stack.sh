#!/usr/bin/env bash
# stack.sh for stacks/rust-flutter/ (SPEC 5.6). Source this file; call the functions. Everything is relative
# to this file's directory. All toolchain flags live here, never in the caller.
# Each build_* prints the path of its artifact on the LAST line of stdout.
#
# Layout:  crates/engine  solver (pure Rust, no dependencies beyond serde)
#          crates/cli     `frame2d` binary          crates/server  axum + tokio + SQLite
#          crates/bridge  flutter_rust_bridge cdylib (desktop) and wasm-bindgen module (web)
#          app/           Flutter client (desktop + web)

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    EXE=".exe"
    # Flutter's Windows target is x64 on this machine (the SDK is x64, run under emulation), so the engine
    # DLL the app loads must be x64 too. The CLI and server use the native host target.
    DESKTOP_TARGET="x86_64-pc-windows-msvc"
    DESKTOP_DIR="windows"; BRIDGE_LIB="frame2d_bridge.dll"
    FLUTTER_BUNDLE_SUBDIR="build/windows/x64/runner" ;;
  Darwin)
    EXE=""; DESKTOP_TARGET="$(rustc -vV | sed -n 's/^host: //p')"
    DESKTOP_DIR="macos"; BRIDGE_LIB="libframe2d_bridge.dylib"; FLUTTER_BUNDLE_SUBDIR="build/macos/Build/Products" ;;
  *)
    EXE=""; DESKTOP_TARGET="$(rustc -vV | sed -n 's/^host: //p')"
    DESKTOP_DIR="linux"; BRIDGE_LIB="libframe2d_bridge.so"
    case "$(uname -m)" in aarch64|arm64) FLUTTER_BUNDLE_SUBDIR="build/linux/arm64";; *) FLUTTER_BUNDLE_SUBDIR="build/linux/x64";; esac ;;
esac
WASM_TARGET="wasm32-unknown-unknown"
APP_DIR="$STACK_DIR/app"
WEB_ENGINE_DIR="$APP_DIR/web/engine"

# WebAssembly SIMD is on by default in every shipping browser; the skyline dot products benefit.
WASM_RUSTFLAGS="-C target-feature=+simd128"

# --- internal helpers -------------------------------------------------------------------------------------

_cargo_wasm() { RUSTFLAGS="$WASM_RUSTFLAGS" cargo "$@"; }

# _bridge_desktop <debug|release>: builds the engine cdylib for the Flutter desktop target and exports its
# path as F2D_BRIDGE_DLL for app/windows/CMakeLists.txt to bundle.
_bridge_desktop() {
  local profile="$1" flag=""
  [ "$profile" = release ] && flag="--release"
  cargo build $flag -p frame2d-bridge --target "$DESKTOP_TARGET" || return 1
  export F2D_BRIDGE_DLL="$STACK_DIR/target/$DESKTOP_TARGET/$profile/$BRIDGE_LIB"
}

# _bridge_wasm <debug|release>: builds the engine for the browser and runs wasm-bindgen into app/web/engine.
_bridge_wasm() {
  local profile="$1" flag=""
  [ "$profile" = release ] && flag="--release"
  _cargo_wasm build $flag -p frame2d-bridge --target "$WASM_TARGET" || return 1
  mkdir -p "$WEB_ENGINE_DIR"
  wasm-bindgen --target web --no-typescript --out-dir "$WEB_ENGINE_DIR" --out-name frame2d_engine \
    "$STACK_DIR/target/$WASM_TARGET/$profile/frame2d_bridge.wasm" || return 1
  if [ "$profile" = release ]; then
    wasm-opt -O3 --enable-simd --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext \
      --enable-mutable-globals -o "$WEB_ENGINE_DIR/frame2d_engine_bg.wasm" "$WEB_ENGINE_DIR/frame2d_engine_bg.wasm" || return 1
  fi
}

_flutter() { (cd "$APP_DIR" && flutter "$@"); }

# --- SPEC 5.6 interface -----------------------------------------------------------------------------------

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Removed: target/ (all compiled Rust), app/build, app/.dart_tool (flutter clean), app/web/engine (wasm output).
#   Kept:    ~/.cargo/registry and ~/.cargo/git (crate sources), the Dart pub cache, app/pubspec.lock.
clean_all() {
  cargo clean || return 1
  _flutter clean || return 1
  rm -rf "$WEB_ENGINE_DIR"
}

build_cli_release() {
  cargo build --release -p frame2d-cli >&2 || return 1
  echo "$STACK_DIR/target/release/frame2d$EXE"
}

build_server_release() {
  cargo build --release -p frame2d-server >&2 || return 1
  echo "$STACK_DIR/target/release/frame2d-server$EXE"
}

build_desktop_release() {
  _bridge_desktop release >&2 || return 1
  _flutter build "$DESKTOP_DIR" --release >&2 || return 1
  echo "$APP_DIR/$FLUTTER_BUNDLE_SUBDIR/Release/frame2d_app$EXE"
}

# build_web_release: both Flutter web builds. build/web_js is the default (JS) build, build/web_wasm the
# `--wasm` build. The last line is the default build's directory; the other is printed as "wasm: <dir>".
build_web_release() {
  _bridge_wasm release >&2 || return 1
  _flutter build web --release --no-web-resources-cdn --no-wasm-dry-run --output "$APP_DIR/build/web_js" >&2 || return 1
  _flutter build web --release --wasm --no-web-resources-cdn --output "$APP_DIR/build/web_wasm" >&2 || return 1
  echo "wasm: $APP_DIR/build/web_wasm"
  echo "$APP_DIR/build/web_js"
}

# build_check: cargo check on every target the code is compiled for, plus the Dart analyzer.
build_check() {
  cargo check --workspace --exclude frame2d-bridge || return 1
  cargo check -p frame2d-bridge --target "$DESKTOP_TARGET" || return 1
  _cargo_wasm check -p frame2d-bridge --target "$WASM_TARGET" || return 1
  _flutter analyze
}

# build_dev: debug profile of everything the agent normally rebuilds: CLI, server, engine DLL for desktop,
# engine WASM for web, and the Flutter desktop debug app.
build_dev() {
  cargo build -p frame2d-cli -p frame2d-server || return 1
  _bridge_desktop debug || return 1
  _bridge_wasm debug || return 1
  _flutter build "$DESKTOP_DIR" --debug
}

# run_server: foreground, honors FRAME2D_ADDR. Builds first, then execs the binary itself so that killing the
# shell that called this function stops the server (a `cargo run` parent would leave it orphaned).
run_server() {
  export FRAME2D_DB="${FRAME2D_DB:-$STACK_DIR/frame2d.db}"
  cargo build --release -p frame2d-server >&2 || return 1
  exec "$STACK_DIR/target/release/frame2d-server$EXE"
}

test_all() {
  cargo test --workspace --exclude frame2d-bridge || return 1
  cargo test -p frame2d-bridge || return 1
  _flutter test
}

deps_report() {
  { cargo tree --workspace --target all -e normal,build --prefix none --no-dedupe 2>/dev/null \
      | grep -v '^frame2d-' | grep -v '^$' | sed 's/ (\*)$//; s/ (proc-macro)$//' | awk '{print "cargo " $1 " " $2}'
    _flutter pub deps --style=list 2>/dev/null | sed -n 's/^- \([a-z_0-9]*\) \([0-9][^ ]*\).*/pub \1 \2/p'
  } | sort -u
}

# bounded: at most ${BENCH_JOBS:-nproc/4} parallel jobs for cargo and for Flutter's CMake/Ninja step.
bounded() {
  local cores jobs
  cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
  jobs="${BENCH_JOBS:-$((cores / 4))}"
  [ "$jobs" -ge 1 ] || jobs=1
  export CARGO_BUILD_JOBS="$jobs" CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
}

# --- extras (not part of the SPEC interface) --------------------------------------------------------------

# codegen: regenerate the flutter_rust_bridge glue after changing crates/bridge/src/api.rs.
codegen() { flutter_rust_bridge_codegen generate; }

# build_web_dev: engine WASM (debug) plus a Flutter web profile build, for looking at the page.
build_web_dev() {
  _bridge_wasm debug >&2 || return 1
  _flutter build web --profile --no-web-resources-cdn --no-wasm-dry-run --output "$APP_DIR/build/web_dev" >&2 || return 1
  echo "$APP_DIR/build/web_dev"
}

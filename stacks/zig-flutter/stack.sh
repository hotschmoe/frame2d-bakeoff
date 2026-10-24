#!/usr/bin/env bash
# stack.sh for stacks/zig-flutter/ (SPEC 5.6). Source this file; call the functions. Everything is relative
# to this file's directory. All toolchain flags live here, never in the caller.
# Each build_* prints the path of its artifact on the LAST line of stdout.
#
# Layout: src/engine (Zig engine), src/cli, src/server (Zig std.http + SQLite), src/bridge (C ABI exports,
#         compiled to a native shared library for dart:ffi and to wasm32 for the web),
#         app/ (Flutter UI; dart:ffi on desktop, dart:js_interop + WASM on web).

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

# A private Zig global cache so concurrent stacks never share compiled artifacts and clean_all is safe.
# Zig package sources are fetched into ./zig-pkg (and cached as tarballs in $ZIG_GLOBAL_CACHE_DIR/p).
export ZIG_GLOBAL_CACHE_DIR="$STACK_DIR/.zig-global"
export ZIG_LOCAL_CACHE_DIR="$STACK_DIR/.zig-cache"

APP_DIR="$STACK_DIR/app"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) EXE=".exe"; HOST_OS=windows; ENGINE_LIB="frame2d_engine.dll" ;;
  Darwin) EXE=""; HOST_OS=macos; ENGINE_LIB="libframe2d_engine.dylib" ;;
  *) EXE=""; HOST_OS=linux; ENGINE_LIB="libframe2d_engine.so" ;;
esac
# Flutter on win-arm64 runs the x64 SDK and produces x64 Windows apps, so the desktop engine library
# must be x86_64 there. Everywhere else the native target is right.
DESKTOP_ZIG_ARGS=()
if [ "$HOST_OS" = windows ]; then DESKTOP_ZIG_ARGS=(-Ddesktop-target=x86_64-windows-gnu); fi
ZIG_J="${ZIG_J:-}"

# Print a path in a form native (non-MSYS) programs such as the Python harness can open.
_nativepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

_zig_build() { # _zig_build <optimize> <step-or-args...>
  local opt="$1"; shift
  zig build -Doptimize="$opt" ${ZIG_J:+-j"$ZIG_J"} "${DESKTOP_ZIG_ARGS[@]}" "$@"
}

# Copy the freshly built engine library and WASM module to where the Flutter build picks them up.
_stage_engine() {
  mkdir -p "$APP_DIR/web"
  cp "$STACK_DIR/zig-out/web/frame2d_engine.wasm" "$APP_DIR/web/frame2d_engine.wasm" || return 1
  case "$HOST_OS" in
    windows) cp "$STACK_DIR/zig-out/bin/$ENGINE_LIB" "$APP_DIR/windows/$ENGINE_LIB" ;;
    *) ;;  # linux/macos runners are not wired up on this machine
  esac
}

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Kept:    ./zig-pkg and $ZIG_GLOBAL_CACHE_DIR/p (Zig package sources), the Flutter pub cache (~/.pub-cache).
#   Removed: .zig-cache, zig-out, everything else in .zig-global, app/build, app/.dart_tool, staged engine copies.
clean_all() {
  rm -rf "$STACK_DIR/.zig-cache" "$STACK_DIR/zig-out"
  if [ -d "$ZIG_GLOBAL_CACHE_DIR" ]; then
    find "$ZIG_GLOBAL_CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name p -exec rm -rf {} +
  fi
  rm -rf "$APP_DIR/build" "$APP_DIR/.dart_tool" "$APP_DIR/web/frame2d_engine.wasm" "$APP_DIR/windows/frame2d_engine.dll"
}

build_cli_release() {
  _zig_build ReleaseFast install >&2 || return 1
  _nativepath "$STACK_DIR/zig-out/bin/frame2d$EXE"
}

build_server_release() {
  _zig_build ReleaseFast install >&2 || return 1
  _nativepath "$STACK_DIR/zig-out/bin/frame2d-server$EXE"
}

# Desktop app: Zig engine library (ReleaseFast) + `flutter build <os> --release`.
build_desktop_release() {
  _zig_build ReleaseFast install >&2 || return 1
  _stage_engine >&2 || return 1
  case "$HOST_OS" in
    windows)
      (cd "$APP_DIR" && flutter build windows --release >&2) || return 1
      _nativepath "$APP_DIR/build/windows/x64/runner/Release/frame2d_app.exe" ;;
    linux)
      (cd "$APP_DIR" && flutter build linux --release >&2) || return 1
      echo "$APP_DIR/build/linux/x64/release/bundle/frame2d_app" ;;
    *) echo "desktop build not wired for $HOST_OS" >&2; return 1 ;;
  esac
}

# Web app, default (dart2js) build. Output is a static directory; frame2d_engine.wasm sits beside index.html.
# --no-web-resources-cdn bundles CanvasKit locally so the app runs offline; the service worker is disabled
# so cached copies never skew benchmark runs.
build_web_release() {
  _zig_build ReleaseFast install >&2 || return 1
  _stage_engine >&2 || return 1
  (cd "$APP_DIR" && flutter build web --release --no-web-resources-cdn --pwa-strategy=none >&2) || return 1
  _nativepath "$APP_DIR/build/web"
}

# Same app compiled with dart2wasm (skwasm renderer); also keeps the dart2js fallback in the output.
build_web_wasm_release() {
  _zig_build ReleaseFast install >&2 || return 1
  _stage_engine >&2 || return 1
  (cd "$APP_DIR" && flutter build web --release --wasm --no-web-resources-cdn --pwa-strategy=none \
      --output="$(_nativepath "$APP_DIR/build/web_wasm")" >&2) || return 1
  _nativepath "$APP_DIR/build/web_wasm"
}

# build_check: the fast loop. Zig compiles every target and the tests without linking installs, and
# dart analyze type-checks the Flutter code (including the web-only and ffi-only files).
build_check() {
  _zig_build Debug check || return 1
  (cd "$APP_DIR" && dart analyze)
}

# build_dev: what the agent rebuilds while working: every Zig target (CLI, server, engine library, WASM) in
# Debug, plus the debug Flutter desktop app and the (profile-less) debug web build.
build_dev() {
  _zig_build Debug install || return 1
  _stage_engine || return 1
  case "$HOST_OS" in
    windows) (cd "$APP_DIR" && flutter build windows --debug) || return 1 ;;
    linux) (cd "$APP_DIR" && flutter build linux --debug) || return 1 ;;
  esac
  (cd "$APP_DIR" && flutter build web --debug --no-web-resources-cdn --pwa-strategy=none)
}

run_server() {
  local bin="$STACK_DIR/zig-out/bin/frame2d-server$EXE"
  [ -x "$bin" ] || _zig_build ReleaseFast install >&2 || return 1
  FRAME2D_ADDR="${FRAME2D_ADDR:-127.0.0.1:8080}" exec "$bin"
}

# Zig engine unit tests, then the Dart unit tests.
test_all() {
  _zig_build Debug test || return 1
  (cd "$APP_DIR" && flutter test)
}

# Direct dependencies of both toolchains, one per line.
deps_report() {
  grep -E '^\s+\.[a-z_]+ = \.\{' "$STACK_DIR/build.zig.zon" | sed -E 's/^\s+\.([a-z_]+) = .*/zig:\1 (sqlite amalgamation 3.50.4)/'
  (cd "$APP_DIR" && flutter pub deps --style=list --no-dev 2>/dev/null | grep -E '^- ' | sed -E 's/^- ([^ ]+) ([^ ]+).*/pub:\1 \2/' | sort -u)
}

# bounded: limit parallel build jobs to ${BENCH_JOBS:-$(nproc)/4}.
bounded() {
  local n="${BENCH_JOBS:-$(( $(nproc 2>/dev/null || echo 4) / 4 ))}"
  [ "$n" -lt 1 ] && n=1
  export ZIG_J="$n"
  export CMAKE_BUILD_PARALLEL_LEVEL="$n"
}

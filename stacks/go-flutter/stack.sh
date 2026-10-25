#!/usr/bin/env bash
# stack.sh for stacks/go-flutter (SPEC 5.6). Source this file; call the functions.
# Layout: engine/ (Go solver), bridge/{session,native,wasm} (Go bridges), cmd/{frame2d,server}, app/ (Flutter).
# Everything is relative to this file's directory. All toolchain flags live here.
# Each build_* prints the path of its artifact on the LAST line of stdout (all other output goes to stderr).

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

OUT="$STACK_DIR/build"
APP="$STACK_DIR/app"
LIB_BASENAME=frame2d_engine
export GOFLAGS="${GOFLAGS:-}"        # recorded: this stack sets no GOFLAGS (SPEC 9.3)
export GOTOOLCHAIN=local

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    EXE=.exe; HOST=windows; LIB_EXT=dll
    # The Flutter Windows runner is built for x64 on this machine (emulated on win-arm64), so the c-shared
    # engine must be amd64 too. cgo needs a C compiler for that target: zig cc (Zig 0.17.0 is already pinned).
    # Pure-Go targets (CLI, server, wasm) stay native and CGO-free.
    NATIVE_GOARCH=amd64
    NATIVE_CC="zig cc -target x86_64-windows-gnu"
    APP_EXE=frame2d_app.exe
    flutter_out_dir() { echo "$APP/build/windows/x64/runner/$1"; } ;;
  Darwin)
    EXE=; HOST=macos; LIB_EXT=dylib; NATIVE_CC=""; APP_EXE=frame2d_app
    flutter_out_dir() { echo "$APP/build/macos/Build/Products/$1"; } ;;
  *)
    EXE=; HOST=linux; LIB_EXT=so; NATIVE_CC=""; APP_EXE=frame2d_app
    flutter_out_dir() {
      local a=x64; [ "$(uname -m)" = aarch64 ] && a=arm64
      echo "$APP/build/linux/$a/$(echo "$1" | tr A-Z a-z)/bundle"
    } ;;
esac
DEV="$OUT/dev"                       # debug-friendly Go artifacts live apart from release ones (never clobber each other)
HOST_LIB="$OUT/$LIB_BASENAME.$LIB_EXT"       # release c-shared engine
DEV_LIB="$DEV/$LIB_BASENAME.$LIB_EXT"        # dev c-shared engine
GO_SRC=("$STACK_DIR/engine" "$STACK_DIR/bridge" "$STACK_DIR/cmd" "$STACK_DIR/go.mod" "$STACK_DIR/go.sum" "$STACK_DIR/stack.sh")
DART_SRC=("$APP/lib" "$APP/test" "$APP/pubspec.yaml" "$APP/pubspec.lock" "$APP/analysis_options.yaml" "$APP/ffigen.yaml" "$APP/web" "$APP/windows" "$STACK_DIR/stack.sh")

_jobs_flag=()   # filled by bounded()

# _stale <stamp-or-output> <inputs...>: true when the target is missing or any input file is newer (make-style).
# Inputs that do not exist are ignored; Flutter's ephemeral/generated dirs are skipped.
_stale() {
  local t="$1"; shift
  [ -e "$t" ] || return 0
  local ins=() i
  for i in "$@"; do [ -e "$i" ] && ins+=("$i"); done
  [ -n "$(find "${ins[@]}" \( -name ephemeral -o -name generated_plugin_registrant.\* -o -name flutter \) -prune -o -type f -newer "$t" -print -quit 2>/dev/null)" ]
}

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Removes: build/ (Go outputs), the Go build cache (go clean -cache), app/build and app/.dart_tool (flutter clean).
#   Keeps:   the Go module cache (GOMODCACHE) and the Dart pub cache.
clean_all() {
  rm -rf "$OUT"
  go clean -cache >&2
  ( cd "$APP" && flutter clean >&2 )
  rm -rf "$APP/.dart_tool" "$APP/build"
}

_go_build() { # <out> <pkg> [extra go build flags...]  (pure Go, no cgo); skipped when no Go source changed
  local out="$1" pkg="$2"; shift 2
  _stale "$out" "${GO_SRC[@]}" || return 0
  mkdir -p "$(dirname "$out")"
  CGO_ENABLED=0 go build "${_jobs_flag[@]}" "$@" -o "$out" "$pkg" >&2
}

_build_native_lib() { # <out> [go build flags...]; builds the c-shared engine for dart:ffi (skipped when fresh)
  local out="$1"; shift
  _stale "$out" "${GO_SRC[@]}" || return 0
  mkdir -p "$(dirname "$out")"
  if [ -n "$NATIVE_CC" ]; then
    GOOS=windows GOARCH=$NATIVE_GOARCH CGO_ENABLED=1 CC="$NATIVE_CC" \
      go build "${_jobs_flag[@]}" -buildmode=c-shared "$@" -o "$out" ./bridge/native >&2
  else
    CGO_ENABLED=1 go build "${_jobs_flag[@]}" -buildmode=c-shared "$@" -o "$out" ./bridge/native >&2
  fi
}

_build_wasm() { # <out> [go build flags...]; Go js/wasm engine for Flutter web (skipped when fresh)
  local out="$1"; shift
  _stale "$out" "${GO_SRC[@]}" || return 0
  mkdir -p "$(dirname "$out")"
  GOOS=js GOARCH=wasm CGO_ENABLED=0 go build "${_jobs_flag[@]}" "$@" -o "$out" ./bridge/wasm >&2
}

# Regenerate dart:ffi bindings (ffigen) only when the exported C header changed.
_ffigen() { # <dir holding the cgo-generated header>
  local hdr="$1/$LIB_BASENAME.h" dst="$APP/ffigen/$LIB_BASENAME.h"
  if ! cmp -s "$hdr" "$dst"; then
    mkdir -p "$APP/ffigen"; cp "$hdr" "$dst"
    ( cd "$APP" && flutter pub get >&2 && dart run ffigen --config ffigen.yaml >&2 ) || return 1
  fi
}

# flutter pub get only when pubspec.* is newer than the resolved package config.
_pub_get() {
  _stale "$APP/.dart_tool/package_config.json" "$APP/pubspec.yaml" "$APP/pubspec.lock" || return 0
  ( cd "$APP" && flutter pub get >&2 )
}

# Run background jobs started by the caller and fail if any failed. Usage: _wait pid...
_wait() { local rc=0 p; for p in "$@"; do wait "$p" || rc=1; done; return $rc; }

# ffigen needs an x64 libclang on win-arm64 (the installed LLVM is ARM64 but Dart runs as x64 under emulation).
_ensure_libclang() {
  [ "$HOST" = windows ] || return 0
  [ -f "$STACK_DIR/.tools/llvm-x64/bin/libclang.dll" ] && return 0
  local tmp; tmp="$(mktemp -d)"
  python -m pip download libclang --platform win_amd64 --only-binary=:all: --no-deps -d "$(cygpath -w "$tmp")" >&2 || return 1
  python - "$(cygpath -w "$tmp")" "$(cygpath -w "$STACK_DIR/.tools/llvm-x64")" >&2 <<'PY' || return 1
import glob, os, sys, zipfile
z = zipfile.ZipFile(glob.glob(os.path.join(sys.argv[1], "libclang-*.whl"))[0])
for sub in ("bin", "lib"):
    os.makedirs(os.path.join(sys.argv[2], sub), exist_ok=True)
    for n in z.namelist():
        if n.endswith("libclang.dll"):
            open(os.path.join(sys.argv[2], sub, "libclang.dll"), "wb").write(z.read(n))
PY
}

build_cli_release() {
  _go_build "$OUT/frame2d$EXE" ./cmd/frame2d -trimpath -ldflags="-s -w" || return 1
  echo "$OUT/frame2d$EXE"
}

build_server_release() {
  _go_build "$OUT/frame2d-server$EXE" ./cmd/server -trimpath -ldflags="-s -w" || return 1
  echo "$OUT/frame2d-server$EXE"
}

# Release desktop app: Go engine as a stripped c-shared library next to the Flutter release bundle.
# --split-debug-info moves Dart symbol tables out of the AOT snapshot (smaller app.so).
build_desktop_release() {
  _build_native_lib "$HOST_LIB" -trimpath -ldflags="-s -w" || return 1
  _ensure_libclang && _ffigen "$OUT" || return 1
  local dir; dir="$(flutter_out_dir Release)"
  if _stale "$APP/build/.release-stamp" "${DART_SRC[@]}" || [ ! -e "$dir/$APP_EXE" ]; then
    _pub_get && ( cd "$APP" && flutter build "$HOST" --release --split-debug-info="$APP/build/symbols" >&2 ) || return 1
    touch "$APP/build/.release-stamp"
  fi
  cmp -s "$HOST_LIB" "$dir/$LIB_BASENAME.$LIB_EXT" || cp "$HOST_LIB" "$dir/" || return 1
  echo "$dir/$APP_EXE"
}

# Release web: Go js/wasm engine + Flutter web. F2D_WEB_MODE=default builds the default (dart2js/CanvasKit)
# build into app/build/web; F2D_WEB_MODE=wasm (the default here) builds with --wasm into the same place.
# Both get the Go engine.wasm and wasm_exec.js copied in afterwards.
build_web_release() {
  _build_wasm "$OUT/engine.wasm" -trimpath -ldflags="-s -w" || return 1
  local mode="${F2D_WEB_MODE:-wasm}" flags=() dest="$APP/build/web"
  [ "$mode" = wasm ] && flags=(--wasm)
  # the stamp records the mode so switching F2D_WEB_MODE rebuilds
  local stamp="$APP/build/.web-release-$mode-stamp"
  if _stale "$stamp" "${DART_SRC[@]}" || [ ! -e "$dest/index.html" ]; then
    _pub_get && ( cd "$APP" && flutter build web --release "${flags[@]}" >&2 ) || return 1
    rm -f "$APP"/build/.web-release-*-stamp; touch "$stamp"
  fi
  cmp -s "$OUT/engine.wasm" "$dest/engine.wasm" || cp "$OUT/engine.wasm" "$dest/engine.wasm" || return 1
  cmp -s "$(go env GOROOT)/lib/wasm/wasm_exec.js" "$dest/wasm_exec.js" || cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" "$dest/wasm_exec.js" || return 1
  echo "$dest"
}

# build_check: fastest "does it compile": go vet (host, js/wasm and the cgo bridge for the x64 desktop target;
# vet type-checks without linking a DLL) and dart analyze. Steps are skipped when their inputs did not change.
build_check() {
  go vet "${_jobs_flag[@]}" ./... >&2 || return 1
  if _stale "$OUT/.vet-wasm-stamp" "${GO_SRC[@]}"; then
    GOOS=js GOARCH=wasm go vet "${_jobs_flag[@]}" ./bridge/wasm >&2 || return 1
    mkdir -p "$OUT"; touch "$OUT/.vet-wasm-stamp"
  fi
  if _stale "$OUT/.vet-native-stamp" "${GO_SRC[@]}"; then
    if [ -n "$NATIVE_CC" ]; then
      GOOS=windows GOARCH=$NATIVE_GOARCH CGO_ENABLED=1 CC="$NATIVE_CC" go vet "${_jobs_flag[@]}" ./bridge/native >&2 || return 1
    else
      CGO_ENABLED=1 go vet "${_jobs_flag[@]}" ./bridge/native >&2 || return 1
    fi
    mkdir -p "$OUT"; touch "$OUT/.vet-native-stamp"
  fi
  if _stale "$OUT/.analyze-stamp" "${DART_SRC[@]}"; then
    _pub_get && ( cd "$APP" && dart analyze . >&2 ) || return 1
    mkdir -p "$OUT"; touch "$OUT/.analyze-stamp"
  fi
}

# build_dev: Go CLI + server + c-shared lib + js/wasm engine (debug-friendly, no -s -w; kept in build/dev so the
# release artifacts are never overwritten), bindings if the header changed, then the Flutter desktop debug build
# with the library copied next to the executable. The four Go builds run concurrently.
build_dev() {
  local pids=()
  _go_build "$DEV/frame2d$EXE" ./cmd/frame2d & pids+=($!)
  _go_build "$DEV/frame2d-server$EXE" ./cmd/server & pids+=($!)
  _build_native_lib "$DEV_LIB" & pids+=($!)
  _build_wasm "$DEV/engine.wasm" & pids+=($!)
  _wait "${pids[@]}" || return 1
  _ensure_libclang && _ffigen "$DEV" || return 1
  local dir; dir="$(flutter_out_dir Debug)"
  if _stale "$APP/build/.debug-stamp" "${DART_SRC[@]}" || [ ! -e "$dir/$APP_EXE" ]; then
    _pub_get && ( cd "$APP" && flutter build "$HOST" --debug >&2 ) || return 1
    touch "$APP/build/.debug-stamp"
  fi
  cmp -s "$DEV_LIB" "$dir/$LIB_BASENAME.$LIB_EXT" || cp "$DEV_LIB" "$dir/" || return 1
  echo "$dir/$APP_EXE"
}

# run_server: foreground, honors FRAME2D_ADDR. Runs the (incrementally built) release server binary, so it never
# replaces the release artifact with a differently-flagged build.
run_server() {
  local bin; bin="$(build_server_release)" || return 1
  FRAME2D_DB="${FRAME2D_DB:-$OUT/frame2d.db}" exec "$bin"
}

test_all() {
  go test "${_jobs_flag[@]}" ./... >&2 || return 1
  ( cd "$APP" && flutter test >&2 )
}

deps_report() { # transitive dependencies: Go modules used by the build + Dart/pub packages
  go list -deps -f '{{with .Module}}go:{{.Path}}@{{.Version}}{{end}}' ./cmd/... ./bridge/... 2>/dev/null | sort -u | grep -v -e '^go:$' -e '^go:frame2d@'
  ( cd "$APP" && flutter pub deps --no-dev --style=compact 2>/dev/null | sed -n 's/^- \([a-z0-9_]*\) \([0-9][^ ]*\).*/pub:\1@\2/p' | sort -u )
}

bounded() { # limit parallel build jobs to ${BENCH_JOBS:-$(nproc)/4}
  local n="${BENCH_JOBS:-$(( $(nproc 2>/dev/null || echo 4) / 4 ))}"
  [ "$n" -ge 1 ] || n=1
  export GOMAXPROCS="$n" CMAKE_BUILD_PARALLEL_LEVEL="$n"
  _jobs_flag=(-p "$n")
}

# Optional: Flutter hot reload probe (the harness drives `flutter run --machine`).
hot_reload_probe() { echo "cd $APP && flutter run --machine -d $HOST"; }

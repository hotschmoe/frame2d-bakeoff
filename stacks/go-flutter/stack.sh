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
HOST_LIB="$OUT/$LIB_BASENAME.$LIB_EXT"

_jobs_flag=()   # filled by bounded()

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Removes: build/ (Go outputs), the Go build cache (go clean -cache), app/build and app/.dart_tool (flutter clean).
#   Keeps:   the Go module cache (GOMODCACHE) and the Dart pub cache.
clean_all() {
  rm -rf "$OUT"
  go clean -cache >&2
  ( cd "$APP" && flutter clean >&2 )
  rm -rf "$APP/.dart_tool" "$APP/build"
}

_go_build() { # <out> <pkg> [extra go build flags...]  (pure Go, no cgo)
  local out="$1" pkg="$2"; shift 2
  CGO_ENABLED=0 go build "${_jobs_flag[@]}" "$@" -o "$out" "$pkg" >&2
}

_build_native_lib() { # [go build flags...]; builds the c-shared engine for dart:ffi
  mkdir -p "$OUT"
  if [ -n "$NATIVE_CC" ]; then
    GOOS=windows GOARCH=$NATIVE_GOARCH CGO_ENABLED=1 CC="$NATIVE_CC" \
      go build "${_jobs_flag[@]}" -buildmode=c-shared "$@" -o "$HOST_LIB" ./bridge/native >&2
  else
    CGO_ENABLED=1 go build "${_jobs_flag[@]}" -buildmode=c-shared "$@" -o "$HOST_LIB" ./bridge/native >&2
  fi
}

_build_wasm() { # [go build flags...]; Go js/wasm engine for Flutter web
  mkdir -p "$OUT"
  GOOS=js GOARCH=wasm CGO_ENABLED=0 go build "${_jobs_flag[@]}" "$@" -o "$OUT/engine.wasm" ./bridge/wasm >&2
}

# Regenerate dart:ffi bindings (ffigen) only when the exported C header changed.
_ffigen() {
  local hdr="$OUT/$LIB_BASENAME.h" dst="$APP/ffigen/$LIB_BASENAME.h"
  if ! cmp -s "$hdr" "$dst"; then
    mkdir -p "$APP/ffigen"; cp "$hdr" "$dst"
    ( cd "$APP" && flutter pub get >&2 && dart run ffigen --config ffigen.yaml >&2 ) || return 1
  fi
}

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
  mkdir -p "$OUT"
  _go_build "$OUT/frame2d$EXE" ./cmd/frame2d -trimpath -ldflags="-s -w" || return 1
  echo "$OUT/frame2d$EXE"
}

build_server_release() {
  mkdir -p "$OUT"
  _go_build "$OUT/frame2d-server$EXE" ./cmd/server -trimpath -ldflags="-s -w" || return 1
  echo "$OUT/frame2d-server$EXE"
}

# Release desktop app: Go engine as a stripped c-shared library next to the Flutter release bundle.
build_desktop_release() {
  _build_native_lib -trimpath -ldflags="-s -w" || return 1
  _ensure_libclang && _ffigen || return 1
  ( cd "$APP" && flutter pub get >&2 && flutter build "$HOST" --release >&2 ) || return 1
  local dir; dir="$(flutter_out_dir Release)"
  cp "$HOST_LIB" "$dir/" || return 1
  echo "$dir/$APP_EXE"
}

# Release web: Go js/wasm engine + Flutter web. F2D_WEB_MODE=default builds the default (dart2js/CanvasKit)
# build into app/build/web; F2D_WEB_MODE=wasm (the default here) builds with --wasm into the same place.
# Both get the Go engine.wasm and wasm_exec.js copied in afterwards.
build_web_release() {
  _build_wasm -trimpath -ldflags="-s -w" || return 1
  local mode="${F2D_WEB_MODE:-wasm}" flags=() dest="$APP/build/web"
  [ "$mode" = wasm ] && flags=(--wasm)
  ( cd "$APP" && flutter pub get >&2 && flutter build web --release "${flags[@]}" >&2 ) || return 1
  cp "$OUT/engine.wasm" "$dest/engine.wasm" || return 1
  cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" "$dest/wasm_exec.js" || return 1
  echo "$dest"
}

# build_check: fastest "does it compile": go vet (host + js/wasm), native c-shared lib compile, dart analyze.
build_check() {
  go vet "${_jobs_flag[@]}" ./... >&2 || return 1
  GOOS=js GOARCH=wasm go vet "${_jobs_flag[@]}" ./bridge/wasm >&2 || return 1
  _build_native_lib || return 1
  ( cd "$APP" && dart analyze . >&2 ) || return 1
}

# build_dev: Go CLI + server + c-shared lib + js/wasm engine (debug-friendly, no -s -w), bindings if the
# header changed, then the Flutter desktop debug build with the library copied next to the executable.
build_dev() {
  mkdir -p "$OUT"
  _go_build "$OUT/frame2d$EXE" ./cmd/frame2d || return 1
  _go_build "$OUT/frame2d-server$EXE" ./cmd/server || return 1
  _build_native_lib || return 1
  _build_wasm || return 1
  _ensure_libclang && _ffigen || return 1
  ( cd "$APP" && flutter pub get >&2 && flutter build "$HOST" --debug >&2 ) || return 1
  local dir; dir="$(flutter_out_dir Debug)"
  cp "$HOST_LIB" "$dir/" || return 1
  echo "$dir/$APP_EXE"
}

run_server() { # foreground; honors FRAME2D_ADDR
  mkdir -p "$OUT"
  _go_build "$OUT/frame2d-server$EXE" ./cmd/server || return 1
  FRAME2D_DB="${FRAME2D_DB:-$OUT/frame2d.db}" exec "$OUT/frame2d-server$EXE"
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

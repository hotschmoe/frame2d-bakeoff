#!/usr/bin/env bash
# stack.sh for stacks/go-zig-flutter (SPEC 5.6). Source this file; call the functions.
# Layout: zig/ (engine + C ABI: src/, include/), bridge/zig (cgo wrapper), cmd/{frame2d,server} (Go),
# app/ (Flutter; dart:ffi on desktop, hand-loaded WASM on web). Everything is relative to this file's directory.
# All toolchain flags live here. Each build_* prints the artifact path on the LAST line of stdout (rest goes to stderr).
#
# One Zig source tree, three artifacts:
#   build/libframe2d.a           static lib for the Go CLI/server (cgo, CC = zig cc), host architecture
#   build/frame2d_engine.<dll>   shared lib for the Flutter desktop app (dart:ffi)
#   build/engine.wasm            wasm32-freestanding module for Flutter web

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

OUT="$STACK_DIR/build"
APP="$STACK_DIR/app"
ZIG_SRC="$STACK_DIR/zig/src/lib.zig"
ZIG_HDR="$STACK_DIR/zig/include/frame2d_engine.h"
LIB_BASENAME=frame2d_engine
export GOFLAGS="${GOFLAGS:-}"        # recorded: this stack sets no GOFLAGS (SPEC 9.3)
export GOTOOLCHAIN=local

# Zig names for the Go host architecture (the CLI/server are cgo binaries for the host).
case "$(go env GOARCH)" in
  arm64) ZIG_GO_ARCH=aarch64 ;;
  amd64) ZIG_GO_ARCH=x86_64 ;;
  *)     ZIG_GO_ARCH="$(go env GOARCH)" ;;
esac

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    EXE=.exe; HOST=windows; LIB_EXT=dll
    # The Flutter Windows runner is built for x64 on this machine (emulated on win-arm64), so the desktop
    # engine library is x86_64 regardless of the host. The Go CLI/server stay native (host arch) via zig cc.
    ZIG_GO_TARGET="$ZIG_GO_ARCH-windows-gnu"
    ZIG_APP_TARGET="x86_64-windows-gnu"
    APP_EXE=frame2d_app.exe
    flutter_out_dir() { echo "$APP/build/windows/x64/runner/$1"; } ;;
  Darwin)
    EXE=; HOST=macos; LIB_EXT=dylib; APP_EXE=frame2d_app
    ZIG_GO_TARGET="$ZIG_GO_ARCH-macos"; ZIG_APP_TARGET=""
    flutter_out_dir() { echo "$APP/build/macos/Build/Products/$1"; } ;;
  *)
    EXE=; HOST=linux; LIB_EXT=so; APP_EXE=frame2d_app
    ZIG_GO_TARGET="$ZIG_GO_ARCH-linux-gnu"; ZIG_APP_TARGET=""
    flutter_out_dir() {
      local a=x64; [ "$(uname -m)" = aarch64 ] && a=arm64
      echo "$APP/build/linux/$a/$(echo "$1" | tr A-Z a-z)/bundle"
    } ;;
esac
HOST_LIB="$OUT/$( [ "$HOST" = windows ] && echo "" || echo lib )$LIB_BASENAME.$LIB_EXT"
# Zig caches live inside the stack so clean_all never touches the global cache other Zig stacks share.
export ZIG_GLOBAL_CACHE_DIR="$STACK_DIR/.zig-global" ZIG_LOCAL_CACHE_DIR="$STACK_DIR/.zig-cache"

# Go with cgo enabled and zig cc as the C compiler. CC is scoped to Go: Flutter's CMake would pick it up too.
_go() { CC="zig cc -target $ZIG_GO_TARGET" CGO_ENABLED=1 go "$@"; }

_jobs_flag=()   # filled by bounded()

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Removes: build/ (Zig/Go outputs), the stack-local Zig caches .zig-global/.zig-cache (compiled compiler-rt/libc),
#            the Go build cache (go clean -cache), app/build and app/.dart_tool (flutter clean).
#   Keeps:   the Go module cache (GOMODCACHE), the Dart pub cache. (No Zig packages are used.)
clean_all() {
  rm -rf "$OUT" "$STACK_DIR/.zig-cache" "$STACK_DIR/.zig-global"
  go clean -cache >&2
  ( cd "$APP" && flutter clean >&2 )
  rm -rf "$APP/.dart_tool" "$APP/build"
}

# _zig <kind> <target> <optimize> <out>: build the engine as static | shared | wasm | check-<kind> (no output).
_zig() {
  local kind="$1" target="$2" opt="$3" out="$4" args=()
  mkdir -p "$OUT"
  [ -n "$target" ] && args+=(-target "$target")
  case "$kind" in
    static)  args+=(-static --name frame2d -femit-bin="$out") ;;
    shared)  args+=(-dynamic --name "$LIB_BASENAME" -femit-bin="$out") ;;
    wasm)    args+=(--name engine -femit-bin="$out") ;;
    check)   args+=(-fno-emit-bin) ;;
  esac
  case "$opt" in release) args+=(-OReleaseFast -fstrip) ;; *) args+=(-OReleaseSafe) ;; esac
  if [ "$target" = wasm32-freestanding ]; then
    ( cd "$STACK_DIR/zig" && zig build-exe src/lib.zig -fno-entry -rdynamic "${args[@]}" ) >&2
  else
    ( cd "$STACK_DIR/zig" && zig build-lib src/lib.zig "${args[@]}" ) >&2
  fi
}

_build_static_lib() { _zig static "$ZIG_GO_TARGET" "$1" "$OUT/libframe2d.a"; }

_build_native_lib() { # desktop shared library for dart:ffi; $1 = release|dev
  _zig shared "$ZIG_APP_TARGET" "$1" "$HOST_LIB" || return 1
  rm -f "$OUT"/*.lib "$OUT"/*.pdb "$OUT"/frame2d_engine.dll.obj 2>/dev/null
  return 0
}

_build_wasm() { _zig wasm wasm32-freestanding "$1" "$OUT/engine.wasm"; }   # $1 = release|dev

# Go links the static lib through cgo. Go does not hash a library's contents into the link action, so a
# stamp of the lib is passed through -ldflags -X to force a relink whenever the Zig code changed.
_lib_stamp() { md5sum "$OUT/libframe2d.a" | cut -c1-12; }

_go_build() { # <out> <pkg> [extra go build flags...]; links build/libframe2d.a via cgo (zig cc)
  local out="$1" pkg="$2"; shift 2
  _go build "${_jobs_flag[@]}" "$@" -o "$out" "$pkg" >&2
}

_go_ldflags() { echo "$1-X frame2d/bridge/zig.libStamp=$(_lib_stamp)"; }   # $1 = extra flags with trailing space

# Regenerate dart:ffi bindings (ffigen) only when the C header changed.
_ffigen() {
  local dst="$APP/ffigen/$LIB_BASENAME.h"
  if ! cmp -s "$ZIG_HDR" "$dst"; then
    mkdir -p "$APP/ffigen"; cp "$ZIG_HDR" "$dst"
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
  _build_static_lib release || return 1
  _go_build "$OUT/frame2d$EXE" ./cmd/frame2d -trimpath -ldflags="$(_go_ldflags '-s -w ')" || return 1
  echo "$OUT/frame2d$EXE"
}

build_server_release() {
  mkdir -p "$OUT"
  _build_static_lib release || return 1
  _go_build "$OUT/frame2d-server$EXE" ./cmd/server -trimpath -ldflags="$(_go_ldflags '-s -w ')" || return 1
  echo "$OUT/frame2d-server$EXE"
}

# Release desktop app: the Zig engine as a stripped shared library next to the Flutter release bundle.
build_desktop_release() {
  _build_native_lib release || return 1
  _ensure_libclang && _ffigen || return 1
  ( cd "$APP" && flutter pub get >&2 && flutter build "$HOST" --release >&2 ) || return 1
  local dir; dir="$(flutter_out_dir Release)"
  cp "$HOST_LIB" "$dir/" || return 1
  echo "$dir/$APP_EXE"
}

# Release web: Zig wasm32-freestanding engine + Flutter web. F2D_WEB_MODE=default builds the default
# (dart2js/CanvasKit) build into app/build/web; F2D_WEB_MODE=wasm (the default here) builds with --wasm into the
# same place. Both get engine.wasm copied in afterwards (web/f2d_loader.js instantiates it).
build_web_release() {
  _build_wasm release || return 1
  local mode="${F2D_WEB_MODE:-wasm}" flags=() dest="$APP/build/web"
  rm -rf "$dest"
  [ "$mode" = wasm ] && flags=(--wasm)
  ( cd "$APP" && flutter pub get >&2 && flutter build web --release "${flags[@]}" >&2 ) || return 1
  cp "$OUT/engine.wasm" "$dest/engine.wasm" || return 1
  echo "$dest"
}

# build_check: fastest "does it compile": Zig semantic check (host + wasm), go vet, static lib + dart analyze.
build_check() {
  _zig check "$ZIG_GO_TARGET" dev "" || return 1
  _zig check wasm32-freestanding dev "" || return 1
  _build_static_lib dev || return 1
  _go vet "${_jobs_flag[@]}" ./... >&2 || return 1
  ( cd "$APP" && dart analyze . >&2 ) || return 1
}

# build_dev: Zig libs (static, shared, wasm; ReleaseSafe), Go CLI + server, bindings if the header changed,
# then the Flutter desktop debug build with the library copied next to the executable.
build_dev() {
  mkdir -p "$OUT"
  _build_static_lib dev || return 1
  _go_build "$OUT/frame2d$EXE" ./cmd/frame2d -ldflags="$(_go_ldflags '')" || return 1
  _go_build "$OUT/frame2d-server$EXE" ./cmd/server -ldflags="$(_go_ldflags '')" || return 1
  _build_native_lib dev || return 1
  _build_wasm dev || return 1
  _ensure_libclang && _ffigen || return 1
  ( cd "$APP" && flutter pub get >&2 && flutter build "$HOST" --debug >&2 ) || return 1
  local dir; dir="$(flutter_out_dir Debug)"
  cp "$HOST_LIB" "$dir/" || return 1
  echo "$dir/$APP_EXE"
}

run_server() { # foreground; honors FRAME2D_ADDR
  mkdir -p "$OUT"
  _build_static_lib dev || return 1
  _go_build "$OUT/frame2d-server$EXE" ./cmd/server -ldflags="$(_go_ldflags '')" || return 1
  FRAME2D_DB="${FRAME2D_DB:-$OUT/frame2d.db}" exec "$OUT/frame2d-server$EXE"
}

test_all() {
  ( cd "$STACK_DIR/zig" && zig test src/tests.zig ) >&2 || return 1
  _build_static_lib dev || return 1
  _go test "${_jobs_flag[@]}" -ldflags="$(_go_ldflags '')" ./... >&2 || return 1
  ( cd "$APP" && flutter test >&2 )
}

deps_report() { # transitive dependencies: Go modules used by the build + Dart/pub packages (Zig: std only)
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

#!/usr/bin/env bash
# stack.sh for stacks/go-zig-flutter (SPEC 5.6). Source this file; call the functions.
# Layout: zig/ (engine + C ABI: src/, include/), bridge/zig (cgo wrapper), cmd/{frame2d,server} (Go),
# app/ (Flutter; dart:ffi on desktop, hand-loaded WASM on web). Everything is relative to this file's directory.
# All toolchain flags live here. Each build_* prints the artifact path on the LAST line of stdout (rest goes to stderr).
#
# One Zig source tree, three artifacts per profile (build/dev/ and build/release/):
#   libframe2d.a           static lib for the Go CLI/server (cgo, CC = zig cc), host architecture
#   frame2d_engine.<dll>   shared lib for the Flutter desktop app (dart:ffi)
#   engine.wasm            wasm32-freestanding module for Flutter web
# Every step is incremental: it is skipped when a hash of its inputs is unchanged and its outputs still exist
# (stamps in build/.stamps), so a no-op build_check/build_dev does no real work and an edit rebuilds only what depends on it.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR" || return 1
source "$STACK_DIR/../../harness/machine-env.sh"   # pinned PATH per machine (SPEC 15)

OUT="$STACK_DIR/build"
APP="$STACK_DIR/app"
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
LIB_FILE="$( [ "$HOST" = windows ] && echo "" || echo lib )$LIB_BASENAME.$LIB_EXT"
# Zig caches live inside the stack so clean_all never touches the global cache other Zig stacks share.
export ZIG_GLOBAL_CACHE_DIR="$STACK_DIR/.zig-global" ZIG_LOCAL_CACHE_DIR="$STACK_DIR/.zig-cache"

# Dev and release outputs live apart, so a dev build (run_server, build_dev) never overwrites a release artifact.
DEV_DIR="$OUT/dev"; REL_DIR="$OUT/release"
STAMPS="$OUT/.stamps"
_pdir() { [ "$1" = release ] && echo "$REL_DIR" || echo "$DEV_DIR"; }

# Go with cgo enabled and zig cc as the C compiler. CC is scoped to Go: Flutter's CMake would pick it up too.
# $1 = dev|release selects the directory of libframe2d.a (the cgo directive in bridge/zig carries only -lframe2d).
_go() {
  local p="$1" d; shift
  d="$(_pdir "$p")"; [ "$HOST" = windows ] && d="$(cygpath -m "$d")"
  CC="zig cc -target $ZIG_GO_TARGET" CGO_ENABLED=1 CGO_LDFLAGS="-L$d" go "$@"
}

_jobs_flag=()   # filled by bounded()

# ---- stamps: skip a step when the hash of its inputs is unchanged and its outputs still exist (make-style)
_tree_hash() { # <paths...>: hash of path, size and mtime of every file below the paths (build outputs excluded; make-style)
  find "$@" -type f -not -path '*/build/*' -not -path '*/.dart_tool/*' -not -path '*/ephemeral/*' -printf '%p %s %T@
' 2>/dev/null | md5sum
}
_fresh() { # <name> <key> <outputs...>
  local name="$1" key="$2"; shift 2
  [ -f "$STAMPS/$name" ] && [ "$(cat "$STAMPS/$name")" = "$key" ] || return 1
  local f; for f in "$@"; do [ -e "$f" ] || return 1; done
}
_mark() { mkdir -p "$STAMPS"; printf '%s' "$2" > "$STAMPS/$1"; }
_par() { # run the named functions concurrently; fail if any fails
  local pids=() f p rc=0
  for f in "$@"; do "$f" & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  return $rc
}

_zig_key() { echo "$(_tree_hash "$STACK_DIR/zig/src" "$ZIG_HDR") ${ZIG_VERSION:=$(zig version)}"; }

# clean_all: remove build outputs and compiled deps; KEEP downloaded sources (SPEC 9.1).
#   Removes: build/ (Zig/Go outputs and stamps), the stack-local Zig caches .zig-global/.zig-cache (compiled compiler-rt/libc),
#            the Go build cache (go clean -cache), app/build and app/.dart_tool (flutter clean).
#   Keeps:   the Go module cache (GOMODCACHE), the Dart pub cache. (No Zig packages are used.)
clean_all() {
  rm -rf "$OUT" "$STACK_DIR/.zig-cache" "$STACK_DIR/.zig-global"
  go clean -cache >&2
  ( cd "$APP" && flutter clean >&2 )
  rm -rf "$APP/.dart_tool" "$APP/build"
}

# _zig <kind> <target> <profile> <out>: build the engine as static | shared | wasm | check (no output).
# Both profiles use ReleaseFast (release adds -fstrip). ReleaseSafe compiled about 2.5x slower for no use in an edit loop
# whose safety net is `zig test` (Debug, runtime safety on). Skipped when sources, flags and output are unchanged.
_zig() {
  local kind="$1" target="$2" prof="$3" out="$4" args=() sname="" key=""
  if [ "$kind" != check ]; then
    mkdir -p "$(dirname "$out")"
    sname="$(basename "$(dirname "$out")")-$(basename "$out")"
    key="$kind $target $prof ${ZKEY:=$(_zig_key)}"
    _fresh "$sname" "$key" "$out" && return 0
  fi
  [ -n "$target" ] && args+=(-target "$target")
  case "$kind" in
    static)  args+=(-static --name frame2d -femit-bin="$out") ;;
    shared)  args+=(-dynamic --name "$LIB_BASENAME" -femit-bin="$out") ;;
    wasm)    args+=(--name engine -femit-bin="$out") ;;
    check)   args+=(-fno-emit-bin) ;;
  esac
  args+=(-OReleaseFast)
  [ "$prof" = release ] && args+=(-fstrip)
  if [ "$target" = wasm32-freestanding ]; then
    ( cd "$STACK_DIR/zig" && zig build-exe src/lib.zig -fno-entry -rdynamic "${args[@]}" ) >&2 || return 1
  else
    ( cd "$STACK_DIR/zig" && zig build-lib src/lib.zig "${args[@]}" ) >&2 || return 1
  fi
  [ "$kind" = check ] || _mark "$sname" "$key"
}

_build_static_lib() { _zig static "$ZIG_GO_TARGET" "$1" "$(_pdir "$1")/libframe2d.a"; }   # $1 = release|dev

_build_native_lib() { # desktop shared library for dart:ffi; $1 = release|dev
  _zig shared "$ZIG_APP_TARGET" "$1" "$(_pdir "$1")/$LIB_FILE" || return 1
  rm -f "$(_pdir "$1")"/*.lib "$(_pdir "$1")"/*.pdb "$(_pdir "$1")"/frame2d_engine.dll.obj 2>/dev/null
  return 0
}

_build_wasm() { _zig wasm wasm32-freestanding "$1" "$(_pdir "$1")/engine.wasm"; }   # $1 = release|dev

# Go links the static lib through cgo. Go does not hash a library's contents into the link action, so a
# stamp of the lib is passed through -ldflags -X to force a relink whenever the Zig code changed.
_lib_stamp() { md5sum "$(_pdir "$1")/libframe2d.a" | cut -c1-12; }

_go_key() { _tree_hash "$STACK_DIR/cmd" "$STACK_DIR/bridge" "$STACK_DIR/go.mod" "$STACK_DIR/go.sum"; }
_go_build() { # <profile> <out> <pkg> [extra go build flags...]; links <profile>/libframe2d.a via cgo (zig cc)
  # Skipped when the Go sources, the library and the flags are unchanged (go build alone costs about 1 s even then).
  local prof="$1" out="$2" pkg="$3"; shift 3
  local sname key; sname="go-$prof-$(basename "$out")"
  key="${GOKEY:-$(_go_key)} $(_lib_stamp "$prof") $*"
  _fresh "$sname" "$key" "$out" && return 0
  _go "$prof" build "${_jobs_flag[@]}" "$@" -o "$out" "$pkg" >&2 || return 1
  _mark "$sname" "$key"
}

_go_ldflags() { echo "$2-X frame2d/bridge/zig.libStamp=$(_lib_stamp "$1")"; }   # <profile> <extra flags with trailing space>

# `flutter pub get` only when pubspec.yaml / pubspec.lock changed.
_pub_get() {
  local key; key="$(_tree_hash "$APP/pubspec.yaml" "$APP/pubspec.lock")"
  _fresh pub-get "$key" "$APP/.dart_tool/package_config.json" && return 0
  ( cd "$APP" && flutter pub get >&2 ) || return 1
  _mark pub-get "$(_tree_hash "$APP/pubspec.yaml" "$APP/pubspec.lock")"
}

# Regenerate dart:ffi bindings (ffigen) only when the C header changed.
_ffigen() {
  local dst="$APP/ffigen/$LIB_BASENAME.h"
  if ! cmp -s "$ZIG_HDR" "$dst" || [ ! -f "$APP/lib/generated/engine_bindings.dart" ]; then
    _pub_get || return 1
    mkdir -p "$APP/ffigen"; cp "$ZIG_HDR" "$dst"
    ( cd "$APP" && dart run ffigen --config ffigen.yaml >&2 ) || return 1
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

# flutter builds are skipped when the app sources, pubspec and flags are unchanged and the output exists.
_app_key() { # <desktop|web> <flags...>
  local k="$1"; shift
  local dirs=("$APP/lib" "$APP/pubspec.yaml" "$APP/pubspec.lock" "$APP/assets")
  if [ "$k" = web ]; then dirs+=("$APP/web"); else dirs+=("$APP/$HOST"); fi
  echo "$(_tree_hash "${dirs[@]}") $k $*"
}
_flutter_desktop() { # <Debug|Release> <exe>
  local mode="$1" exe="$2" flag=--debug extra=()
  if [ "$mode" = Release ]; then flag=--release; extra=(--split-debug-info="$OUT/symbols"); fi
  local key; key="$(_app_key desktop "$flag")"
  _fresh "flutter-desktop-$mode" "$key" "$exe" && return 0
  ( cd "$APP" && flutter build "$HOST" "$flag" "${extra[@]}" >&2 ) || return 1
  _mark "flutter-desktop-$mode" "$key"
}
_install_lib() { # copy the shared lib into the bundle only when it changed
  local src="$1" dir="$2"
  cmp -s "$src" "$dir/$(basename "$src")" || cp "$src" "$dir/"
}

build_cli_release() {
  _build_static_lib release || return 1
  _go_build release "$REL_DIR/frame2d$EXE" ./cmd/frame2d -trimpath -buildvcs=false -ldflags="$(_go_ldflags release '-s -w ')" || return 1
  echo "$REL_DIR/frame2d$EXE"
}

build_server_release() {
  _build_static_lib release || return 1
  _go_build release "$REL_DIR/frame2d-server$EXE" ./cmd/server -trimpath -buildvcs=false -ldflags="$(_go_ldflags release '-s -w ')" || return 1
  echo "$REL_DIR/frame2d-server$EXE"
}

# Release desktop app: the Zig engine as a stripped shared library next to the Flutter release bundle.
build_desktop_release() {
  _build_native_lib release || return 1
  _ensure_libclang && _ffigen && _pub_get || return 1
  local dir; dir="$(flutter_out_dir Release)"
  _flutter_desktop Release "$dir/$APP_EXE" || return 1
  _install_lib "$REL_DIR/$LIB_FILE" "$dir" || return 1
  echo "$dir/$APP_EXE"
}

# Release web: Zig wasm32-freestanding engine + Flutter web. F2D_WEB_MODE=default builds the default
# (dart2js/CanvasKit) build into app/build/web; F2D_WEB_MODE=wasm (the default here) builds with --wasm into the
# same place. Both get engine.wasm copied in afterwards (web/f2d_loader.js instantiates it).
build_web_release() {
  _build_wasm release || return 1
  local mode="${F2D_WEB_MODE:-wasm}" flags=() dest="$APP/build/web"
  [ "$mode" = wasm ] && flags=(--wasm)
  _pub_get || return 1
  local key; key="$(_app_key web "$mode")"
  if ! _fresh flutter-web "$key" "$dest/index.html"; then
    rm -rf "$dest"
    ( cd "$APP" && flutter build web --release "${flags[@]}" >&2 ) || return 1
    _mark flutter-web "$key"
  fi
  cmp -s "$REL_DIR/engine.wasm" "$dest/engine.wasm" || cp "$REL_DIR/engine.wasm" "$dest/engine.wasm" || return 1
  echo "$dest"
}

# build_check: "does it compile", for everything: Zig semantic check (host + wasm), go vet (cgo needs only the
# header, not the library), dart analyze (skipped when the app sources are unchanged). The four run concurrently.
_chk_zig_host() { _zig check "$ZIG_GO_TARGET" dev ""; }
_chk_zig_wasm() { _zig check wasm32-freestanding dev ""; }
_chk_go() { _go dev vet "${_jobs_flag[@]}" ./... >&2; }
_chk_dart() {
  _pub_get || return 1
  local key; key="$(_tree_hash "$APP/lib" "$APP/test" "$APP/pubspec.yaml" "$APP/pubspec.lock" "$APP/analysis_options.yaml")"
  _fresh dart-analyze "$key" && return 0
  ( cd "$APP" && dart analyze . >&2 ) || return 1
  _mark dart-analyze "$key"
}
build_check() {
  mkdir -p "$OUT"
  _par _chk_zig_host _chk_zig_wasm _chk_go _chk_dart
}

# build_dev: Zig libs (static, shared, wasm), Go CLI + server, bindings if the header changed, then the Flutter
# desktop debug build with the library copied next to the executable. Independent chains run concurrently, and every
# step is skipped when its inputs did not change (a Zig edit does not rebuild Flutter, a UI edit rebuilds neither Zig nor Go).
_dev_go_cli() { _go_build dev "$DEV_DIR/frame2d$EXE" ./cmd/frame2d -ldflags="$(_go_ldflags dev '')"; }
_dev_go_server() { _go_build dev "$DEV_DIR/frame2d-server$EXE" ./cmd/server -ldflags="$(_go_ldflags dev '')"; }
_dev_go_chain() {
  _build_static_lib dev || return 1
  _par _dev_go_cli _dev_go_server
}
_dev_dll() { _build_native_lib dev; }
_dev_wasm() { _build_wasm dev; }
_dev_flutter_chain() {
  _ensure_libclang && _ffigen && _pub_get || return 1
  _flutter_desktop Debug "$(flutter_out_dir Debug)/$APP_EXE"
}
build_dev() {
  mkdir -p "$DEV_DIR"
  ZKEY="$(_zig_key)"; GOKEY="$(_go_key)"   # computed once, shared by the concurrent steps
  _par _dev_go_chain _dev_dll _dev_wasm _dev_flutter_chain || return 1
  local dir; dir="$(flutter_out_dir Debug)"
  _install_lib "$DEV_DIR/$LIB_FILE" "$dir" || return 1
  echo "$dir/$APP_EXE"
}

# run_server: foreground; honors FRAME2D_ADDR. Runs the release-profile server (build/release/, rebuilt only when the
# Zig or Go sources changed) so benchmarking through it measures the shipped configuration, and a dev build can never
# clobber the release artifact.
run_server() {
  build_server_release >/dev/null || return 1
  FRAME2D_DB="${FRAME2D_DB:-$OUT/frame2d.db}" exec "$REL_DIR/frame2d-server$EXE"
}

test_all() {
  ( cd "$STACK_DIR/zig" && zig test src/tests.zig ) >&2 || return 1
  _build_static_lib dev || return 1
  _go dev test "${_jobs_flag[@]}" -ldflags="$(_go_ldflags dev '')" ./... >&2 || return 1
  ( cd "$APP" && _pub_get && flutter test >&2 )
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

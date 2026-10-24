#!/usr/bin/env bash
# Per-machine PATH setup, sourced by stack.sh files and harness scripts (SPEC 15). It makes the pinned
# toolchains from results/<run>/versions.md win over whatever else is installed. It never installs or
# upgrades anything. On Linux/macOS it does nothing: use the system or rustup/asdf-managed toolchains.

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if [ -z "${F2D_MACHINE_ENV_DONE:-}" ]; then
      # win-arm64 (run1). Order matters: WinGet Links first so Zig 0.17.0 beats the self-patched 0.16.0
      # at C:\zig\aarch64-patched, which is still first on the Windows PATH.
      _h="/c/Users/$USERNAME"
      for _d in \
        "$_h/dev/tools/binaryen/binaryen-version_133/bin" \
        "$_h/dev/flutter/bin" \
        "$_h/.cargo/bin" \
        "/c/Program Files/LLVM/bin" \
        "/c/Program Files/Go/bin" \
        "$_h/AppData/Local/Microsoft/WinGet/Links"; do
        [ -d "$_d" ] && PATH="$_d:$PATH"
      done
      export PATH F2D_MACHINE_ENV_DONE=1
      export F2D_MACHINE_ID="${F2D_MACHINE_ID:-win-arm64}"
      export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-}"
      unset _h _d
    fi
    ;;
esac

# Sanity check the load-bearing pins; warn loudly rather than fail so tools still run.
f2d_check_pins() {
  local z; z="$(zig version 2>/dev/null)"
  [ "$z" = "0.17.0" ] || echo "machine-env: WARNING zig is '${z:-missing}', run1 pins 0.17.0" >&2
}

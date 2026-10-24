#!/usr/bin/env bash
# One machine-wide GNU make jobserver (SPEC 9.6.1). LINUX ONLY (named FIFOs + make jobserver protocol; SPEC 15.4).
#
#   source harness/jobserver.sh [cores]     # exports MAKEFLAGS and CARGO_MAKEFLAGS, starts the token holder
#   jobserver_stop                          # remove the FIFO and stop the holder
#
# The FIFO is preloaded with (cores - 1) tokens: every make/cargo client implicitly owns one more "free" slot, so
# `cores` jobs can run machine-wide at most. Cargo and make >= 4.4 understand --jobserver-auth=fifo:PATH.
# SPEC 9.6.1 asks to verify at the start that the pinned Cargo honors the FIFO form (watch procs_peak with 4 copies);
# if not, use the classic pipe form: run the 4 copies as recipes of one top-level `make -j<cores>`.
# A mixed-in client that does not honor the jobserver simply ignores it, so builds still work, just uncapped.

_js_is_linux() { [ "$(uname -s)" = Linux ]; }
if ! _js_is_linux; then
  echo "jobserver.sh: skipped: Linux-only (SPEC 15.4)" >&2
  return 0 2>/dev/null || exit 0
fi

jobserver_start() {
  local cores="${1:-$(nproc)}"
  JOBSERVER_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/f2d-jobserver.XXXXXX")"
  mkfifo "$JOBSERVER_FIFO" || return 1
  # Hold the FIFO open read-write so tokens written now survive until clients read them (fd 9 in this shell and
  # in a background holder; a FIFO opened O_RDWR never blocks and never loses its buffer while any fd is open).
  exec 9<>"$JOBSERVER_FIFO"
  local i; for ((i = 1; i < cores; i++)); do printf '+' >&9; done
  ( exec 9<>"$JOBSERVER_FIFO"; while :; do sleep 3600; done ) &
  JOBSERVER_HOLDER=$!
  export MAKEFLAGS="-j$cores --jobserver-auth=fifo:$JOBSERVER_FIFO"
  export CARGO_MAKEFLAGS="$MAKEFLAGS"
  export JOBSERVER_FIFO JOBSERVER_HOLDER
}

jobserver_stop() {
  [ -n "${JOBSERVER_HOLDER:-}" ] && kill "$JOBSERVER_HOLDER" 2>/dev/null   # only the PID we started
  exec 9>&- 2>/dev/null
  [ -n "${JOBSERVER_FIFO:-}" ] && rm -f "$JOBSERVER_FIFO"
  unset MAKEFLAGS CARGO_MAKEFLAGS JOBSERVER_FIFO JOBSERVER_HOLDER
}

jobserver_start "${1:-}"

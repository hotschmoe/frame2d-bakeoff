#!/usr/bin/env bash
# usage: server_conformance.sh <stack> [--url http://127.0.0.1:18080]
# Starts the stack's server via stack.sh `run_server` (unless --url is given), then runs server_conformance.py.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STACK="${1:?stack}"; shift
if [ "${1:-}" = "--url" ]; then exec python "$HERE/server_conformance.py" "$2"; fi
# one port per stack so parallel agent runs do not collide; override with F2D_PORT
case "$STACK" in
  rust) OFF=0;; go) OFF=1;; zig) OFF=2;; rust-flutter) OFF=3;; zig-flutter) OFF=4;; go-flutter) OFF=5;; go-zig-flutter) OFF=6;; *) OFF=7;;
esac
ADDR="127.0.0.1:${F2D_PORT:-$((18080 + OFF))}"
( cd "$HERE/../stacks/$STACK" && source ./stack.sh && FRAME2D_ADDR="$ADDR" run_server ) &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null' EXIT
python "$HERE/server_conformance.py" "http://$ADDR"

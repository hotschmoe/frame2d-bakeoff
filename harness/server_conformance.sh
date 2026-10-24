#!/usr/bin/env bash
# usage: server_conformance.sh <stack> [--url http://127.0.0.1:18080]
# Starts the stack's server via stack.sh `run_server` (unless --url is given), then runs server_conformance.py.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
STACK="${1:?stack}"; shift
if [ "${1:-}" = "--url" ]; then exec python "$HERE/server_conformance.py" "$2"; fi
ADDR="127.0.0.1:18080"
( cd "$HERE/../stacks/$STACK" && source ./stack.sh && FRAME2D_ADDR="$ADDR" run_server ) &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null' EXIT
python "$HERE/server_conformance.py" "http://$ADDR"

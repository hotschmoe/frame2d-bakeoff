#!/usr/bin/env bash
# SPEC 9.2 edit: response header value a <-> b
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi
exec $PY "$(dirname "$0")/toggle.py" "$1" server 'x-frame2d: a' 'x-frame2d: b'

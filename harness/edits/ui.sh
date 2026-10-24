#!/usr/bin/env bash
# SPEC 9.2 edit: toolbar label Solve <-> Solve!
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi
exec $PY "$(dirname "$0")/toggle.py" "$1" ui '"Solve"' '"Solve!"'

#!/usr/bin/env bash
# SPEC 9.2 edit: pivot tolerance 1e-12 <-> 2e-12
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi
exec $PY "$(dirname "$0")/toggle.py" "$1" leaf '1e-12' '2e-12'

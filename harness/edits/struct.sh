#!/usr/bin/env bash
# SPEC 9.2 edit: bench_pad width u32 <-> u64
if python3 -c pass >/dev/null 2>&1; then PY=python3; else PY=python; fi
exec $PY "$(dirname "$0")/toggle.py" "$1" struct 'u32|uint32' 'u64|uint64'

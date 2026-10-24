#!/usr/bin/env bash
# SPEC 9.2 edit: bench_pad width u32 <-> u64
exec python "$(dirname "$0")/toggle.py" "$1" struct 'u32|uint32' 'u64|uint64'

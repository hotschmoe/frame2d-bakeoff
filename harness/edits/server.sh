#!/usr/bin/env bash
# SPEC 9.2 edit: response header value a <-> b
exec python "$(dirname "$0")/toggle.py" "$1" server 'x-frame2d: a' 'x-frame2d: b'

#!/usr/bin/env bash
# SPEC 9.2 edit: toolbar label Solve <-> Solve!
exec python "$(dirname "$0")/toggle.py" "$1" ui '"Solve"' '"Solve!"'

#!/usr/bin/env bash
# SPEC 9.2 edit: pivot tolerance 1e-12 <-> 2e-12
exec python "$(dirname "$0")/toggle.py" "$1" leaf '1e-12' '2e-12'

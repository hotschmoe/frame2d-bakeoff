#!/usr/bin/env bash
# edit.sh <stack-dir> <leaf|struct|server|ui>   apply harness/edits/<edit>.sh to that stack dir and count it
# edit.sh <stack-dir> --restore                 undo every counted edit (toggle once more where the count is odd)
# The edits alternate between two states, so an odd count means the stack is left modified. Counters live outside
# the repo, in $BL_STATE_DIR (default $TMPDIR/f2d-bl-state), so a stack never gets extra files.
HERE="$(cd "$(dirname "$0")" && pwd)"
SD="$1"; E="$2"
CNT_DIR="${BL_STATE_DIR:-${TMPDIR:-/tmp}/f2d-bl-state}/$(echo "$SD" | tr '/:\\' '___')"
mkdir -p "$CNT_DIR"
if [ "$E" = "--restore" ]; then
  for e in leaf struct server ui; do
    n=$(cat "$CNT_DIR/$e" 2>/dev/null || echo 0)
    if [ $((n % 2)) = 1 ]; then bash "$HERE/../edits/$e.sh" "$SD" >/dev/null && echo "restored edit $e in $SD" >&2; fi
    rm -f "$CNT_DIR/$e"
  done
  exit 0
fi
bash "$HERE/../edits/$E.sh" "$SD" >/dev/null || exit $?
n=$(cat "$CNT_DIR/$E" 2>/dev/null || echo 0); echo $((n + 1)) > "$CNT_DIR/$E"

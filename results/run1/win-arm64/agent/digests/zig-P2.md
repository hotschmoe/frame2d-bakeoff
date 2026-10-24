# Failure digest: zig P2

Phase start 2026-10-24T06:38:53Z, active wall 1.7 min (stalls removed), 3 build/check commands, 4 build/check/test/conformance commands, 1 flagged failures.

Failures are extracted heuristically (see harness/agentlog/README.md). A `reasons` entry starting with `inferred:` means the exit code was 0 (pipes such as `| tail` hide it) and the failure was inferred from output text; such items can be false positives. If an item is not a real failure of the kind named, classify it `false_positive`.

| id | min | kind | next success (min) | signature |
|---|---|---|---|---|
| F1 | 1.2 | check | 0.1 | /usr/bin/bash: line 1: stacks/zig/stack.sh: No such file or directory |

## F1  2026-10-24T06:40:07Z  (+1.2 min)  kind=check
- primary kind: check; duration 1 s; reasons: inferred: missing tool/file
- command: `cd $REPO/stacks/zig/src; python - <<'E'
<heredoc body, 9 lines elided>
cd ..; date >> /dev/null; source stack.sh; bash ../../harness/measure.sh zig p2_build -- bash -c 'source stacks/zig/stack.sh && build_check' 2>&1 | tail -30`
- output:
```
/usr/bin/bash: line 1: stacks/zig/stack.sh: No such file or directory
```
- next success of same kind (check): 2026-10-24T06:40:12Z, 0.1 min after the failure: `cd $REPO; bash harness/measure.sh zig p2_build -- bash -c 'source stacks/zig/stack.sh && build_check' 2>&1 | tail -30`

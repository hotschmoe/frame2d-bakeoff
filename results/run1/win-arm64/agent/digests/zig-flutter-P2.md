# Failure digest: zig-flutter P2

Phase start 2026-10-24T06:56:18Z, active wall 3.0 min (stalls removed), 3 build/check commands, 5 build/check/test/conformance commands, 1 flagged failures.

Failures are extracted heuristically (see harness/agentlog/README.md). A `reasons` entry starting with `inferred:` means the exit code was 0 (pipes such as `| tail` hide it) and the failure was inferred from output text; such items can be false positives. If an item is not a real failure of the kind named, classify it `false_positive`.

| id | min | kind | next success (min) | signature |
|---|---|---|---|---|
| F1 | 2.2 | check | 0.2 | +- compile exe frameNd debug native N errors |

## F1  2026-10-24T06:58:29Z  (+2.2 min)  kind=check
- primary kind: check; duration 2 s; reasons: inferred: error: line; inferred: file:line diagnostic; inferred: zig build failed
- command: `cd $REPO; bash harness/measure.sh zig-flutter p2-check -- bash -c 'source stacks/zig-flutter/stack.sh; build_check' 2>&1 | tail -40`
- output:
```
+- compile exe frame2d debug native 1 errors
src\engine\solver.zig:151:45: error: value with comptime-only type 'comptime_float' depends on runtime control flow
        if (mem.rel & 1 == 0) rz[mem.i] += (if (mem.rel & 2 != 0) 3.0 else 4.0) * ei / L;
                                            ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
src\engine\solver.zig:151:25: note: runtime control flow here
            ~~~~~~~~~~~~^~~~
    buildPlan: src\engine\solver.zig:169:34
    prepare: src\engine\solver.zig:427:31
    7 reference(s) hidden; use '-freference-trace=9' to see all references
error: 1 compilation errors
failed command: "C:\\Users\\hotschmoe\\AppData\\Local\\Microsoft\\WinGet\\Packages\\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\\zig-aarch64-windows-0.17.0\\zig.exe" build-exe -O
check
+- compile exe frame2d-server debug native 1 errors
failed command: "C:\\Users\\hotschmoe\\AppData\\Local\\Microsoft\\WinGet\\Packages\\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\\zig-aarch64-windows-0.17.0\\zig.exe" build-exe -c
Build Summary: 0/6 steps succeeded (5 failed)
check transitive failure
+- compile lib frame2d_engine debug x86_64-windows-gnu 1 errors
+- compile exe frame2d_engine debug wasm32-freestanding 1 errors
+- compile test debug native 1 errors
error: the following build command exited with code 1:
.zig-global\o\2af29872fe1ed9f87ecb89eac8b4be25\maker.exe build --zig-lib=C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zi
```
- agent after: Now build and run conformance.
- next success of same kind (check): 2026-10-24T06:58:44Z, 0.2 min after the failure: `cd $REPO; sed -i 's/(if (mem.rel \& 2 != 0) 3.0 else 4.0)/(if (mem.rel \& 2 != 0) @as(f64, 3) else 4)/; s/(if (mem.rel \& 1 != 0) 3.0 else 4.0)/(if (m ...  bash harness/measure.sh zig-flutter p2-check -- bash -c 'source stacks/zig-flutter/stack.sh; build_check' 2>&1 | grep -v "^failed command" | head -40`

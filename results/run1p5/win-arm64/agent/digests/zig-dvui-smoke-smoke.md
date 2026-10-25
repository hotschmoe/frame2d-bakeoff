# Failure digest: zig-dvui-smoke smoke

Phase start 2026-10-24T05:53:00Z, active wall 7.2 min (stalls removed), 7 build/check commands, 7 build/check/test/conformance commands, 4 flagged failures.

Failures are extracted heuristically (see harness/agentlog/README.md). A `reasons` entry starting with `inferred:` means the exit code was 0 (pipes such as `| tail` hide it) and the failure was inferred from output text; such items can be false positives. If an item is not a real failure of the kind named, classify it `false_positive`.

| id | min | kind | next success (min) | signature |
|---|---|---|---|---|
| F1 | 2.3 | build | 2.0 | FILE.zon:N:N: error: invalid fingerprint: NxNdNcNaNeNbNfNaN; if this is a new or forked package, use |
| F2 | 3.1 | build | 1.7 | FILE:N:N: error: no field named 'Debug' in enum 'lang.Optimize' |
| F3 | 3.5 | build | 0.5 |    +- compile exe smoke safe native N errors |
| F4 | 4.6 | build | 0.4 |    +- compile exe smoke safe native N errors |

## F1  2026-10-24T05:55:18Z  (+2.3 min)  kind=build
- primary kind: build; duration 43 s; reasons: inferred: error: line; inferred: zig build failed
- command: `cd "$SCRATCH/dvui-smoke/app"; zig fetch --save=dvui "git+https://github.com/david-vanderson/dvui#275c248f6a2a80f92723ac93242310e16201a49b" 2>&1 | tail -5; cat build.zig.zon; time zig build -Doptimize=ReleaseSafe 2>&1 | tail -40`
- output:
```
build.zig.zon:1:2: error: invalid fingerprint: 0x5d1c0a7e3b9f2a41; if this is a new or forked package, use this value: 0x9376e368a4dc3e0a
.{
 ^
error: the following build command exited with code 2:
C:\Users\hotschmoe\AppData\Local\zig\o\2af29872fe1ed9f87ecb89eac8b4be25\maker.exe fetch --zig-lib=C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winge
build.zig.zon:1:2: error: invalid fingerprint: 0x5d1c0a7e3b9f2a41; if this is a new or forked package, use this value: 0x9376e36896f575b9
C:\Users\hotschmoe\AppData\Local\zig\o\2af29872fe1ed9f87ecb89eac8b4be25\maker.exe build --zig-lib=C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winge
real	0m0.096s
```
- agent before: Nothing ran. I'll use Write.
- next success of same kind (build): 2026-10-24T05:58:03Z, 2.0 min after the failure: `cd "$SCRATCH/dvui-smoke/app"; sed -i 's/.color_text = .{ .r = 200, .g = 200, .b = 200, .a = 255 }/.color_text = .{ .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 } }/' src/main.zig; zig build -Doptimize=safe 2>&1 | grep -v "^failed command" | cut -c1-400 | tail -30; ls -la zig-out/bin`

## F2  2026-10-24T05:56:06Z  (+3.1 min)  kind=build
- primary kind: build; duration 15 s; reasons: inferred: error: line; inferred: file:line diagnostic; inferred: zig build failed
- command: `cd "$SCRATCH/dvui-smoke/app"; sed -i 's/0x5d1c0a7e3b9f2a41/0x9376e36896f575b9/' build.zig.zon; zig fetch --save=dvui "git+https://github.com/david-vanderson/dvui#275c248f6a2a80f92723ac93242310e16201a49b" 2>&1 | tail -5; cat build.zig.zon; time zig build -Doptimize=ReleaseSafe 2>&1 | tail -40`
- output:
```
build.zig:39:39: error: no field named 'Debug' in enum 'lang.Optimize'
                .strip = optimize != .Debug,
                                     ~^~~~~
C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-aarch64-windows-0.17.0\lib\std\lang.zig:113:22: note: enum declared her
pub const Optimize = enum {
                     ^~~~
referenced by:
    runPackageScript [inlined]: C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-aarch64-windows-0.17.0\lib\std\Build.zi
    main: C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-aarch64-windows-0.17.0\lib\compiler\configurer.zig:138:29
    3 reference(s) hidden; use '-freference-trace=5' to see all references
error: the following build command exited with code 1:
C:\Users\hotschmoe\AppData\Local\zig\o\2af29872fe1ed9f87ecb89eac8b4be25\maker.exe build --zig-lib=C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winge
real	0m7.970s
```
- next success of same kind (build): 2026-10-24T05:58:03Z, 1.7 min after the failure: `cd "$SCRATCH/dvui-smoke/app"; sed -i 's/.color_text = .{ .r = 200, .g = 200, .b = 200, .a = 255 }/.color_text = .{ .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 } }/' src/main.zig; zig build -Doptimize=safe 2>&1 | grep -v "^failed command" | cut -c1-400 | tail -30; ls -la zig-out/bin`

## F3  2026-10-24T05:56:27Z  (+3.5 min)  kind=build
- primary kind: build; duration 64 s; reasons: inferred: error: line; inferred: file:line diagnostic; inferred: zig build failed
- command: `cd "$SCRATCH/dvui-smoke/app"; sed -i 's/optimize != .Debug/optimize != .debug/' build.zig; time zig build -Doptimize=safe 2>&1 | tail -40`
- output:
```
   +- compile exe smoke safe native 1 errors
src\main.zig:69:93: error: no field named 'r' in union 'Gradient.ColorOrGradient'
    var ov = dvui.overlay(@src(), .{ .expand = .both, .background = true, .color_fill = .{ .r = 24, .g = 28, .b = 36, .a = 255 } });
                                              ^
zig-pkg\dvui-0.6.0-dev-AQFJmWZLBAG6E9WSTCqdouXXCC8gF91z6oiLmZvh3e-5\src\Gradient.zig:633:29: note: union declared here
pub const ColorOrGradient = union(enum) {
                            ^~~~~
referenced by:
    frame: src\main.zig:37:11
    appIterate: zig-pkg\dvui-0.6.0-dev-AQFJmWZLBAG6E9WSTCqdouXXCC8gF91z6oiLmZvh3e-5\src\backends\sdl.zig:2550:26
    5 reference(s) hidden; use '-freference-trace=7' to see all references
error: 1 compilation errors
failed command: "C:\\Users\\hotschmoe\\AppData\\Local\\Microsoft\\WinGet\\Packages\\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\\zig-aarch64-windows-0.17.0\\zig.exe" build-exe -O
Build Summary: 35/38 steps succeeded (1 failed)
install transitive failure
+- install smoke transitive failure
error: the following build command exited with code 1:
C:\Users\hotschmoe\AppData\Local\zig\o\2af29872fe1ed9f87ecb89eac8b4be25\maker.exe build --zig-lib=C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winge
real	1m3.257s
```
- next success of same kind (build): 2026-10-24T05:58:03Z, 0.5 min after the failure: `cd "$SCRATCH/dvui-smoke/app"; sed -i 's/.color_text = .{ .r = 200, .g = 200, .b = 200, .a = 255 }/.color_text = .{ .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 } }/' src/main.zig; zig build -Doptimize=safe 2>&1 | grep -v "^failed command" | cut -c1-400 | tail -30; ls -la zig-out/bin`

## F4  2026-10-24T05:57:35Z  (+4.6 min)  kind=build
- primary kind: build; duration 1 s; reasons: exit code 2; inferred: error: line; inferred: file:line diagnostic; inferred: zig build failed; inferred: missing tool/file
- command: `cd "$SCRATCH/dvui-smoke/app"; sed -i 's/.color_fill = .{ .r = 24, .g = 28, .b = 36, .a = 255 }/.color_fill = .{ .color = .{ .r = 24, .g = 28, .b = 36, .a = 255 } }/' src/main.zig; zig build -Doptimize=safe 2>&1 | grep -v "^failed command" | cut -c1-400 | tail -30; ls -la zig-out/bin`
- output:
```
   +- compile exe smoke safe native 1 errors
src\main.zig:119:131: error: no field named 'r' in union 'Gradient.ColorOrGradient'
    dvui.label(@src(), "drag: pan   wheel: zoom   zoom={d:.2} pan=({d:.0},{d:.0})", .{ zoom, pan.x, pan.y }, .{ .color_text = .{ .r = 200, .g = 200, .b = 200, .a = 255 } });
                                                                 ^
zig-pkg\dvui-0.6.0-dev-AQFJmWZLBAG6E9WSTCqdouXXCC8gF91z6oiLmZvh3e-5\src\Gradient.zig:633:29: note: union declared here
pub const ColorOrGradient = union(enum) {
                            ^~~~~
referenced by:
    frame: src\main.zig:37:11
    appIterate: zig-pkg\dvui-0.6.0-dev-AQFJmWZLBAG6E9WSTCqdouXXCC8gF91z6oiLmZvh3e-5\src\backends\sdl.zig:2550:26
    5 reference(s) hidden; use '-freference-trace=7' to see all references
error: 1 compilation errors
Build Summary: 35/38 steps succeeded (1 failed)
install transitive failure
+- install smoke transitive failure
error: the following build command exited with code 1:
C:\Users\hotschmoe\AppData\Local\zig\o\2af29872fe1ed9f87ecb89eac8b4be25\maker.exe build --zig-lib=C:\Users\hotschmoe\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winge
ls: cannot access 'zig-out/bin': No such file or directory
```
- next success of same kind (build): 2026-10-24T05:58:03Z, 0.4 min after the failure: `cd "$SCRATCH/dvui-smoke/app"; sed -i 's/.color_text = .{ .r = 200, .g = 200, .b = 200, .a = 255 }/.color_text = .{ .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 } }/' src/main.zig; zig build -Doptimize=safe 2>&1 | grep -v "^failed command" | cut -c1-400 | tail -30; ls -la zig-out/bin`

# Failure digest: rust-flutter P1

Phase start 2026-10-24T06:23:14Z, active wall 78.2 min (stalls removed), 63 build/check commands, 76 build/check/test/conformance commands, 15 flagged failures.

Failures are extracted heuristically (see harness/agentlog/README.md). A `reasons` entry starting with `inferred:` means the exit code was 0 (pipes such as `| tail` hide it) and the failure was inferred from output text; such items can be false positives. If an item is not a real failure of the kind named, classify it `false_positive`.

| id | min | kind | next success (min) | signature |
|---|---|---|---|---|
| F1 | 6.9 | build | 0.7 | /usr/bin/bash: -c: line N: unexpected EOF while looking for matching `'' |
| F2 | 11.6 | check | 1.4 | wasmN-unknown-unknown |
| F3 | 11.8 | build | 9.1 | Error: When compute_mod_from_rust_path(code_path="FILE", base_dir="\\\ |
| F4 | 11.9 | build | 9.1 | Error: When compute_mod_from_rust_path(code_path="FILE", base_dir=" |
| F5 | 11.9 | build | 9.0 | Error: When compute_mod_from_rust_path(code_path="C:\\?FILE", bas |
| F6 | 12.0 | build | 8.1 | error[EN]: file not found for module `frb_generated` |
| F7 | 18.3 | build | 2.5 | FILE:N:    pub member_length: Vec<fN>, |
| F8 | 30.6 | run | none | /usr/bin/bash: line 1:   716 Segmentation fault         timeout 100 ./frame2d_app.exe --bench=drag - |
| F9 | 30.7 | run | none | ✓ Built build\windows\x64\runner\Release\frame2d_app.exe |
| F10 | 31.4 | run | none | /usr/bin/bash: line 1:   768 Segmentation fault         timeout 8 ./frame2d_app.exe > /tmp/e.txt 2>& |
| F11 | 31.6 | run | none | Analyzing app... |
| F12 | 32.4 | run | none | ✓ Built build\windows\x64\runner\Release\frame2d_app.exe |
| F13 | 33.0 | run | none | ✓ Built build\windows\x64\runner\Release\frame2d_app.exe |
| F14 | 51.9 | run | none | /usr/bin/bash: line 1:  1629 Segmentation fault         F2D_DISCARD=1 F2D_MESH=1 F2D_NO_MOMENT=1 tim |
| F15 | 58.4 | test | 0.1 |    --> FILE:N:N |

## F1  2026-10-24T06:30:06Z  (+6.9 min)  kind=build
- primary kind: build; duration 0 s; reasons: exit code 2
- command: `cd $REPO/stacks/rust-flutter/crates; sed -i 's/if dj <= 1e-12 \* max_diag { \/\/ BENCH-EDIT:leaf/if !(dj > 1e-12 * max_diag) { \/\/ BENCH-EDIT:leaf/' engine/src/skyline.rs; grep -n BENCH engine/src/skyline.rs
cat > cli/src/alloc.rs <<'EOF'
<heredoc body, 76 lines elided>
cat > cli/src/main.rs <<'EOF'
<heredoc body, 156 lines elided>
cd ..; source ../../harness/machine-env.sh; cargo build -p frame2d-cli --release 2>&1 | tail -30`
- output:
```
/usr/bin/bash: -c: line 144: unexpected EOF while looking for matching `''
```
- next success of same kind (build): 2026-10-24T06:30:46Z, 0.7 min after the failure: `cd $REPO/stacks/rust-flutter; source ../../harness/machine-env.sh; sed -i 's|members = .*|members = ["crates/engine", "crates/cli"]|' Cargo.toml; cat crates/engine/Cargo.toml; time cargo build -p frame2d-cli --release 2>&1 | tail -30`

## F2  2026-10-24T06:34:51Z  (+11.6 min)  kind=check
- primary kind: check; duration 6 s; reasons: inferred: error: line; inferred: build failed text
- command: `cd $REPO/stacks/rust-flutter; source ../../harness/machine-env.sh; rustup target list --installed; cargo check -p frame2d-bridge --target x86_64-pc-windows-msvc 2>&1 | tail -20`
- output:
```
wasm32-unknown-unknown
x86_64-pc-windows-msvc
    Checking futures-util v0.3.34
error[E0583]: file not found for module `frb_generated`
  --> crates\bridge\src\lib.rs:10:1
   |
10 | mod frb_generated;
   | ^^^^^^^^^^^^^^^^^^
   = help: to create the module `frb_generated`, create file "crates\bridge\src\frb_generated.rs" or "crates\bridge\src\frb_generated\mod.rs"
   = note: if there is a `mod frb_generated` elsewhere in the crate already, import it with `use crate::...` instead
For more information about this error, try `rustc --explain E0583`.
error: could not compile `frame2d-bridge` (lib) due to 1 previous error
```
- agent after: Expected. Now run the FRB codegen.
- next success of same kind (check): 2026-10-24T06:36:23Z, 1.4 min after the failure: `cd $REPO/stacks/rust-flutter; source ../../harness/machine-env.sh; cargo check -p frame2d-bridge --target x86_64-pc-windows-msvc 2>&1 | tail -20; carg ... ridge --target wasm32-unknown-unknown 2>&1 | tail -20; cat app/lib/generated/frb_generated.dart | head -120; cat app/lib/generated/api.dart | head -60`

## F3  2026-10-24T06:35:00Z  (+11.8 min)  kind=build
- primary kind: build; duration 0 s; reasons: inferred: Error: line
- command: `cd $REPO/stacks/rust-flutter; source ../../harness/machine-env.sh; time flutter_rust_bridge_codegen generate 2>&1 | tail -40`
- output:
```
Error: When compute_mod_from_rust_path(code_path="C:\\Users\\hotschmoe\\Documents\\GitHub\\frame2d-bakeoff\\stacks\\rust-flutter\\crates/bridge/src/frb_generated.rs", base_dir="\\\
Caused by:
    prefix not found
real	0m0.062s
user	0m0.016s
```
- agent before: Expected. Now run the FRB codegen.
- next success of same kind (build): 2026-10-24T06:44:09Z, 9.1 min after the failure: `cd $REPO/stacks/rust-flutter/app/windows; python - <<'XEOF'
<heredoc body, 14 lines elided>
cd ../..; source ../../harness/machine-env.sh; cargo build -p frame2d-bridge --target x86_64-pc-windows-msvc 2>&1 | tail -5; ls target/x86_64-pc-windows-msvc/debug/*.dll`

## F4  2026-10-24T06:35:05Z  (+11.9 min)  kind=build
- primary kind: build; duration 0 s; reasons: inferred: Error: line
- command: `cd $REPO/stacks/rust-flutter; source ../../harness/machine-env.sh; cat > flutter_rust_bridge.yaml <<'XEOF'
<heredoc body, 5 lines elided>
flutter_rust_bridge_codegen generate 2>&1 | tail -30`
- output:
```
Error: When compute_mod_from_rust_path(code_path="C:\\Users\\hotschmoe\\Documents\\GitHub\\frame2d-bakeoff\\stacks\\rust-flutter\\crates\\bridge\\src\\frb_generated.rs", base_dir="
Caused by:
    prefix not found
```
- agent before: Expected. Now run the FRB codegen.
- next success of same kind (build): 2026-10-24T06:44:09Z, 9.1 min after the failure: `cd $REPO/stacks/rust-flutter/app/windows; python - <<'XEOF'
<heredoc body, 14 lines elided>
cd ../..; source ../../harness/machine-env.sh; cargo build -p frame2d-bridge --target x86_64-pc-windows-msvc 2>&1 | tail -5; ls target/x86_64-pc-windows-msvc/debug/*.dll`

## F5  2026-10-24T06:35:10Z  (+11.9 min)  kind=build
- primary kind: build; duration 1 s; reasons: inferred: Error: line
- command: `cd $REPO/stacks/rust-flutter; source ../../harness/machine-env.sh; cat > flutter_rust_bridge.yaml <<'XEOF'
<heredoc body, 5 lines elided>
flutter_rust_bridge_codegen generate 2>&1 | tail -30`
- output:
```
Error: When compute_mod_from_rust_path(code_path="C:\\?\\C:\\Users\\hotschmoe\\Documents\\GitHub\\frame2d-bakeoff\\stacks\\rust-flutter\\crates\\bridge\\src\\frb_generated.rs", bas
Caused by:
    prefix not found
```
- next success of same kind (build): 2026-10-24T06:44:09Z, 9.0 min after the failure: `cd $REPO/stacks/rust-flutter/app/windows; python - <<'XEOF'
<heredoc body, 14 lines elided>
cd ../..; source ../../harness/machine-env.sh; cargo build -p frame2d-bridge --target x86_64-pc-windows-msvc 2>&1 | tail -5; ls target/x86_64-pc-windows-msvc/debug/*.dll`

## F6  2026-10-24T06:35:14Z  (+12.0 min)  kind=build
- primary kind: build; duration 50 s; reasons: inferred: error: line
- command: `cd $REPO/stacks/rust-flutter; source ../../harness/machine-env.sh; cat > flutter_rust_bridge.yaml <<'XEOF'
<heredoc body, 4 lines elided>
flutter_rust_bridge_codegen generate 2>&1 | tail -30`
- output:
```
error[E0583]: file not found for module `frb_generated`
  --> crates\bridge\src\lib.rs:10:1
   |
10 | mod frb_generated;
   | ^^^^^^^^^^^^^^^^^^
   = help: to create the module `frb_generated`, create file "crates\bridge\src\frb_generated.rs" or "crates\bridge\src\frb_generated\mod.rs"
   = note: if there is a `mod frb_generated` elsewhere in the crate already, import it with `use crate::...` instead
For more information about this error, try `rustc --explain E0583`.
[2026-10-24T06:35:56.571Z INFO C:\Users\hotschmoe\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\flutter_rust_bridge_codegen-2.13.0\src\library\codegen\parser\mir\parser\ty\l
Done!
```
- next success of same kind (build): 2026-10-24T06:44:09Z, 8.1 min after the failure: `cd $REPO/stacks/rust-flutter/app/windows; python - <<'XEOF'
<heredoc body, 14 lines elided>
cd ../..; source ../../harness/machine-env.sh; cargo build -p frame2d-bridge --target x86_64-pc-windows-msvc 2>&1 | tail -5; ls target/x86_64-pc-windows-msvc/debug/*.dll`

## F7  2026-10-24T06:41:33Z  (+18.3 min)  kind=build
- primary kind: build; duration 6 s; reasons: inferred: file:line diagnostic
- command: `cd $REPO/stacks/rust-flutter; python - <<'XEOF'
<heredoc body, 26 lines elided>
grep -n "member_length" crates/bridge/src/*.rs | head; source ../../harness/machine-env.sh; flutter_rust_bridge_codegen generate 2>&1 | tail -3`
- output:
```
crates/bridge/src/api.rs:21:    pub member_length: Vec<f64>,
crates/bridge/src/api.rs:102:    let mut member_length = Vec::with_capacity(model.members.len());
crates/bridge/src/api.rs:107:        member_length.push((b.x - a.x).hypot(b.y - a.y));
crates/bridge/src/api.rs:135:        member_length,
crates/bridge/src/api.rs:191:        member_length: results.member_length.clone(),
crates/bridge/src/frb_generated.rs:393:            member_length: var_memberLength,
crates/bridge/src/frb_generated.rs:514:            self.member_length.into_into_dart().into_dart(),
crates/bridge/src/frb_generated.rs:643:        <Vec<f64>>::sse_encode(self.member_length, serializer);
crates/bridge/src/web.rs:44:    member_length: Vec<f64>,
[2026-10-24T06:41:34.379Z INFO C:\Users\hotschmoe\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\flutter_rust_bridge_codegen-2.13.0\src\library\commands\fvm.rs:28] Has .fvmrc
[2026-10-24T06:41:35.855Z INFO C:\Users\hotschmoe\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\flutter_rust_bridge_codegen-2.13.0\src\library\codegen\parser\mir\parser\ty\l
Done!
```
- agent before: Now the canvas view and member table.
- next success of same kind (build): 2026-10-24T06:44:09Z, 2.5 min after the failure: `cd $REPO/stacks/rust-flutter/app/windows; python - <<'XEOF'
<heredoc body, 14 lines elided>
cd ../..; source ../../harness/machine-env.sh; cargo build -p frame2d-bridge --target x86_64-pc-windows-msvc 2>&1 | tail -5; ls target/x86_64-pc-windows-msvc/debug/*.dll`

## F8  2026-10-24T06:53:51Z  (+30.6 min)  kind=run
- primary kind: run; duration 2 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/rust-flutter/app/build/windows/x64/runner/Release; timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1; echo "exit $?"; cat /tmp/d.txt | tail -5`
- output:
```
/usr/bin/bash: line 1:   716 Segmentation fault         timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1
exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
```
- next success of same kind (run): none in this transcript

## F9  2026-10-24T06:53:58Z  (+30.7 min)  kind=build
- primary kind: run; duration 36 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/rust-flutter/app; python - <<'XEOF'
<heredoc body, 5 lines elided>
source ../../../harness/machine-env.sh; export F2D_BRIDGE_DLL="$PWD/../target/x86_64-pc-windows-msvc/release/frame2d_bridge.dll"; flutter build windows --release 2>&1 | tail -1; cd build/windows/x64/runner/Release; timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1; echo "exit $?"; cat /tmp/d.txt | tail -5`
- output:
```
✓ Built build\windows\x64\runner\Release\frame2d_app.exe
/usr/bin/bash: line 7:   762 Segmentation fault         timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1
exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
```
- next success of same kind (run): none in this transcript

## F10  2026-10-24T06:54:37Z  (+31.4 min)  kind=run
- primary kind: run; duration 3 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/rust-flutter/app/build/windows/x64/runner/Release; (timeout 8 ./frame2d_app.exe > /tmp/e.txt 2>&1; echo "exit $?") ; tail -3 /tmp/e.txt; timeout 60 ./frame2d_app.exe --bench=startup > /tmp/s.txt 2>&1; echo "startup exit $?"; tail -2 /tmp/s.txt`
- output:
```
/usr/bin/bash: line 1:   768 Segmentation fault         timeout 8 ./frame2d_app.exe > /tmp/e.txt 2>&1
exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
/usr/bin/bash: line 1:   771 Segmentation fault         timeout 60 ./frame2d_app.exe --bench=startup > /tmp/s.txt 2>&1
startup exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
```
- next success of same kind (run): none in this transcript

## F11  2026-10-24T06:54:49Z  (+31.6 min)  kind=check/build
- primary kind: run; duration 41 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/rust-flutter/app; python - <<'XEOF'
<heredoc body, 55 lines elided>
source ../../../harness/machine-env.sh; flutter analyze 2>&1 | tail -3; export F2D_BRIDGE_DLL="$PWD/../target/x86_64-pc-windows-msvc/release/frame2d_bridge.dll"; flutter build windows --release 2>&1 | tail -1; cd build/windows/x64/runner/Release; timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1; echo "exit $?"; cat /tmp/d.txt | tail -3`
- output:
```
Analyzing app...
No issues found! (ran in 6.1s)
✓ Built build\windows\x64\runner\Release\frame2d_app.exe
/usr/bin/bash: line 57:   896 Segmentation fault         timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1
exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
```
- next success of same kind (run): none in this transcript

## F12  2026-10-24T06:55:38Z  (+32.4 min)  kind=build
- primary kind: run; duration 30 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/rust-flutter/app; sed -i 's/ bool showDeflected = true;/ bool showDeflected = false;/' lib/state/app_state.dart; source ../../../harness/machine-env.sh; export F2D_BRIDGE_DLL="$PWD/../target/x86_64-pc-windows-msvc/release/frame2d_bridge.dll"; flutter build windows --release 2>&1 | tail -1; cd build/windows/x64/runner/Release; timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1; echo "exit $?"; cat /tmp/d.txt | tail -3`
- output:
```
✓ Built build\windows\x64\runner\Release\frame2d_app.exe
/usr/bin/bash: line 1:  1851 Segmentation fault         timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1
exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
[This command modified 1 file you've previously read: stacks\rust-flutter\app\lib\state\app_state.dart. Call Read before editing.]
```
- next success of same kind (run): none in this transcript

## F13  2026-10-24T06:56:15Z  (+33.0 min)  kind=build
- primary kind: run; duration 30 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/rust-flutter/app; cp lib/ui/scene.dart /tmp/scene_mesh.dart; python - <<'XEOF'
<heredoc body, 9 lines elided>
source ../../../harness/machine-env.sh; export F2D_BRIDGE_DLL="$PWD/../target/x86_64-pc-windows-msvc/release/frame2d_bridge.dll"; flutter build windows --release 2>&1 | tail -1; cd build/windows/x64/runner/Release; timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1; echo "exit $?"; cat /tmp/d.txt | tail -3`
- output:
```
✓ Built build\windows\x64\runner\Release\frame2d_app.exe
/usr/bin/bash: line 11:  1213 Segmentation fault         timeout 100 ./frame2d_app.exe --bench=drag --frames=40 > /tmp/d.txt 2>&1
exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
```
- next success of same kind (run): none in this transcript

## F14  2026-10-24T07:15:09Z  (+51.9 min)  kind=run
- primary kind: run; duration 1 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/rust-flutter/app/build/windows/x64/runner/Release; F2D_DISCARD=1 F2D_MESH=1 F2D_NO_MOMENT=1 timeout 60 ./frame2d_app.exe --bench=startup > /tmp/out.txt 2> /tmp/err.txt; echo "exit $?"; tail -12 /tmp/err.txt`
- output:
```
/usr/bin/bash: line 1:  1629 Segmentation fault         F2D_DISCARD=1 F2D_MESH=1 F2D_NO_MOMENT=1 timeout 60 ./frame2d_app.exe --bench=startup > /tmp/out.txt 2> /tmp/err.txt
exit 139
[IMPORTANT:flutter/shell/platform/embedder/embedder_surface_gl_impeller.cc(126)] Using the Impeller rendering backend (OpenGLESSDF).
MEMBERS start n=5050 colored=false
MEMBERS a
MEMBERS b
MEMBERS c
MEMBERS d
MEMBERS e
MEMBERS f 5202
```
- next success of same kind (run): none in this transcript

## F15  2026-10-24T07:21:37Z  (+58.4 min)  kind=test
- primary kind: test; duration 10 s; reasons: inferred: compile error in test build
- command: `cd $REPO/stacks/rust-flutter/crates; cat >> bridge/src/api.rs <<'XEOF'
<heredoc body, 51 lines elided>
cd ..; source ../../harness/machine-env.sh; cargo test -p frame2d-bridge 2>&1 | tail -12`
- output:
```
   --> /rustc/58cf8f9c35b355199727627d07ae34a4e2846d67/library\core\src\result.rs:1323:4
help: consider annotating `ModelView` with `#[derive(Debug)]`
    |
 13 | pub struct ModelView {
For more information about this error, try `rustc --explain E0277`.
error: could not compile `frame2d-bridge` (lib test) due to 3 previous errors
warning: build failed, waiting for other jobs to finish...
```
- next success of same kind (test): 2026-10-24T07:21:51Z, 0.1 min after the failure: `cd $REPO/stacks/rust-flutter; sed -i 's|^pub struct ModelView {|#[derive(Debug)]\npub struct ModelView {|; s|^pub struct SolveView {|#[derive(Debug)]\npub struct SolveView {|' crates/bridge/src/api.rs; source ../../harness/machine-env.sh; cargo test -p frame2d-bridge 2>&1 | tail -12`

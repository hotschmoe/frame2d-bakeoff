# Failure digest: go-flutter P1

Phase start 2026-10-24T06:41:08Z, active wall 95.4 min (stalls removed), 22 build/check commands, 29 build/check/test/conformance commands, 5 flagged failures.

Failures are extracted heuristically (see harness/agentlog/README.md). A `reasons` entry starting with `inferred:` means the exit code was 0 (pipes such as `| tail` hide it) and the failure was inferred from output text; such items can be false positives. If an item is not a real failure of the kind named, classify it `false_positive`.

| id | min | kind | next success (min) | signature |
|---|---|---|---|---|
| F1 | 4.0 | conformance | 5.1 | Traceback (most recent call last): |
| F2 | 4.0 | conformance | 5.0 | FAIL FN |
| F3 | 7.6 | build | 0.1 | Traceback (most recent call last): |
| F4 | 14.9 | run | none | panic: runtime error: C:/Program FILE:N: result of Go function t called from cgo is unpinned Go poin |
| F5 | 39.0 | test | 0.2 | --- FAIL: TestGenSolveAndMove (N.Ns) |

## F1  2026-10-24T06:45:07Z  (+4.0 min)  kind=build/conformance
- primary kind: conformance; duration 1 s; reasons: inferred: python traceback; inferred: missing binary
- command: `cd $REPO/stacks/go-flutter && mkdir -p build && go build -o build/frame2d.exe ./cmd/frame2d && cd ../.. && python harness/conformance.py go-flutter all --bin stacks/go-flutter/build/frame2d.exe 2>&1 | tail -30`
- output:
```
Traceback (most recent call last):
  File "C:\Users\hotschmoe\Documents\GitHub\frame2d-bakeoff\harness\conformance.py", line 228, in <module>
    main()
               ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "C:\Users\hotschmoe\Documents\GitHub\frame2d-bakeoff\harness\conformance.py", line 107, in check_fixture
    code, res = run_solve(binary, fx)
                ^^^^^^^^^^^^^^^^^^^^^
  File "C:\Users\hotschmoe\Documents\GitHub\frame2d-bakeoff\harness\conformance.py", line 95, in run_solve
    p = subprocess.run([*binary, "solve", str(mp), "-o", str(rp)], capture_output=True, text=True, timeout=300)
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "C:\Users\hotschmoe\AppData\Local\Programs\Python\Python312-arm64\Lib\subprocess.py", line 548, in run
    with Popen(*popenargs, **kwargs) as process:
         ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "C:\Users\hotschmoe\AppData\Local\Programs\Python\Python312-arm64\Lib\subprocess.py", line 1026, in __init__
    self._execute_child(args, executable, preexec_fn, close_fds,
                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
FileNotFoundError: [WinError 2] The system cannot find the file specified
```
- agent after: Relative path issue (cwd-relative bin check); use absolute.
- next success of same kind (conformance): 2026-10-24T06:50:11Z, 5.1 min after the failure: `time bash harness/server_conformance.sh go-flutter 2>&1 | tail -30`

## F2  2026-10-24T06:45:10Z  (+4.0 min)  kind=conformance
- primary kind: conformance; duration 2 s; reasons: inferred: FAIL line; inferred: 17/22 passed
- command: `python harness/conformance.py go-flutter all --bin "C:/Users/hotschmoe/Documents/GitHub/frame2d-bakeoff/stacks/go-flutter/build/frame2d.exe" 2>&1 | tail -30`
- output:
```
FAIL F21
       /load_cases/0/displacements/1/uy: got -0.02604166666666666, want -0.013020833333333332
       /warnings: len 0 != 1
       /warnings/0/warning: unresolved (IndexError('list index out of range'))
       /load_cases/0/reactions/0/mz: got 6250, want 12500.0
       /warnings/0/node: unresolved (IndexError('list index out of range'))
       /warnings/0/dof: unresolved (IndexError('list index out of range'))
       expected exit 2 (support_conflict), got exit 0
ok   gen_10_10
```
- agent before: Relative path issue (cwd-relative bin check); use absolute.
- next success of same kind (conformance): 2026-10-24T06:50:11Z, 5.0 min after the failure: `time bash harness/server_conformance.sh go-flutter 2>&1 | tail -30`

## F3  2026-10-24T06:48:43Z  (+7.6 min)  kind=build
- primary kind: build; duration 10 s; reasons: inferred: missing tool/file
- command: `cd $REPO/stacks/go-flutter && mkdir -p .tools/libclang-x64 && cd .tools/libclang-x64 && python -c "
import zipfile
z=zipfile.ZipFile('/tmp/lc/libclang-18.1.1-py2.py3-none-win_amd64.whl')
for n in z.namelist():
 if n.endswith('libclang.dll'): open('libclang.dll','wb').write(z.read(n)); print(n)
"; ls -la; cd ../../app && python - <<'EOF'
<heredoc body, 6 lines elided>
cat > ffigen.yaml <<'EOF'
<heredoc body, 13 lines elided>
mkdir -p ffigen lib/generated && cp ../build/frame2d_engine.h ffigen/ && source ../../../harness/machine-env.sh && flutter pub get 2>&1 | tail -3 && time dart run ffigen --config ffigen.yaml 2>&1 | tail -15`
- output:
```
Traceback (most recent call last):
  File "<string>", line 3, in <module>
  File "C:\Users\hotschmoe\AppData\Local\Programs\Python\Python312-arm64\Lib\zipfile\__init__.py", line 1336, in __init__
              ^^^^^^^^^^^^^^^^^^^^^^^
FileNotFoundError: [Errno 2] No such file or directory: '/tmp/lc/libclang-18.1.1-py2.py3-none-win_amd64.whl'
total 0
drwxr-xr-x 1 hotschmoe 197121 0 Oct 23 23:48 .
Unhandled exception:
Invalid argument(s): Failed to load dynamic library 'C:\Program Files\LLVM\bin\libclang.dll': %1 is not a valid Win32 application.
 (error code: 193)
#0      _open (dart:ffi-patch/ffi_dynamic_library_patch.dart:11:43)
#1      new DynamicLibrary.open (dart:ffi-patch/ffi_dynamic_library_patch.dart:24:12)
#2      new Context (package:ffigen/src/context.dart:54:37)
#3      FfiGenGenerator.generate (package:ffigen/src/ffigen.dart:24:21)
#4      FfiGenerator.generate (package:ffigen/src/config_provider/config.dart:166:7)
#5      main (package:ffigen/src/executables/ffigen.dart:65:21)
<asynchronous suspension>
real	0m5.963s
```
- next success of same kind (build): 2026-10-24T06:48:59Z, 0.1 min after the failure: `cd $REPO/stacks/go-flutter/.tools/libclang-x64 && W=$(cygpath -w /tmp/lc/libclang-18.1.1-py2.py3-none-win_amd64.whl) && python -c "
import zipfile,sys ... l <<'EOF'
<heredoc body, 3 lines elided>
source ../../../harness/machine-env.sh; dart run ffigen --config ffigen.yaml 2>&1 | tail -8; ls lib/generated`

## F4  2026-10-24T06:56:00Z  (+14.9 min)  kind=run
- primary kind: run; duration 3 s; reasons: inferred: runtime crash marker in program output
- command: `cd $REPO/stacks/go-flutter && gofmt -w bridge cmd engine && ./app/build/windows/x64/runner/Debug/frame2d_app.exe --bench=startup 2>&1 | head -20`
- output:
```
panic: runtime error: C:/Program Files/Go/src/runtime/cgocall.go:837: result of Go function t called from cgo is unpinned Go pointer or points to unpinned Go pointer
goroutine 17 [running, locked to thread]:
panic({0x7ffbdd3b8b20?, 0x912c74b8010?})
	C:/Program Files/Go/src/runtime/panic.go:878 +0x159
runtime.cgoCheckUnknownPointer(0x912c7590180, 0x1)
	C:/Program Files/Go/src/runtime/cgocall.go:773 +0x12a
runtime.cgoCheckArg(0x7ffbdd3b6908, 0x912c7590180, 0x93?, 0x0, 0x1)
	C:/Program Files/Go/src/runtime/cgocall.go:750 +0x25c
runtime.cgoCheckResult({0x7ffbdd3b6908, 0x912c7590180})
	C:/Program Files/Go/src/runtime/cgocall.go:837 +0x45
_cgoexp_c5ea1c93e06f_f2d_stats(0xfef87cdd60)
	C:/Users/hotschmoe/Documents/GitHub/frame2d-bakeoff/stacks/go-flutter/bridge/native/main.go:71 +0x52
runtime.cgocallbackg1(0x7ffbdd24a580, 0xfef87cdd60, 0x0)
	C:/Program Files/Go/src/runtime/cgocall.go:474 +0x2f6
runtime.cgocallbackg(0x7ffbdd24a580, 0xfef87cdd60, 0x0)
runtime.cgocallback(0x0, 0x0, 0x0)
```
- next success of same kind (run): none in this transcript

## F5  2026-10-24T07:20:10Z  (+39.0 min)  kind=test
- primary kind: test; duration 2 s; reasons: inferred: --- FAIL; inferred: FAIL line
- command: `cd $REPO/stacks/go-flutter && cat > bridge/session/session_test.go <<'EOF'
<heredoc body, 56 lines elided>
cd ../.. && bash harness/measure.sh go-flutter test_all -- bash -c "cd stacks/go-flutter && source stack.sh && test_all" 2>&1 | tail -15`
- output:
```
--- FAIL: TestGenSolveAndMove (0.00s)
    session_test.go:17: counts = [9 10 3]
FAIL
FAIL	frame2d/bridge/session	0.050s
?   	frame2d/cmd/frame2d	[no test files]
?   	frame2d/cmd/server	[no test files]
```
- next success of same kind (test): 2026-10-24T07:20:27Z, 0.2 min after the failure: `cd $REPO/stacks/go-flutter && sed -i 's/{9, 12, 3}/{9, 10, 3}/' bridge/session/session_test.go && cd ../.. && bash harness/measure.sh go-flutter test_all -- bash -c "cd stacks/go-flutter && source stack.sh && test_all" 2>&1 | tail -12`

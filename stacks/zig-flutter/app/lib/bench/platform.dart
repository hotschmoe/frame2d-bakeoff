import 'platform_stub.dart'
    if (dart.library.js_interop) 'platform_web.dart'
    if (dart.library.io) 'platform_native.dart' as p;

/// The requested bench mode (`--bench=<mode>` on desktop, `?bench=<mode>` on web), or null.
String? benchModeFrom(List<String> args) => p.benchModeFrom(args);

/// Optional tuning parameter such as `--size=100` / `?size=100`, for diagnosis runs.
String? benchParam(List<String> args, String name) => p.benchParam(args, name);

/// Prints one `BENCH {...}` line where the harness reads it (stdout, or console.log on web).
void benchEmit(String line) => p.benchEmit(line);

/// Desktop exits the process after a bench; web stays idle.
void benchFinish() => p.benchFinish();

/// Resident memory of the process in MB, when the platform can tell.
double? residentMemoryMb() => p.residentMemoryMb();

/// Platform hooks for the benchmark modes: output channel, clocks, process exit, memory.
library;
export 'bench_platform_io.dart' if (dart.library.js_interop) 'bench_platform_web.dart';

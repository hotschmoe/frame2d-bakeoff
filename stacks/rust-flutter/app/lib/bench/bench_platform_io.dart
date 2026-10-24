/// Desktop: BENCH lines go to stdout; time is measured from process creation.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const String platformName = 'desktop';

void benchPrint(String line) => stdout.writeln(line);

/// Prints nothing more and ends the process (desktop benchmarks exit when done).
Future<void> benchFinish() async {
  await stdout.flush();
  exit(0);
}

final DateTime _dartStart = DateTime.now();
double? _processStartEpochMs;

/// Milliseconds since the OS created this process (Windows), else since the Dart entrypoint ran.
double msSinceStart() {
  _processStartEpochMs ??= _lookupProcessStart();
  return DateTime.now().millisecondsSinceEpoch - _processStartEpochMs!;
}

double _lookupProcessStart() {
  if (Platform.isWindows) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final currentProcess = kernel32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
      final getTimes = kernel32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
          int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>('GetProcessTimes');
      final times = calloc<Uint64>(4);
      try {
        if (getTimes(currentProcess(), times, times + 1, times + 2, times + 3) != 0) {
          // FILETIME: 100 ns ticks since 1601-01-01; Unix epoch is 116444736000000000 ticks later.
          return (times[0] - 116444736000000000) / 10000.0;
        }
      } finally {
        calloc.free(times);
      }
    } catch (_) {
      // fall through to the Dart start time
    }
  }
  return _dartStart.millisecondsSinceEpoch.toDouble();
}

double? rssMb() => ProcessInfo.currentRss / (1024 * 1024);



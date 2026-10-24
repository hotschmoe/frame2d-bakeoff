/// Web: BENCH lines go to console.log; time is measured from navigation start.
library;

import 'dart:js_interop';

const String platformName = 'web';

@JS('console.log')
external void _log(JSString line);

@JS('performance.now')
external double _now();

@JS('performance.memory')
external _Memory? get _memory;

extension type _Memory._(JSObject _) implements JSObject {
  external double get usedJSHeapSize;
}

void benchPrint(String line) => _log(line.toJS);

/// The page stays open after a web benchmark so the harness can read the console.
Future<void> benchFinish() async {}

double msSinceStart() => _now();

double? rssMb() {
  final mem = _memory;
  return mem == null ? null : mem.usedJSHeapSize / (1024 * 1024);
}



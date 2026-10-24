import 'dart:js_interop';
import 'dart:js_interop_unsafe';

String? benchModeFrom(List<String> args) => Uri.base.queryParameters['bench'];

String? benchParam(List<String> args, String name) => Uri.base.queryParameters[name];

void benchEmit(String line) {
  (globalContext['console'] as JSObject).callMethod('log'.toJS, line.toJS);
}

void benchFinish() {}

double? residentMemoryMb() {
  final perf = globalContext['performance'];
  if (perf == null || perf.isUndefinedOrNull) return null;
  final mem = (perf as JSObject)['memory'];
  if (mem == null || mem.isUndefinedOrNull) return null;
  final used = (mem as JSObject)['usedJSHeapSize'];
  if (used == null || used.isUndefinedOrNull) return null;
  return (used as JSNumber).toDartDouble / (1024 * 1024);
}

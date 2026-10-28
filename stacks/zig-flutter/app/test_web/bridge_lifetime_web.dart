// Web regression test for docs/zig-dart-bridge.md 2.5: results held across engine calls must survive WASM
// memory growth (which detaches every JS typed-array view) and a regenerate to a different size.
// Compiled with `dart compile js` and `dart compile wasm` and run under node by run.mjs (stack.sh test_all).
// run.mjs instantiates the engine and passes its exports as globalThis.f2dExports; the verdict goes to
// globalThis.f2dTestResult ("PASS" or the failure).
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:frame2d_app/engine/engine_web.dart';

void _check(bool ok, String what) {
  if (!ok) throw StateError(what);
}

int _bytes(JSObject exports) =>
    (((exports['memory'] as JSObject)['buffer'] as JSObject)['byteLength'].dartify() as num).toInt();

void _intact(List<Float64List> held, List<Float64List> snap, String when) {
  for (var i = 0; i < held.length; i++) {
    _check(held[i].length == snap[i].length, '$when: held list $i length ${held[i].length} != ${snap[i].length}');
    for (var j = 0; j < snap[i].length; j++) {
      if (held[i][j] != snap[i][j]) throw StateError('$when: held list $i differs at $j');
    }
  }
}

void main() {
  final log = <String>[];
  try {
    final exports = globalContext['f2dExports'] as JSObject;
    final e = WebEngine.fromExports(exports);
    log.add(e.backend);

    _check(e.generate(50, 50) == null, 'generate 50x50');
    _check(e.solve((1 << e.caseCount) - 1) == null, 'solve');
    final held = [
      e.displacements(0)!,
      e.endForces(0)!,
      e.maxMoment(0)!,
      e.stationMoments(0)!,
      e.nodeXy,
      e.memberLength,
    ];
    final snap = [for (final l in held) Float64List.fromList(l)];
    _check(held[0].length == 2601 * 3, 'disp length ${held[0].length}');
    final gen0 = e.generation;
    final mem0 = _bytes(exports);

    // Save + results export: grows linear memory (12 MB -> 29 MB in the report's repro).
    final model = e.exportModelJson();
    _check(model.startsWith('{'), 'export model');
    final results = e.exportResultsJson();
    _check(results.length > model.length, 'export results');
    final mem1 = _bytes(exports);
    _check(mem1 > mem0, 'memory did not grow ($mem0 -> $mem1): the test would prove nothing');
    _check(e.generation != gen0, 'generation must change on memory growth');
    _intact(held, snap, 'after memory growth');

    // Fresh results after the growth read through the new buffer.
    final again = e.displacements(0)!;
    _check(again.length == held[0].length && again[again.length - 2] == snap[0][snap[0].length - 2],
        'results re-read after growth');

    // Different sizes: every published buffer freed and reallocated.
    _check(e.generate(3, 2) == null, 'generate 3x2');
    _check(e.solve((1 << e.caseCount) - 1) == null, 'solve 3x2');
    _check(e.displacements(0)!.length == e.nodeCount * 3, 'small disp');
    _check(e.generate(60, 40) == null, 'generate 60x40');
    _check(e.solve((1 << e.caseCount) - 1) == null, 'solve 60x40');
    e.exportResultsJson();
    _intact(held, snap, 'after regenerate');
    log.add('memory ${mem0 >> 20} -> ${_bytes(exports) >> 20} MB');

    globalContext['f2dTestResult'] = 'PASS (${log.join(', ')})'.toJS;
  } catch (err) {
    globalContext['f2dTestResult'] = 'FAIL: $err (${log.join(', ')})'.toJS;
  }
}

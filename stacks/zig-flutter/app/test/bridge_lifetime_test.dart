// Regression tests for the bridge memory-safety bugs of docs/zig-dart-bridge.md 2.5 (native, dart:ffi):
// results held across engine calls must survive an export (scratch buffer regrowth) and a regenerate to a
// different size (every published buffer freed and reallocated). Before the fix the held lists were views
// onto engine memory and read freed memory here.
//
// Loads the debug engine built by `zig build bridge-test-libs` (stack.sh test_all does it first);
// F2D_ENGINE_LIB overrides the path.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame2d_app/engine/engine_native.dart';
import 'package:frame2d_app/engine/frame_engine.dart';
import 'package:frame2d_app/state/app_state.dart';

String _libPath() =>
    Platform.environment['F2D_ENGINE_LIB'] ?? '../zig-out/test-bridge/$engineLibraryName';

FrameEngine _open() {
  final p = _libPath();
  if (!File(p).existsSync()) {
    fail('engine library not found at $p: run stack.sh test_all (it builds zig-out/test-bridge first)');
  }
  return openNativeEngine(p);
}

int _all(FrameEngine e) => (1 << e.caseCount) - 1;

class _Held {
  _Held(this.lists) : snap = [for (final l in lists) Float64List.fromList(l)];
  final List<Float64List> lists;
  final List<Float64List> snap;

  void expectIntact() {
    for (var i = 0; i < lists.length; i++) {
      expect(lists[i].length, snap[i].length, reason: 'held list $i changed length');
      expect(lists[i], orderedEquals(snap[i]), reason: 'held list $i changed content');
    }
  }
}

void main() {
  late FrameEngine e;
  setUpAll(() => e = _open());

  test('held results survive export and regenerating a different size', () {
    expect(e.generate(50, 50), isNull);
    expect(e.solve(_all(e)), isNull);
    final held = _Held([
      e.displacements(0)!,
      e.endForces(0)!,
      e.maxMoment(0)!,
      e.stationMoments(0)!,
      e.nodeXy,
      e.memberLength,
    ]);
    expect(held.lists[0].length, 2601 * 3);
    expect(held.snap[0].any((v) => v != 0), isTrue);
    final gen0 = e.generation;

    // Save: grows (reallocates) the scratch buffer.
    final model = e.exportModelJson();
    expect(model, startsWith('{'));
    final results = e.exportResultsJson();
    expect(results.length, greaterThan(model.length));
    expect(e.generation, isNot(gen0), reason: 'scratch regrowth must bump the generation');
    held.expectIntact();

    // A different size frees and reallocates every case and geometry buffer.
    final gen1 = e.generation;
    expect(e.generate(3, 2), isNull);
    expect(e.solve(_all(e)), isNull);
    expect(e.generation, isNot(gen1));
    final small = e.displacements(0)!;
    expect(small.length, e.nodeCount * 3);
    expect(e.exportModelJson(), startsWith('{'));
    expect(e.generate(60, 40), isNull);
    expect(e.solve(_all(e)), isNull);
    e.exportResultsJson();
    held.expectIntact();
  });

  test('results copy into the list passed back in (no allocation per solve)', () {
    expect(e.generate(10, 10), isNull);
    expect(e.solve(_all(e)), isNull);
    final d = e.displacements(0)!;
    final before = Float64List.fromList(d);
    final xy = e.nodeXy;
    e.setNodeXY(e.nodeCount - 1, xy[xy.length - 2] + 0.5, xy[xy.length - 1]);
    expect(e.solve(1), isNull);
    final d2 = e.displacements(0, into: d)!;
    expect(identical(d2, d), isTrue);
    expect(d2, isNot(orderedEquals(before)));
    // Wrong length: a fresh list instead of writing past the end.
    final wrong = Float64List(3);
    expect(identical(e.displacements(0, into: wrong), wrong), isFalse);
    expect(e.displacements(5), isNull, reason: 'unsolved / missing case');
  });

  test('AppState keeps drawable results across Save and an engine reload', () {
    final s = AppState(e);
    expect(s.generate(50, 50), isNull);
    final held = _Held([s.disp!, s.endForces!, s.maxM!, s.stationM!, s.nodeXy, s.memberLength]);
    final disp = s.disp;
    expect(s.exportJson(), startsWith('{'));
    expect(identical(s.disp, disp), isTrue);
    held.expectIntact();
    // The engine is reloaded behind AppState's back: what it holds stays drawable.
    expect(e.generate(7, 3), isNull);
    expect(e.solve(_all(e)), isNull);
    e.exportResultsJson();
    held.expectIntact();
  });

  test('model errors come back as text', () {
    final err = e.loadJson('{"nodes": [}');
    expect(err, isNotNull);
    expect(err, isNotEmpty);
    expect(e.loadJson(e.exportModelJson()), isNull);
  });
}

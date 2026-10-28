// Native (dart:ffi) bridge lifetime regression tests against the real Zig engine library.
// test_all runs them with F2D_ENGINE_LIB=<build/dev/frame2d_engine.dll>; without it they are skipped.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame2d_app/app_state.dart';
import 'package:frame2d_app/engine/engine_ffi.dart';

void main() {
  final lib = Platform.environment['F2D_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty ? 'F2D_ENGINE_LIB not set (test_all sets it)' : null;
  late FfiEngine e;
  setUpAll(() {
    if (skip == null) e = FfiEngine(lib);
  });

  test('held results survive Save, generate of another size, load, solve and freeing the session', () {
    final s = AppState(e)..setViewSize(800, 600);
    expect(s.generate(50, 50), isTrue);
    expect(s.solved, isTrue);
    final heldRes = s.res, heldGeo = s.geo, heldStats = s.stats;
    final r0 = Float64List.fromList(heldRes), g0 = Float64List.fromList(heldGeo), s0 = Float64List.fromList(heldStats);
    expect(r0.any((v) => v != 0), isTrue);

    final json = s.exportJson(); // Save: reallocates the session's JSON buffer
    expect(json.length, greaterThan(100000));
    expect(s.exportJson(), json); // a second Save frees the first buffer
    expect(s.generate(7, 3), isTrue); // different size; frees the 50x50 session
    expect(s.res.length, isNot(r0.length));
    expect(s.loadJson(json), isTrue);
    s.setCase(1);
    expect(s.generate(100, 100), isTrue);
    s.dispose();

    expect(heldRes.length, r0.length);
    expect(heldGeo.length, g0.length);
    expect(heldRes, orderedEquals(r0));
    expect(heldGeo, orderedEquals(g0));
    expect(heldStats, orderedEquals(s0));
  }, skip: skip);

  test('solve reuses the Dart-owned result list (no per-solve allocation) and copies, not views', () {
    final s = AppState(e)..setViewSize(800, 600);
    expect(s.generate(10, 10), isTrue);
    final res = s.res, stats = s.stats;
    final before = Float64List.fromList(res);
    s.moveNode(s.nodeCount - 1, s.nodeX(s.nodeCount - 1) + 0.5, s.nodeY(s.nodeCount - 1));
    expect(identical(s.res, res), isTrue);
    expect(identical(s.stats, stats), isTrue);
    expect(s.res, isNot(orderedEquals(before)));
    // reloading the exported model reproduces the moved geometry and the same results
    final moved = Float64List.fromList(s.res);
    final h = e.loadJson(s.exportJson());
    expect(h, greaterThan(0));
    expect(e.solve(h, 0), 0);
    final again = e.resultInto(h, Float64List(moved.length));
    for (var i = 0; i < moved.length; i++) {
      expect(again[i], closeTo(moved[i], 1e-9 * (1 + moved[i].abs())));
    }
    e.free(h);
    s.dispose();
  }, skip: skip);

  test('a freed handle stays dead after its slot is reused', () {
    final h1 = e.gen(2, 2);
    e.free(h1);
    final h2 = e.gen(30, 30);
    expect(h2, isNot(h1));
    expect(e.counts(h1), (0, 0, 0));
    expect(e.geometry(h1), isEmpty);
    final dst = Float64List(4)..fillRange(0, 4, 42);
    expect(e.resultInto(h1, dst), orderedEquals([42, 42, 42, 42]));
    expect(e.solve(h1, 0), lessThan(0));
    expect(e.toJson(h1), '');
    e.free(h1); // no-op; must not free h2
    expect(e.solve(h2, 0), 0);
    expect(e.counts(h2).$1, 31 * 31);
    e.free(h2);
  }, skip: skip);

  test('lastError is copied out and survives later calls', () {
    expect(e.loadJson('{not json'), lessThan(0));
    final msg = e.lastError();
    expect(msg, isNotEmpty);
    final copy = String.fromCharCodes(msg.codeUnits);
    final h = e.gen(20, 20);
    expect(e.loadJson('{"nodes":5}'), lessThan(0));
    expect(msg, copy);
    e.free(h);
  }, skip: skip);
}

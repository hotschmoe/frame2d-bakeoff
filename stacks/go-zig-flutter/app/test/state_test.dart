import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frame2d_app/app_state.dart';
import 'package:frame2d_app/engine/engine.dart';

/// A two-node, one-member fake engine: exercises Dart-side state and geometry mapping only.
class FakeEngine implements Engine {
  final geo = Float64List.fromList([1, 0, 0, 7, 2, 5, 0, 0, 1, 0, 1]);
  final res = Float64List(2 * 3 + Layout.resMember);
  int solves = 0;

  @override
  String get mechanism => 'fake';
  @override
  void noop() {}
  @override
  Float64List echo(int n) => Float64List(n);
  @override
  double processAgeMs() => 0;
  @override
  int loadJson(String json) => 1;
  @override
  int gen(int bays, int stories) => 1;
  @override
  void free(int h) {}
  @override
  String lastError() => '';
  @override
  (int, int, int) counts(int h) => (2, 1, 1);
  @override
  Float64List geometry(int h, int length) => geo;
  @override
  Float64List result(int h, int length) => res;
  @override
  Float64List stats(int h) => Float64List(Layout.statCount);
  @override
  List<String> caseIds(int h) => ['D'];
  @override
  void setNode(int h, int index, double x, double y) {}
  @override
  int solve(int h, int caseIndex) {
    solves++;
    res[2 * 3 + 6] = 1000; // max |M| of member 0
    return 0;
  }

  @override
  String toJson(int h) => '{}';
}

void main() {
  test('loads a session, solves and fits the view', () {
    final e = FakeEngine();
    final s = AppState(e)..setViewSize(500, 100);
    expect(s.generate(1, 1), isTrue);
    expect(s.nodeCount, 2);
    expect(s.memberCount, 1);
    expect(e.solves, 1);
    expect(s.memberLength(0), 5);
    expect(s.maxMoment, 1000);
    expect(s.memberId(0), 1);
  });

  test('nearestNode and moveNode keep Dart geometry in sync', () {
    final s = AppState(FakeEngine())..setViewSize(500, 100);
    s.generate(1, 1);
    s.k = 10;
    s.ox = 0;
    s.oy = 50;
    expect(s.nearestNode(50, 50, 5), 1);
    expect(s.nearestNode(25, 5, 5), -1);
    s.moveNode(1, 4, 1);
    expect(s.nodeX(1), 4);
    expect(s.nodeY(1), 1);
  });
}

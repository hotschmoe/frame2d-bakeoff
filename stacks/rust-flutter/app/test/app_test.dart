import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame2d_app/engine/engine.dart';
import 'package:frame2d_app/state/app_state.dart';
import 'package:frame2d_app/ui/frame_app.dart';

/// A one-member cantilever with canned results, so the UI is tested without the native library.
class FakeEngine implements Engine {
  ModelData _model() => ModelData(
        nodeIds: Int32List.fromList([1, 2]),
        nodeXy: Float64List.fromList([0, 0, 5, 0]),
        nodeSupport: Uint8List.fromList([7, 0]),
        memberIds: Int32List.fromList([1]),
        memberNodes: Uint32List.fromList([0, 1]),
        memberLength: Float64List.fromList([5]),
        memberMaterial: Uint32List.fromList([0]),
        memberSection: Uint32List.fromList([0]),
        materialNames: ['steel'],
        sectionNames: ['BM'],
        caseIds: ['D', 'L'],
        nodalLoadIx: Uint32List.fromList([0, 1]),
        nodalLoadF: Float64List.fromList([0, -10000, 0]),
        udlIx: Uint32List(0),
        udlW: Float64List(0),
      );

  SolveData _solve(int c) => SolveData(
        caseIndex: c,
        disp: Float64List.fromList([0, 0, 0, 0, -0.026, -0.0078]),
        endForces: Float64List(6),
        stationsM: Float64List.fromList(List.generate(11, (k) => 50000.0 * (1 - k / 10))),
        memberMaxAbsM: Float64List.fromList([50000]),
        memberMaxAbsV: Float64List.fromList([10000]),
        memberAxial: Float64List.fromList([0]),
        memberLength: Float64List.fromList([5]),
        reactions: Float64List.fromList([0, 0, 10000, 50000]),
        equilibriumResidual: 0,
        assembleMs: 0.1,
        factorMs: 0.1,
        solveMs: 0.1,
        freeDofs: 3,
        profileBefore: 2,
        profileAfter: 2,
      );

  @override
  Future<void> init() async {}
  @override
  Future<ModelData> generate(int bays, int stories) async => _model();
  @override
  Future<ModelData> load(String json) async => _model();
  @override
  Future<String> export() async => '{}';
  @override
  Future<SolveData> solve(int caseIndex) async => _solve(caseIndex);
  @override
  Future<SolveData> moveAndSolve(int nodePos, double x, double y, int caseIndex) async => _solve(caseIndex);
  @override
  void noop() {}
  @override
  Float64List echo(int n) => Float64List(n);
  @override
  String get mechanism => 'fake';
}

void main() {
  test('EngineError parses code and detail from the Rust side', () {
    final e = EngineError.from('unstable|node 3 rz');
    expect(e.code, 'unstable');
    expect(e.detail, 'node 3 rz');
    expect(EngineError.from(Exception('boom')).code, 'engine');
  });

  test('view transform zooms about the focus point', () {
    final v = ViewTransform()
      ..zoom = 10
      ..ox = 100
      ..oy = 300;
    final focus = const Offset(250, 120);
    final before = v.toWorld(focus);
    v.zoomAt(focus, 2);
    final after = v.toWorld(focus);
    expect(v.zoom, 20);
    expect((before - after).distance, lessThan(1e-9));
  });

  test('state adopts a generated model, solves it and reports a node hit', () async {
    final s = AppState(FakeEngine());
    await s.generate(1, 1);
    expect(s.model!.memberCount, 1);
    expect(s.solution!.engineMs, closeTo(0.3, 1e-9));
    s.view
      ..zoom = 10
      ..ox = 0
      ..oy = 100;
    expect(s.hitNode(const Offset(50, 100), 6), 1);
    expect(s.hitNode(const Offset(25, 100), 6), isNull);
  });

  testWidgets('shell shows the toolbar, the case selector and the member table', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(FakeEngine());
    await tester.pumpWidget(FrameApp(state: state));
    await state.generate(1, 1);
    await tester.pump();

    expect(find.text('Solve'), findsOneWidget);
    expect(find.text('D'), findsOneWidget);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('ID'), findsOneWidget);
    expect(find.text('50.00'), findsOneWidget); // max |M| in kN*m

    await tester.tap(find.text('L'));
    await tester.pump();
    expect(state.caseIndex, 1);
  });
}

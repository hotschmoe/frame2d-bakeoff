import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frame2d_app/state/app_state.dart';
import 'package:frame2d_app/engine/frame_engine.dart';

class _NoEngine implements FrameEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test('zoomAt keeps the focal world point fixed', () {
    final s = AppState(_NoEngine());
    s.viewSize = const Size(800, 600);
    s.scale = 10;
    s.offX = 100;
    s.offY = 500;
    const focal = Offset(300, 200);
    final before = s.toWorld(focal);
    s.zoomAt(focal, 2);
    final after = s.toWorld(focal);
    expect(after.dx, closeTo(before.dx, 1e-9));
    expect(after.dy, closeTo(before.dy, 1e-9));
    expect(s.scale, 20);
  });

  test('toWorld flips y', () {
    final s = AppState(_NoEngine());
    s.scale = 10;
    s.offX = 0;
    s.offY = 100;
    expect(s.toWorld(const Offset(50, 40)), const Offset(5, 6));
  });
}

/// Pannable, zoomable model canvas with node dragging and selection.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'scene.dart';

class CanvasView extends StatefulWidget {
  const CanvasView({super.key, required this.state});

  final AppState state;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  final SceneCache _cache = SceneCache();
  int? _dragging;
  double _startZoom = 1;

  AppState get s => widget.state;

  void _onScaleStart(ScaleStartDetails d) {
    _startZoom = s.view.zoom;
    _dragging = d.pointerCount == 1 ? s.hitNode(d.localFocalPoint, 14) : null;
    if (_dragging != null) {
      s.selectedNode = _dragging;
      s.repaint();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final node = _dragging;
    if (node != null) {
      final w = s.view.toWorld(d.localFocalPoint);
      s.dragNode(node, w.dx, w.dy);
      return;
    }
    s.view.ox += d.focalPointDelta.dx;
    s.view.oy += d.focalPointDelta.dy;
    if (d.scale != 1.0) {
      s.view.zoomAt(d.localFocalPoint, _startZoom * d.scale / s.view.zoom);
    }
    s.repaint();
  }

  void _onScaleEnd(ScaleEndDetails d) => _dragging = null;

  void _onTap(TapUpDetails d) {
    final node = s.hitNode(d.localPosition, 12);
    if (node != null) {
      s.selectedNode = node;
      s.selectedMember = null;
      s.repaint();
      return;
    }
    s.selectedNode = null;
    s.selectMember(_hitMember(d.localPosition));
  }

  /// Closest member to the screen point within a few pixels, or null.
  int? _hitMember(Offset p) {
    final m = s.model;
    if (m == null) return null;
    final v = s.view;
    var best = -1;
    var bestD = 7.0 * 7.0;
    for (var k = 0; k < m.memberCount; k++) {
      final i = m.memberNodes[k * 2], j = m.memberNodes[k * 2 + 1];
      final a = v.toScreen(m.nodeXy[i * 2], m.nodeXy[i * 2 + 1]);
      final b = v.toScreen(m.nodeXy[j * 2], m.nodeXy[j * 2 + 1]);
      final ab = b - a;
      final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = len2 == 0 ? 0.0 : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
      final q = a + ab * t;
      final dist = (p - q).distanceSquared;
      if (dist < bestD) {
        bestD = dist;
        best = k;
      }
    }
    return best < 0 ? null : best;
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      s.view.zoomAt(e.localPosition, math.exp(-e.scrollDelta.dy * 0.0015));
      s.repaint();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: Listener(
        onPointerSignal: _onSignal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onTapUp: _onTap,
          child: ColoredBox(
            color: scheme.surfaceContainerLowest,
            child: CustomPaint(
              painter: ScenePainter(s, _cache, scheme),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

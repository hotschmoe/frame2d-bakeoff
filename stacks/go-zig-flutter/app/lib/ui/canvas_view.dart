import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Pannable / zoomable structure canvas with node dragging (drag a node: the model re-solves live).
class CanvasView extends StatefulWidget {
  const CanvasView({super.key, required this.state});
  final AppState state;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  late final _FramePainter _painter = _FramePainter(widget.state);
  bool _dragging = false;
  double _lastScale = 1;

  AppState get s => widget.state;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final first = s.viewW != c.maxWidth || s.viewH != c.maxHeight;
      s.setViewSize(c.maxWidth, c.maxHeight);
      if (first && s.nodeCount > 0 && !_userMoved) s.fitView();
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            _userMoved = true;
            s.zoomAt(math.exp(-e.scrollDelta.dy / 300), e.localPosition.dx, e.localPosition.dy);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) {
            _lastScale = 1;
            _dragging = false;
            if (d.pointerCount == 1) {
              final n = s.nearestNode(d.localFocalPoint.dx, d.localFocalPoint.dy, 14);
              if (n >= 0) {
                _dragging = true;
                s.selectedNode = n;
                s.touch();
              }
            }
          },
          onScaleUpdate: (d) {
            if (_dragging) {
              if (d.pointerCount == 1) {
                s.moveNode(s.selectedNode, s.worldX(d.localFocalPoint.dx), s.worldY(d.localFocalPoint.dy));
              }
              return;
            }
            _userMoved = true;
            if (d.scale != _lastScale && d.pointerCount > 1) {
              s.zoomAt(d.scale / _lastScale, d.localFocalPoint.dx, d.localFocalPoint.dy);
              _lastScale = d.scale;
            }
            s.panBy(d.focalPointDelta.dx, d.focalPointDelta.dy);
          },
          onScaleEnd: (_) => _dragging = false,
          child: ClipRect(
            child: CustomPaint(painter: _painter, size: Size.infinite, isComplex: true, willChange: true),
          ),
        ),
      );
    });
  }

  bool _userMoved = false;
}

const _ramp = <Color>[
  Color(0xFF3B6FD8), Color(0xFF2F8FD0), Color(0xFF2AA6B8), Color(0xFF2DAA86), Color(0xFF4DAF4A), Color(0xFF8DB63C),
  Color(0xFFC4BA2E), Color(0xFFE6A82A), Color(0xFFEE8A2A), Color(0xFFEA6A2A), Color(0xFFE04A2C), Color(0xFFCC2430),
];

class _FramePainter extends CustomPainter {
  _FramePainter(this.s) : super(repaint: s);
  final AppState s;

  // scratch buffers, grown on demand
  Float32List _bin(int i, int need) {
    if (_bins[i].length < need) _bins[i] = Float32List(need);
    return _bins[i];
  }

  final List<Float32List> _bins = List.generate(_ramp.length, (_) => Float32List(0));
  final List<int> _binN = List.filled(_ramp.length, 0);
  Float32List _line = Float32List(0);

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    _paint(canvas, size);
    s.paintMs = sw.elapsedMicroseconds / 1000.0;
  }

  void _paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFAFAFA));
    if (s.nodeCount == 0) return;
    final w = size.width, h = size.height;
    final k = s.k, ox = s.ox, oy = s.oy;
    final nm = s.memberCount;
    final big = nm > 3000;

    // ---- members, binned by max |M| ----
    for (var i = 0; i < _binN.length; i++) {
      _binN[i] = 0;
    }
    final useColor = s.solved && s.colorByMoment && s.maxMoment > 0;
    for (var m = 0; m < nm; m++) {
      final a = s.memberI(m), b = s.memberJ(m);
      final ax = ox + s.nodeX(a) * k, ay = oy - s.nodeY(a) * k;
      final bx = ox + s.nodeX(b) * k, by = oy - s.nodeY(b) * k;
      if ((ax < 0 && bx < 0) || (ax > w && bx > w) || (ay < 0 && by < 0) || (ay > h && by > h)) continue;
      var bin = 0;
      if (useColor) {
        bin = (s.memberMaxM(m) / s.maxMoment * (_ramp.length - 1)).round().clamp(0, _ramp.length - 1);
      }
      final buf = _bin(bin, (_binN[bin] + 1) * 4);
      final o = _binN[bin] * 4;
      buf[o] = ax;
      buf[o + 1] = ay;
      buf[o + 2] = bx;
      buf[o + 3] = by;
      _binN[bin]++;
    }
    final mp = Paint()
      ..strokeWidth = big ? 1.0 : 2.0
      ..strokeCap = StrokeCap.butt
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < _ramp.length; i++) {
      if (_binN[i] == 0) continue;
      mp.color = useColor ? _ramp[i] : const Color(0xFF607D8B);
      _segments(canvas, _bins[i], _binN[i] * 4, mp);
    }

    // ---- moment diagram ----
    if (s.solved && s.showMoment && s.momentScale > 0) _paintMoments(canvas, w, h);

    // ---- deflected shape ----
    if (s.solved && s.showDeflected && s.deflectionScale > 0) _paintDeflected(canvas, w, h);

    // ---- supports and nodes ----
    final sup = <double>[];
    final pts = <double>[];
    final showNodes = s.nodeCount <= 3000 || k > 14;
    for (var i = 0; i < s.nodeCount; i++) {
      final x = ox + s.nodeX(i) * k, y = oy - s.nodeY(i) * k;
      if (x < -8 || x > w + 8 || y < -8 || y > h + 8) continue;
      if (s.nodeMask(i) != 0) {
        sup.addAll([x, y + 4]);
      } else if (showNodes) {
        pts.addAll([x, y]);
      }
    }
    if (sup.isNotEmpty) {
      canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(sup),
          Paint()
            ..color = const Color(0xFF2E7D32)
            ..strokeWidth = big ? 4 : 9
            ..strokeCap = StrokeCap.square);
    }
    if (pts.isNotEmpty) {
      canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.fromList(pts),
          Paint()
            ..color = const Color(0xFF263238)
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round);
    }
    if (s.selectedNode >= 0 && s.selectedNode < s.nodeCount) {
      final x = ox + s.nodeX(s.selectedNode) * k, y = oy - s.nodeY(s.selectedNode) * k;
      canvas.drawCircle(
          Offset(x, y),
          7,
          Paint()
            ..color = const Color(0xFFD81B60)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    if (s.selectedMember >= 0 && s.selectedMember < nm) {
      final a = s.memberI(s.selectedMember), b = s.memberJ(s.selectedMember);
      canvas.drawLine(
          Offset(ox + s.nodeX(a) * k, oy - s.nodeY(a) * k),
          Offset(ox + s.nodeX(b) * k, oy - s.nodeY(b) * k),
          Paint()
            ..color = const Color(0xFFD81B60)
            ..strokeWidth = 4);
    }
  }

  /// Draws [count] floats of (x0,y0,x1,y1) segments as one stroked path (cheaper than drawRawPoints in Impeller).
  void _segments(Canvas canvas, Float32List pts, int count, Paint paint) {
    final path = Path();
    for (var i = 0; i < count; i += 4) {
      path
        ..moveTo(pts[i], pts[i + 1])
        ..lineTo(pts[i + 2], pts[i + 3]);
    }
    canvas.drawPath(path, paint);
  }

  void _paintMoments(Canvas canvas, double w, double h) {
    final k = s.k, ox = s.ox, oy = s.oy, sc = s.momentScale;
    final nm = s.memberCount;
    // 10 segments per member at high zoom, 2 when members are tiny on screen
    final step = k * s.avgLength < 30 ? 5 : 1;
    final segs = 10 ~/ step;
    final need = nm * segs * 4;
    if (_line.length < need) _line = Float32List(need);
    var n = 0;
    for (var m = 0; m < nm; m++) {
      final a = s.memberI(m), b = s.memberJ(m);
      final ax = s.nodeX(a), ay = s.nodeY(a), bx = s.nodeX(b), by = s.nodeY(b);
      final sax = ox + ax * k, say = oy - ay * k, sbx = ox + bx * k, sby = oy - by * k;
      if ((sax < -50 && sbx < -50) || (sax > w + 50 && sbx > w + 50) || (say < -50 && sby < -50) || (say > h + 50 && sby > h + 50)) {
        continue;
      }
      final dx = bx - ax, dy = by - ay;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;
      final nx = -dy / len, ny = dx / len; // local y in world axes
      double px = 0, py = 0;
      for (var st = 0; st <= 10; st += step) {
        final t = st / 10;
        final off = -s.stationM(m, st) * sc; // plotted on the tension side
        final x = ax + dx * t + nx * off, y = ay + dy * t + ny * off;
        final sx = ox + x * k, sy = oy - y * k;
        if (st > 0) {
          _line[n++] = px;
          _line[n++] = py;
          _line[n++] = sx;
          _line[n++] = sy;
        }
        px = sx;
        py = sy;
      }
    }
    _segments(
        canvas,
        _line,
        n,
        Paint()
          ..color = const Color(0xCC1565C0)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke);
  }

  void _paintDeflected(Canvas canvas, double w, double h) {
    final k = s.k, ox = s.ox, oy = s.oy, sc = s.deflectionScale;
    final nm = s.memberCount;
    const segs = 6;
    final detailed = nm <= 6000;
    final per = detailed ? segs : 1;
    final need = nm * per * 4;
    if (_line.length < need) _line = Float32List(need);
    var n = 0;
    for (var m = 0; m < nm; m++) {
      final a = s.memberI(m), b = s.memberJ(m);
      final ax = s.nodeX(a), ay = s.nodeY(a), bx = s.nodeX(b), by = s.nodeY(b);
      final sax = ox + ax * k, say = oy - ay * k, sbx = ox + bx * k, sby = oy - by * k;
      if ((sax < -50 && sbx < -50) || (sax > w + 50 && sbx > w + 50) || (say < -50 && sby < -50) || (say > h + 50 && sby > h + 50)) {
        continue;
      }
      final dx = bx - ax, dy = by - ay;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;
      final c = dx / len, sn = dy / len;
      // end displacements in local axes
      final u1 = s.disp(a, 0), v1 = s.disp(a, 1), r1 = s.disp(a, 2);
      final u2 = s.disp(b, 0), v2 = s.disp(b, 1), r2 = s.disp(b, 2);
      final lu1 = c * u1 + sn * v1, lv1 = -sn * u1 + c * v1;
      final lu2 = c * u2 + sn * v2, lv2 = -sn * u2 + c * v2;
      double px = 0, py = 0;
      for (var i = 0; i <= per; i++) {
        final t = i / per;
        double lu = lu1 + (lu2 - lu1) * t, lv;
        if (detailed) {
          final t2 = t * t, t3 = t2 * t;
          lv = (1 - 3 * t2 + 2 * t3) * lv1 + (t - 2 * t2 + t3) * len * r1 + (3 * t2 - 2 * t3) * lv2 + (-t2 + t3) * len * r2;
        } else {
          lv = lv1 + (lv2 - lv1) * t;
        }
        lu *= sc;
        lv *= sc;
        final lx = len * t + lu, ly = lv;
        final x = ax + c * lx - sn * ly, y = ay + sn * lx + c * ly;
        final sx = ox + x * k, sy = oy - y * k;
        if (i > 0) {
          _line[n++] = px;
          _line[n++] = py;
          _line[n++] = sx;
          _line[n++] = sy;
        }
        px = sx;
        py = sy;
      }
    }
    _segments(
        canvas,
        _line,
        n,
        Paint()
          ..color = const Color(0xFFEF6C00)
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _FramePainter old) => true;
}

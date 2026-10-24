import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Pannable, zoomable structure canvas. Drag a node to move it and re-solve continuously.
class CanvasView extends StatefulWidget {
  const CanvasView({super.key, required this.state});

  final AppState state;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  int _dragNode = -1;
  double _startScale = 1;
  double _startOffX = 0;
  double _startOffY = 0;
  Offset _startFocal = Offset.zero;

  AppState get s => widget.state;

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = s.scale;
    _startOffX = s.offX;
    _startOffY = s.offY;
    _startFocal = d.localFocalPoint;
    _dragNode = -1;
    if (d.pointerCount == 1) {
      final hit = s.hitNode(d.localFocalPoint, 16);
      if (hit >= 0) {
        _dragNode = hit;
        s.setDragging(true);
        s.select(hit);
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_dragNode >= 0) {
      final w = s.toWorld(d.localFocalPoint);
      s.moveNode(_dragNode, w.dx, w.dy);
      return;
    }
    final ns = (_startScale * d.scale).clamp(0.02, 5000.0);
    final f = ns / _startScale;
    s.scale = ns;
    s.offX = d.localFocalPoint.dx - (_startFocal.dx - _startOffX) * f;
    s.offY = d.localFocalPoint.dy - (_startFocal.dy - _startOffY) * f;
    s.panBy(0, 0);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_dragNode >= 0) s.setDragging(false);
    _dragNode = -1;
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      s.zoomAt(e.localPosition, math.exp(-e.scrollDelta.dy / 400));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      s.setViewSize(Size(c.maxWidth, c.maxHeight));
      return ClipRect(
        child: Listener(
          onPointerSignal: _onSignal,
          onPointerPanZoomUpdate: (e) {
            if (e.scale != 1) s.zoomAt(e.localPosition, 1 + (e.scale - 1) * 0.05);
            s.panBy(e.panDelta.dx, e.panDelta.dy);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: FramePainter(s, Theme.of(context).brightness == Brightness.dark),
                size: Size.infinite,
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// Draws the model with a handful of batched drawRawPoints calls, so a 200x200 frame (80,200 members) is
/// a few draw calls rather than tens of thousands.
class FramePainter extends CustomPainter {
  FramePainter(this.s, this.dark) : super(repaint: s);

  final AppState s;
  final bool dark;

  static const _binCount = 12;
  static final List<Color> _ramp = List.generate(_binCount, (i) => _rampColor(i / (_binCount - 1)));

  static Color _rampColor(double t) {
    // blue -> cyan -> green -> yellow -> red
    const stops = [Color(0xFF2B59C3), Color(0xFF16A6B6), Color(0xFF3FB950), Color(0xFFE3B341), Color(0xFFD93025)];
    final x = t * (stops.length - 1);
    final i = x.floor().clamp(0, stops.length - 2);
    return Color.lerp(stops[i], stops[i + 1], x - i)!;
  }

  // ---- caches keyed on AppState.stamp ----
  static Float32List _scratch = Float32List(0);

  // Members are drawn as quads in one ui.Vertices (a single draw call, no stroke tessellation). The quad
  // half-width is fixed in world units per zoom bucket, so a zoom sweep only rebuilds a few times.
  static final Map<String, ui.Vertices> _vertexCache = {};
  static int _vertexStamp = -1;

  ui.Vertices _vertices(String key, Float32List? endpoints, int Function(int member) colorOf, double halfWidth) {
    if (_vertexStamp != s.stamp) {
      for (final v in _vertexCache.values) {
        v.dispose();
      }
      _vertexCache.clear();
      _vertexStamp = s.stamp;
    }
    return _vertexCache.putIfAbsent(key, () {
      final lines = endpoints!;
      final n = lines.length >> 2;
      final pos = Float32List(n * 12);
      final col = Int32List(n * 6);
      for (var k = 0; k < n; k++) {
        final ax = lines[k * 4], ay = lines[k * 4 + 1], bx = lines[k * 4 + 2], by = lines[k * 4 + 3];
        final l = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        final nx = l > 0 ? -(by - ay) / l * halfWidth : 0.0;
        final ny = l > 0 ? (bx - ax) / l * halfWidth : 0.0;
        final o = k * 12;
        pos[o] = ax + nx;
        pos[o + 1] = ay + ny;
        pos[o + 2] = ax - nx;
        pos[o + 3] = ay - ny;
        pos[o + 4] = bx + nx;
        pos[o + 5] = by + ny;
        pos[o + 6] = ax - nx;
        pos[o + 7] = ay - ny;
        pos[o + 8] = bx - nx;
        pos[o + 9] = by - ny;
        pos[o + 10] = bx + nx;
        pos[o + 11] = by + ny;
        final c = colorOf(k);
        for (var q = 0; q < 6; q++) {
          col[k * 6 + q] = c;
        }
      }
      return ui.Vertices.raw(ui.VertexMode.triangles, pos, colors: col);
    });
  }

  Float32List _endpoints(bool deflected) {
    final ends = s.memberEnds, xy = s.nodeXy;
    final d = deflected ? s.disp : null;
    final k = deflected ? s.deflScale : 0.0;
    final n = ends.length >> 1;
    final out = Float32List(n * 4);
    for (var m = 0; m < n; m++) {
      final i = ends[m * 2], j = ends[m * 2 + 1];
      out[m * 4] = xy[i * 2] + (d == null ? 0 : d[i * 3] * k);
      out[m * 4 + 1] = xy[i * 2 + 1] + (d == null ? 0 : d[i * 3 + 1] * k);
      out[m * 4 + 2] = xy[j * 2] + (d == null ? 0 : d[j * 3] * k);
      out[m * 4 + 3] = xy[j * 2 + 1] + (d == null ? 0 : d[j * 3 + 1] * k);
    }
    return out;
  }

  int _momentColor(int k) {
    final m = s.maxM;
    final top = s.maxMAll > 0 ? s.maxMAll : 1.0;
    final t = m == null ? 0.0 : math.sqrt(m[k] / top);
    return _ramp[(t * (_binCount - 1)).round().clamp(0, _binCount - 1)].toARGB32();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = dark ? const Color(0xFF14181D) : const Color(0xFFF7F8FA));
    if (!s.hasModel || s.memberCount == 0) return;
    final scale = s.scale;
    final px = 1 / scale;

    final bucket = (math.log(scale) / math.log(1.5)).round();
    final hw = 1.0 / math.pow(1.5, bucket);
    final hasResults = s.disp != null;
    final ghostColor = (dark ? const Color(0x80AAB4C0) : const Color(0x80606873)).toARGB32();
    final fill = Paint();

    canvas.save();
    canvas.translate(s.offX, s.offY);
    canvas.scale(scale, -scale);

    if (hasResults && s.showDeflected) {
      canvas.drawVertices(
          _vertices('ghost$bucket', _endpoints(false), (_) => ghostColor, hw * 0.5), BlendMode.srcOver, fill);
      final key = 'defl$bucket/${s.colorByMoment}/${s.deflScale}';
      canvas.drawVertices(
          _vertices(key, _endpoints(true), s.colorByMoment ? _momentColor : (_) => 0xFFD93025, hw),
          BlendMode.srcOver,
          fill);
    } else if (hasResults && s.colorByMoment) {
      canvas.drawVertices(
          _vertices('plainM$bucket', _endpoints(false), _momentColor, hw), BlendMode.srcOver, fill);
    } else {
      canvas.drawVertices(
          _vertices('plain$bucket', _endpoints(false), (_) => ghostColor, hw), BlendMode.srcOver, fill);
    }

    if (hasResults && s.showMoment) _paintMoments(canvas, size, px);

    _paintNodes(canvas, size, px);
    canvas.restore();
  }

  /// Moment diagrams on the tension side, only for members long enough on screen to read.
  void _paintMoments(Canvas canvas, Size size, double px) {
    final st = s.stationM;
    final top = s.maxMAll;
    if (st == null || top <= 0) return;
    final scale = s.scale;
    final minLen = 26.0;
    final ends = s.memberEnds, xy = s.nodeXy, len = s.memberLength;
    final worldK = 1.2 / top; // world metres drawn for the largest moment
    // Visible world rectangle.
    final x0 = -s.offX / scale, x1 = (size.width - s.offX) / scale;
    final y1 = s.offY / scale, y0 = (s.offY - size.height) / scale;
    const segsPerMember = 12;
    const maxMembers = 1500;
    if (_scratch.length < maxMembers * segsPerMember * 4) _scratch = Float32List(maxMembers * segsPerMember * 4);
    var o = 0;
    var count = 0;
    final n = ends.length >> 1;
    for (var k = 0; k < n && count < maxMembers; k++) {
      if (len[k] * scale < minLen) continue;
      final i = ends[k * 2] * 2, j = ends[k * 2 + 1] * 2;
      final ax = xy[i], ay = xy[i + 1], bx = xy[j], by = xy[j + 1];
      if (math.max(ax, bx) < x0 || math.min(ax, bx) > x1 || math.max(ay, by) < y0 || math.min(ay, by) > y1) continue;
      final l = len[k];
      final nx = -(by - ay) / l, ny = (bx - ax) / l;
      double px0 = 0, py0 = 0;
      for (var q = 0; q < 11; q++) {
        final t = q / 10.0;
        final m = -st[k * 11 + q] * worldK;
        final qx = ax + (bx - ax) * t + nx * m;
        final qy = ay + (by - ay) * t + ny * m;
        if (q == 0) {
          _put(o, ax, ay, qx, qy);
          o += 4;
        } else {
          _put(o, px0, py0, qx, qy);
          o += 4;
        }
        px0 = qx;
        py0 = qy;
      }
      _put(o, px0, py0, bx, by);
      o += 4;
      count++;
    }
    if (o == 0) return;
    canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.sublistView(_scratch, 0, o),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4 * px
          ..color = const Color(0xFF8E44AD));
  }

  void _put(int o, double a, double b, double c, double d) {
    _scratch[o] = a;
    _scratch[o + 1] = b;
    _scratch[o + 2] = c;
    _scratch[o + 3] = d;
  }

  void _paintNodes(Canvas canvas, Size size, double px) {
    final scale = s.scale;
    final xy = s.nodeXy;
    final nn = xy.length >> 1;
    // Node markers once nodes are far enough apart to be useful.
    if (scale * 3.0 > 6 || nn < 3000) {
      final x0 = -s.offX / scale, x1 = (size.width - s.offX) / scale;
      final y1 = s.offY / scale, y0 = (s.offY - size.height) / scale;
      final pts = Float32List(nn * 2);
      var cnt = 0;
      for (var k = 0; k < nn; k++) {
        final x = xy[k * 2], y = xy[k * 2 + 1];
        if (x < x0 || x > x1 || y < y0 || y > y1) continue;
        pts[cnt++] = x;
        pts[cnt++] = y;
      }
      canvas.drawRawPoints(
          ui.PointMode.points,
          Float32List.sublistView(pts, 0, cnt),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = (scale > 4 ? 5.0 : 3.0) * px
            ..color = dark ? const Color(0xFFDDE3EA) : const Color(0xFF2F3640));
    }
    // Supports.
    final r = s.restraint;
    final tri = Path();
    final box = Path();
    final size0 = 7.0 * px;
    for (var k = 0; k < r.length; k++) {
      if (r[k] == 0) continue;
      final x = xy[k * 2], y = xy[k * 2 + 1];
      if (r[k] == 7) {
        box.addRect(Rect.fromLTWH(x - size0, y - size0 * 1.4, size0 * 2, size0 * 0.9));
      } else {
        tri.moveTo(x, y);
        tri.lineTo(x - size0, y - size0 * 1.6);
        tri.lineTo(x + size0, y - size0 * 1.6);
        tri.close();
      }
    }
    final fill = Paint()..color = const Color(0xFF6B7380);
    canvas.drawPath(box, fill);
    canvas.drawPath(tri, fill);
    final sel = s.selectedNode;
    if (sel != null && sel >= 0 && sel < nn) {
      canvas.drawCircle(
          Offset(xy[sel * 2], xy[sel * 2 + 1]),
          8 * px,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * px
            ..color = const Color(0xFFFF6D00));
    }
  }

  @override
  bool shouldRepaint(FramePainter old) => old.dark != dark || old.s != s;
}

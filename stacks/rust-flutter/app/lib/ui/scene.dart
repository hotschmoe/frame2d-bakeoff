/// Drawing of the model: cached world-space pictures for members, deflection and moment diagram, plus
/// screen-space overlays (supports, nodes, loads, selection).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../state/app_state.dart';

const int _buckets = 14;
final Uint32List _bucketArgb = Uint32List.fromList([for (var b = 0; b < _buckets; b++) bucketColor(b).toARGB32()]);

/// Colour for bucket `b` of `_buckets`: blue (low |M|) through green and yellow to red (high).
Color bucketColor(int b) {
  final t = b / (_buckets - 1);
  return HSVColor.fromAHSV(1, 230 - 230 * t, 0.75, 0.85).toColor();
}

const Color _memberColor = Color(0xFF546E7A);
const Color _deflectedColor = Color(0xFFD81B60);
const Color _momentColor = Color(0xFF00897B);

/// Pictures are recorded in world coordinates (Y up) and replayed under the view transform, so panning and
/// zooming never rebuild them. A rebuild happens when the geometry, results or styling change.
class SceneCache {
  ui.Picture? _members;
  Object? _membersKey;
  ui.Picture? _deflected;
  Object? _deflectedKey;
  ui.Picture? _moment;
  Object? _momentKey;
  Object? _supportKey;
  List<int> _supported = const [];

  ui.Picture members(AppState s, double lineWidthWorld, int zoomBucket) {
    final key = (s.model, s.geometryVersion, s.solutionVersion, s.colorByMoment, zoomBucket);
    if (_membersKey != key) {
      _members = _buildMembers(s, lineWidthWorld);
      _membersKey = key;
    }
    return _members!;
  }

  ui.Picture deflected(AppState s, double lineWidthWorld, int zoomBucket) {
    final key = (s.model, s.geometryVersion, s.solutionVersion, s.deflectionScale, zoomBucket);
    if (_deflectedKey != key) {
      _deflected = _buildDeflected(s, lineWidthWorld);
      _deflectedKey = key;
    }
    return _deflected!;
  }

  ui.Picture moment(AppState s) {
    final key = (s.model, s.geometryVersion, s.solutionVersion);
    if (_momentKey != key) {
      _moment = _buildMoment(s);
      _momentKey = key;
    }
    return _moment!;
  }

  /// Positions of nodes that have any restraint.
  List<int> supportedNodes(ModelData m) {
    if (_supportKey != m) {
      _supported = [for (var i = 0; i < m.nodeCount; i++) if (m.nodeSupport[i] != 0) i];
      _supportKey = m;
    }
    return _supported;
  }

  static int bucketOf(double value, double max) {
    if (max <= 0) return 0;
    return math.min(_buckets - 1, (value / max * _buckets).floor());
  }

  ui.Picture _buildMembers(AppState s, double width) {
    final m = s.model!;
    final n = m.memberCount;
    final sol = s.solution;
    final colored = s.colorByMoment && sol != null;
    var maxM = 0.0;
    if (colored) {
      for (final v in sol.memberMaxAbsM) {
        maxM = math.max(maxM, v);
      }
    }
    final segs = Float32List(n * 4);
    final colors = Uint32List(n);
    final xy = m.nodeXy;
    for (var k = 0; k < n; k++) {
      final i = m.memberNodes[k * 2], j = m.memberNodes[k * 2 + 1];
      segs[k * 4] = xy[i * 2];
      segs[k * 4 + 1] = xy[i * 2 + 1];
      segs[k * 4 + 2] = xy[j * 2];
      segs[k * 4 + 3] = xy[j * 2 + 1];
      colors[k] = colored ? _bucketArgb[bucketOf(sol.memberMaxAbsM[k], maxM)] : _memberColor.toARGB32();
    }
    return _segmentPicture(segs, colors, width);
  }

  /// Line segments (x1, y1, x2, y2 each) as thin quads of `width` world units, one GPU draw per colour and
  /// chunk of 10,000 quads (indexed triangles, 16-bit indices).
  ui.Picture _segmentPicture(Float32List segs, Uint32List colors, double width) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final count = colors.length;
    final hw = width / 2;
    const chunk = 10000;
    final byColor = <int, List<int>>{};
    for (var k = 0; k < count; k++) {
      (byColor[colors[k]] ??= <int>[]).add(k);
    }
    for (final entry in byColor.entries) {
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = Color(entry.key)
        ..isAntiAlias = true;
      final ids = entry.value;
      for (var start = 0; start < ids.length; start += chunk) {
        final end = math.min(ids.length, start + chunk);
        final quads = end - start;
        final pos = Float32List(quads * 8);
        final idx = Uint16List(quads * 6);
        var o = 0, ii = 0;
        for (var q = 0; q < quads; q++) {
          final k = ids[start + q];
          final x1 = segs[k * 4], y1 = segs[k * 4 + 1], x2 = segs[k * 4 + 2], y2 = segs[k * 4 + 3];
          final dx = x2 - x1, dy = y2 - y1;
          final len = math.sqrt(dx * dx + dy * dy);
          final nx = len > 0 ? -dy / len * hw : 0.0, ny = len > 0 ? dx / len * hw : 0.0;
          pos[o++] = x1 + nx;
          pos[o++] = y1 + ny;
          pos[o++] = x1 - nx;
          pos[o++] = y1 - ny;
          pos[o++] = x2 - nx;
          pos[o++] = y2 - ny;
          pos[o++] = x2 + nx;
          pos[o++] = y2 + ny;
          final v = q * 4;
          idx[ii++] = v;
          idx[ii++] = v + 1;
          idx[ii++] = v + 2;
          idx[ii++] = v;
          idx[ii++] = v + 2;
          idx[ii++] = v + 3;
        }
        final vertices = ui.Vertices.raw(ui.VertexMode.triangles, pos, indices: idx);
        canvas.drawVertices(vertices, BlendMode.srcOver, paint);
      }
    }
    return recorder.endRecording();
  }

  ui.Picture _empty() {
    final recorder = ui.PictureRecorder();
    Canvas(recorder);
    return recorder.endRecording();
  }

  ui.Picture _buildDeflected(AppState s, double width) {
    final m = s.model!;
    final sol = s.solution;
    if (sol == null) return _empty();
    final scale = s.deflectionScale;
    final n = m.memberCount;
    final smooth = n <= 3000;
    const segs = 8;
    final per = smooth ? segs : 1;
    final pts = Float32List(n * per * 4);
    final xy = m.nodeXy, d = sol.disp;
    var o = 0;
    for (var k = 0; k < n; k++) {
      final i = m.memberNodes[k * 2], j = m.memberNodes[k * 2 + 1];
      final xi = xy[i * 2], yi = xy[i * 2 + 1], xj = xy[j * 2], yj = xy[j * 2 + 1];
      final len = m.memberLength[k];
      final c = len > 0 ? (xj - xi) / len : 1.0, sn = len > 0 ? (yj - yi) / len : 0.0;
      final uix = d[i * 3], uiy = d[i * 3 + 1], ri = d[i * 3 + 2];
      final ujx = d[j * 3], ujy = d[j * 3 + 1], rj = d[j * 3 + 2];
      double px = 0, py = 0;
      for (var q = 0; q <= per; q++) {
        final xi_ = q / per;
        // Axial: linear. Transverse: cubic Hermite from end deflection and rotation.
        final ul = (c * uix + sn * uiy) * (1 - xi_) + (c * ujx + sn * ujy) * xi_;
        final v1 = -sn * uix + c * uiy, v2 = -sn * ujx + c * ujy;
        final n1 = 1 - 3 * xi_ * xi_ + 2 * xi_ * xi_ * xi_;
        final n2 = xi_ - 2 * xi_ * xi_ + xi_ * xi_ * xi_;
        final n3 = 3 * xi_ * xi_ - 2 * xi_ * xi_ * xi_;
        final n4 = -xi_ * xi_ + xi_ * xi_ * xi_;
        final vl = smooth ? v1 * n1 + ri * len * n2 + v2 * n3 + rj * len * n4 : v1 * (1 - xi_) + v2 * xi_;
        final gx = xi + (xj - xi) * xi_ + scale * (c * ul - sn * vl);
        final gy = yi + (yj - yi) * xi_ + scale * (sn * ul + c * vl);
        if (q > 0) {
          pts[o++] = px;
          pts[o++] = py;
          pts[o++] = gx;
          pts[o++] = gy;
        }
        px = gx;
        py = gy;
      }
    }
    final colors = Uint32List(n * per)..fillRange(0, n * per, _deflectedColor.toARGB32());
    return _segmentPicture(pts, colors, width);
  }

  /// The moment diagram as one filled triangle mesh per chunk: a single GPU draw instead of tens of
  /// thousands of stroked segments (stroke tessellation was the frame-time bottleneck).
  ui.Picture _buildMoment(AppState s) {
    final m = s.model!;
    final sol = s.solution;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (sol == null) return recorder.endRecording();
    const st = 11;
    const perMember = (st - 1) * 6 * 2; // 10 quads, 2 triangles each, 3 vertices of 2 floats
    const chunkMembers = 4000;
    final scale = s.momentScale;
    final xy = m.nodeXy;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = _momentColor.withValues(alpha: 0.5)
      ..isAntiAlias = true;
    final n = m.memberCount;
    for (var start = 0; start < n; start += chunkMembers) {
      final end = math.min(n, start + chunkMembers);
      final pos = Float32List((end - start) * perMember);
      var o = 0;
      for (var k = start; k < end; k++) {
        final i = m.memberNodes[k * 2], j = m.memberNodes[k * 2 + 1];
        final xi = xy[i * 2], yi = xy[i * 2 + 1], xj = xy[j * 2], yj = xy[j * 2 + 1];
        final len = m.memberLength[k];
        if (len <= 0) {
          o += perMember;
          continue;
        }
        final c = (xj - xi) / len, sn = (yj - yi) / len;
        // Sagging moment is drawn on the tension side, opposite to local +y (-sn, c).
        final nx = sn, ny = -c;
        double bx0 = xi, by0 = yi;
        double cx0 = xi + nx * sol.stationsM[k * st] * scale, cy0 = yi + ny * sol.stationsM[k * st] * scale;
        for (var q = 1; q < st; q++) {
          final t = q / (st - 1);
          final bx1 = xi + (xj - xi) * t, by1 = yi + (yj - yi) * t;
          final mv = sol.stationsM[k * st + q] * scale;
          final cx1 = bx1 + nx * mv, cy1 = by1 + ny * mv;
          pos[o++] = bx0;
          pos[o++] = by0;
          pos[o++] = bx1;
          pos[o++] = by1;
          pos[o++] = cx1;
          pos[o++] = cy1;
          pos[o++] = bx0;
          pos[o++] = by0;
          pos[o++] = cx1;
          pos[o++] = cy1;
          pos[o++] = cx0;
          pos[o++] = cy0;
          bx0 = bx1;
          by0 = by1;
          cx0 = cx1;
          cy0 = cy1;
        }
      }
      final vertices = ui.Vertices.raw(ui.VertexMode.triangles, pos);
      canvas.drawVertices(vertices, BlendMode.srcOver, paint);
      vertices.dispose();
    }
    return recorder.endRecording();
  }
}

class ScenePainter extends CustomPainter {
  ScenePainter(this.state, this.cache, this.scheme) : super(repaint: state);

  final AppState state;
  final SceneCache cache;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    state.paintCount++;
    state.canvasSize = size;
    final m = state.model;
    if (m == null) return;
    if (state.needsFit && size.width > 0) state.fitView(size);
    final v = state.view;

    // Pictures are rebuilt when the zoom moves a bucket (a factor of 1.4); line width is ~1.6 px at the
    // zoom they were built for.
    final bucket = (math.log(v.zoom) / math.log(1.4)).round();
    final worldWidth = 1.6 / math.pow(1.4, bucket.toDouble());

    canvas.save();
    canvas.translate(v.ox, v.oy);
    canvas.scale(v.zoom, -v.zoom);
    canvas.drawPicture(cache.members(state, worldWidth, bucket));
    if (state.solution != null) {
      if (state.showMoment) canvas.drawPicture(cache.moment(state));
      if (state.showDeflected) canvas.drawPicture(cache.deflected(state, worldWidth * 1.3, bucket));
    }
    canvas.restore();

    _supports(canvas, m, size);
    if (state.showLoads) _loads(canvas, m, size);
    _nodes(canvas, m, size);
    _selection(canvas, m);
    if (state.colorByMoment && state.solution != null) _legend(canvas, size);
  }

  void _supports(Canvas canvas, ModelData m, Size size) {
    final v = state.view;
    final fill = Paint()..color = scheme.tertiary.withValues(alpha: 0.85);
    final stroke = Paint()
      ..color = scheme.tertiary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final supported = cache.supportedNodes(m);
    final stride = supported.length > 600 ? (supported.length / 600).ceil() : 1;
    for (var q = 0; q < supported.length; q += stride) {
      final i = supported[q];
      final p = v.toScreen(m.nodeXy[i * 2], m.nodeXy[i * 2 + 1]);
      if (p.dx < -20 || p.dy < -20 || p.dx > size.width + 20 || p.dy > size.height + 20) continue;
      final f = m.nodeSupport[i];
      if (f == 7) {
        canvas.drawRect(Rect.fromCenter(center: p.translate(0, 5), width: 14, height: 8), fill);
      } else {
        final path = Path()
          ..moveTo(p.dx, p.dy)
          ..lineTo(p.dx - 7, p.dy + 12)
          ..lineTo(p.dx + 7, p.dy + 12)
          ..close();
        canvas.drawPath(path, fill);
        if (f & 3 != 3) canvas.drawCircle(p.translate(0, 15), 3, stroke);
      }
    }
  }

  void _nodes(Canvas canvas, ModelData m, Size size) {
    final v = state.view;
    if (m.memberCount == 0) return;
    final avgLen = m.memberLength[m.memberCount ~/ 2];
    if (avgLen * v.zoom < 14) return;
    final paint = Paint()..color = scheme.onSurface.withValues(alpha: 0.75);
    final pts = <double>[];
    for (var i = 0; i < m.nodeCount; i++) {
      final p = v.toScreen(m.nodeXy[i * 2], m.nodeXy[i * 2 + 1]);
      if (p.dx < -4 || p.dy < -4 || p.dx > size.width + 4 || p.dy > size.height + 4) continue;
      pts
        ..add(p.dx)
        ..add(p.dy);
      if (pts.length > 40000) break;
    }
    paint
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    canvas.drawRawPoints(ui.PointMode.points, Float32List.fromList(pts), paint);
  }

  void _loads(Canvas canvas, ModelData m, Size size) {
    final v = state.view;
    final ci = state.caseIndex;
    final paint = Paint()
      ..color = const Color(0xFFEF6C00)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    // Nodal loads: arrow of fixed length pointing along the force.
    final count = m.nodalLoadIx.length ~/ 2;
    var drawn = 0;
    for (var k = 0; k < count && drawn < 800; k++) {
      if (m.nodalLoadIx[k * 2] != ci) continue;
      final node = m.nodalLoadIx[k * 2 + 1];
      final fx = m.nodalLoadF[k * 3], fy = m.nodalLoadF[k * 3 + 1];
      final mag = math.sqrt(fx * fx + fy * fy);
      if (mag == 0) continue;
      final tip = v.toScreen(m.nodeXy[node * 2], m.nodeXy[node * 2 + 1]);
      if (tip.dx < -40 || tip.dy < -40 || tip.dx > size.width + 40 || tip.dy > size.height + 40) continue;
      drawn++;
      final dir = Offset(fx / mag, -fy / mag);
      _arrow(canvas, tip - dir * 34, tip, paint);
    }
    // Member UDLs: a short arrow row beside the member, only when few enough to read.
    final udls = m.udlW.length;
    if (udls > 400) return;
    for (var k = 0; k < udls; k++) {
      if (m.udlIx[k * 2] != ci) continue;
      final mem = m.udlIx[k * 2 + 1];
      final a = v.toScreen(m.nodeXy[m.memberNodes[mem * 2] * 2], m.nodeXy[m.memberNodes[mem * 2] * 2 + 1]);
      final b = v.toScreen(m.nodeXy[m.memberNodes[mem * 2 + 1] * 2], m.nodeXy[m.memberNodes[mem * 2 + 1] * 2 + 1]);
      final d = b - a;
      final len = d.distance;
      if (len < 12) continue;
      // Load acts along local y (rotated +90 degrees from the member axis, in world coordinates).
      final w = m.udlW[k];
      final localY = Offset(d.dy / len, -d.dx / len); // screen coords have Y down
      final push = localY * (w < 0 ? -1.0 : 1.0);
      final steps = math.max(2, (len / 28).floor());
      for (var q = 0; q <= steps; q++) {
        final p = a + d * (q / steps);
        _arrow(canvas, p - push * 18, p - push * 3, paint);
      }
    }
  }

  void _arrow(Canvas canvas, Offset from, Offset to, Paint paint) {
    canvas.drawLine(from, to, paint);
    final d = to - from;
    final len = d.distance;
    if (len < 1) return;
    final u = d / len;
    final n = Offset(-u.dy, u.dx);
    canvas.drawLine(to, to - u * 6 + n * 3.5, paint);
    canvas.drawLine(to, to - u * 6 - n * 3.5, paint);
  }

  void _selection(Canvas canvas, ModelData m) {
    final v = state.view;
    final mem = state.selectedMember;
    if (mem != null && mem < m.memberCount) {
      final i = m.memberNodes[mem * 2], j = m.memberNodes[mem * 2 + 1];
      canvas.drawLine(
        v.toScreen(m.nodeXy[i * 2], m.nodeXy[i * 2 + 1]),
        v.toScreen(m.nodeXy[j * 2], m.nodeXy[j * 2 + 1]),
        Paint()
          ..color = scheme.primary
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }
    final node = state.selectedNode;
    if (node != null && node < m.nodeCount) {
      final p = v.toScreen(m.nodeXy[node * 2], m.nodeXy[node * 2 + 1]);
      canvas.drawCircle(
        p,
        8,
        Paint()
          ..color = scheme.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  void _legend(Canvas canvas, Size size) {
    final sol = state.solution!;
    var maxM = 0.0;
    for (final v in sol.memberMaxAbsM) {
      maxM = math.max(maxM, v);
    }
    const w = 14.0, h = 120.0;
    final left = size.width - 90, top = 16.0;
    for (var b = 0; b < _buckets; b++) {
      final r = Rect.fromLTWH(left, top + h * (1 - (b + 1) / _buckets), w, h / _buckets + 0.5);
      canvas.drawRect(r, Paint()..color = bucketColor(b));
    }
    final style = TextStyle(color: scheme.onSurface, fontSize: 11);
    _text(canvas, 'max |M|', Offset(left - 4, top - 14), style);
    _text(canvas, '${(maxM / 1000).toStringAsFixed(1)} kN·m', Offset(left + w + 4, top - 2), style);
    _text(canvas, '0', Offset(left + w + 4, top + h - 12), style);
  }

  void _text(Canvas canvas, String text, Offset at, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(ScenePainter old) => true;
}

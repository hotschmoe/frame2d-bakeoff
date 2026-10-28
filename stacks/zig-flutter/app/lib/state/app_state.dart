import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import '../engine/frame_engine.dart';

/// Everything the UI shows: the engine session, the view transform, overlay switches and the latest
/// results. The UI is a thin layer: all analysis happens in the engine.
class AppState extends ChangeNotifier {
  AppState(this.engine);

  final FrameEngine engine;

  // ---- model / results ----
  bool hasModel = false;
  String? error;
  SolveStats stats = SolveStats.empty;
  int caseIndex = 0;

  /// Bumps whenever geometry or results change; painters and tables key their caches on it.
  int stamp = 0;
  int _staleMask = 0;
  bool dragging = false;

  Int32List nodeIds = Int32List(0);
  Float64List nodeXy = Float64List(0);
  Uint8List restraint = Uint8List(0);
  Int32List memberIds = Int32List(0);
  Uint32List memberEnds = Uint32List(0);
  Float64List memberLength = Float64List(0);
  List<String> caseNames = const [];

  // Dart-owned copies of the selected case's results (never views onto engine memory, so a Save or any
  // other engine call cannot invalidate them). Each solve copies into the same lists while sizes match.
  Float64List? disp;
  Float64List? endForces;
  Float64List? maxM;
  Float64List? stationM;
  double maxMAll = 0;
  double maxDisp = 0;
  double residual = 0;

  /// Wall time of the last engine solve call as seen from Dart (bench `solve_ms`).
  double lastSolveMs = 0;

  // ---- overlays ----
  bool showDeflected = true;
  bool showMoment = true;
  bool colorByMoment = true;

  /// Slider position 0..1; maps to 0.1x .. 10x of the automatic deflection scale.
  double deflSlider = 0.5;

  double get deflScale => _autoDeflScale * math.pow(10, (deflSlider - 0.5) * 2);
  double _autoDeflScale = 1;

  // ---- view (screen = off + world * scale, y flipped) ----
  double scale = 10;
  double offX = 0;
  double offY = 0;
  Size viewSize = Size.zero;
  int? selectedNode;
  bool _fitPending = false;

  int get nodeCount => nodeIds.length;
  int get memberCount => memberIds.length;

  /// Data changed (geometry or results): invalidates painter caches.
  void _changed() {
    stamp++;
    notifyListeners();
  }

  /// Only the view or an overlay switch changed.
  void _viewChanged() => notifyListeners();

  // ---- loading ----

  String? loadText(String text) {
    final err = engine.loadJson(text);
    return _afterLoad(err);
  }

  String? generate(int bays, int stories) {
    final err = engine.generate(bays, stories);
    return _afterLoad(err);
  }

  String? _afterLoad(String? err) {
    if (err != null) {
      error = err;
      notifyListeners();
      return err;
    }
    hasModel = true;
    error = null;
    caseIndex = 0;
    selectedNode = null;
    _pullGeometry();
    caseNames = [for (var k = 0; k < engine.caseCount; k++) engine.caseName(k)];
    _staleMask = 0;
    _solve(_allCases(), notify: false);
    _autoDeflScale = maxDisp > 0 ? 0.8 / maxDisp : 1;
    fitView();
    _changed();
    return error;
  }

  int _allCases() => (1 << engine.caseCount) - 1;

  void _pullGeometry() {
    nodeIds = engine.nodeIds;
    nodeXy = engine.nodeXy;
    restraint = engine.nodeRestraint;
    memberIds = engine.memberIds;
    memberEnds = engine.memberEnds;
    memberLength = engine.memberLength;
  }

  // ---- solving ----

  /// Solves [mask] and refreshes the cached result views. Returns the engine error, if any.
  String? _solve(int mask, {bool notify = true}) {
    final sw = Stopwatch()..start();
    final err = engine.solve(mask);
    lastSolveMs = sw.elapsedMicroseconds / 1000.0;
    if (err != null) {
      error = err;
      if (notify) _changed();
      return err;
    }
    error = null;
    stats = engine.stats;
    _staleMask = (_staleMask | _allCases()) & ~mask;
    _pullResults();
    if (notify) _changed();
    return null;
  }

  void _pullResults() {
    if (!hasModel) return;
    // nodeXy is the engine's Dart-owned mirror (same list); member lengths are refreshed in place.
    nodeXy = engine.nodeXy;
    memberLength = engine.memberLength;
    disp = engine.displacements(caseIndex, into: disp);
    endForces = engine.endForces(caseIndex, into: endForces);
    maxM = engine.maxMoment(caseIndex, into: maxM);
    stationM = engine.stationMoments(caseIndex, into: stationM);
    residual = engine.residual(caseIndex);
    var mm = 0.0;
    final m = maxM;
    if (m != null) {
      for (var k = 0; k < m.length; k++) {
        if (m[k] > mm) mm = m[k];
      }
    }
    maxMAll = mm;
    var md = 0.0;
    final d = disp;
    if (d != null) {
      for (var k = 0; k < d.length; k += 3) {
        final v = d[k] * d[k] + d[k + 1] * d[k + 1];
        if (v > md) md = v;
      }
    }
    maxDisp = math.sqrt(md);
  }

  /// Re-solve every load case (toolbar "Solve").
  void solveAll() {
    if (!hasModel) return;
    _solve(_allCases());
  }

  void selectCase(int k) {
    if (k == caseIndex || k < 0 || k >= caseNames.length) return;
    caseIndex = k;
    if (_staleMask & (1 << k) != 0) {
      _solve(1 << k, notify: false);
    } else {
      _pullResults();
    }
    _changed();
  }

  /// Moves one node and re-solves the selected load case.
  void moveNode(int index, double x, double y) {
    engine.setNodeXY(index, x, y);
    _solve(1 << caseIndex);
  }

  // ---- view ----

  void fitView() {
    if (nodeXy.isEmpty || viewSize.isEmpty) {
      _fitPending = true;
      return;
    }
    _fitPending = false;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (var k = 0; k < nodeXy.length; k += 2) {
      final x = nodeXy[k], y = nodeXy[k + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    final w = math.max(maxX - minX, 1e-6), h = math.max(maxY - minY, 1e-6);
    scale = math.min(viewSize.width / w, viewSize.height / h) * 0.86;
    offX = viewSize.width / 2 - (minX + maxX) / 2 * scale;
    offY = viewSize.height / 2 + (minY + maxY) / 2 * scale;
  }

  /// Called by the canvas whenever its size is known or changes.
  void setViewSize(Size size) {
    viewSize = size;
    // Runs during layout, so no notification: the canvas paints in this same frame with the fitted view.
    if (_fitPending && !size.isEmpty) fitView();
  }

  /// Center the view on world point (cx, cy) at an absolute [newScale].
  void setView(double cx, double cy, double newScale) {
    scale = newScale;
    offX = viewSize.width / 2 - cx * scale;
    offY = viewSize.height / 2 + cy * scale;
    _viewChanged();
  }

  void zoomAt(Offset focal, double factor) {
    final ns = (scale * factor).clamp(0.02, 5000.0);
    final f = ns / scale;
    offX = focal.dx - (focal.dx - offX) * f;
    offY = focal.dy - (focal.dy - offY) * f;
    scale = ns;
    _viewChanged();
  }

  void panBy(double dx, double dy) {
    offX += dx;
    offY += dy;
    _viewChanged();
  }

  Offset toWorld(Offset p) => Offset((p.dx - offX) / scale, (offY - p.dy) / scale);

  /// Index of the node closest to screen point [p] within [radius] px, or -1.
  int hitNode(Offset p, double radius) {
    var best = -1;
    var bestD = radius * radius;
    for (var k = 0; k < nodeXy.length; k += 2) {
      final dx = offX + nodeXy[k] * scale - p.dx;
      if (dx > radius || dx < -radius) continue;
      final dy = offY - nodeXy[k + 1] * scale - p.dy;
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = k >> 1;
      }
    }
    return best;
  }

  void setDragging(bool v) {
    dragging = v;
    if (!v) _viewChanged();
  }

  void select(int? node) {
    selectedNode = node;
    _viewChanged();
  }

  void setShowDeflected(bool v) {
    showDeflected = v;
    _viewChanged();
  }

  void setShowMoment(bool v) {
    showMoment = v;
    _viewChanged();
  }

  void setColorByMoment(bool v) {
    colorByMoment = v;
    _viewChanged();
  }

  void setDeflSlider(double v) {
    deflSlider = v;
    _viewChanged();
  }

  /// Current model as JSON text, for saving.
  String exportJson() => engine.exportModelJson();

  void report(String message) {
    error = message;
    notifyListeners();
  }
}

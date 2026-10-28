import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import 'engine/engine.dart';

/// Holds the loaded model session, Dart-owned copies of its geometry and latest results (never views into engine
/// memory, which a free, a new model or a wasm memory.grow would invalidate) and the view.
/// No analysis happens here: Dart only does state, geometry-to-screen mapping and drawing.
class AppState extends ChangeNotifier {
  AppState(this.engine);

  final Engine engine;

  int handle = 0;
  int nodeCount = 0;
  int memberCount = 0;
  List<String> caseIds = const [];
  int caseIndex = 0;
  bool solved = false;
  String? error;

  Float64List geo = Float64List(0);
  Float64List res = Float64List(0);
  Float64List stats = Float64List(Layout.statCount);
  double lastSolveMs = 0;

  /// Time the canvas painter spent recording the last frame (CPU side only).
  double paintMs = 0;

  // overlays
  bool showDeflected = true;
  bool showMoment = false;
  bool colorByMoment = true;
  double deflectionSlider = 1.0;

  // derived from the model/results
  double minX = 0, maxX = 1, minY = 0, maxY = 1;
  double avgLength = 1;
  double maxMoment = 0;
  double maxDisp = 0;
  int selectedNode = -1;
  int selectedMember = -1;

  // view: screen = (ox + x*k, oy - y*k)
  double k = 1, ox = 0, oy = 0;
  double viewW = 800, viewH = 600;

  /// Bumped on every solve/model change; the table and painter key their caches on it.
  int version = 0;

  // ---- geometry accessors -------------------------------------------------
  double nodeX(int i) => geo[i * Layout.nodeStride + 1];
  double nodeY(int i) => geo[i * Layout.nodeStride + 2];
  int nodeId(int i) => geo[i * Layout.nodeStride].toInt();
  int nodeMask(int i) => geo[i * Layout.nodeStride + 3].toInt();
  int get _mBase => nodeCount * Layout.nodeStride;
  int memberId(int m) => geo[_mBase + m * Layout.memberStride].toInt();
  int memberI(int m) => geo[_mBase + m * Layout.memberStride + 1].toInt();
  int memberJ(int m) => geo[_mBase + m * Layout.memberStride + 2].toInt();
  double memberLength(int m) {
    final a = memberI(m), b = memberJ(m);
    return math.sqrt(math.pow(nodeX(b) - nodeX(a), 2) + math.pow(nodeY(b) - nodeY(a), 2));
  }

  // ---- result accessors ---------------------------------------------------
  int get _rBase => nodeCount * 3;
  double disp(int node, int dof) => res[node * 3 + dof];
  double endForce(int m, int c) => res[_rBase + m * Layout.resMember + c];
  double memberMaxM(int m) => res[_rBase + m * Layout.resMember + 6];
  double stationM(int m, int s) => res[_rBase + m * Layout.resMember + 7 + s];

  // ---- model lifecycle ----------------------------------------------------
  bool generate(int bays, int stories) => _adopt(engine.gen(bays, stories));

  bool loadJson(String json) => _adopt(engine.loadJson(json));

  bool _adopt(int h) {
    if (h <= 0) {
      error = engine.lastError();
      notifyListeners();
      return false;
    }
    final old = handle;
    handle = h;
    final (n, m, _) = engine.counts(h);
    nodeCount = n;
    memberCount = m;
    geo = engine.geometry(h);
    res = Float64List(Layout.resultLength(n, m)); // reused by every solve of this model
    stats = Float64List(Layout.statCount);
    if (old > 0) engine.free(old); // only after nothing refers to the old session
    caseIds = engine.caseIds(h);
    caseIndex = 0;
    error = null;
    selectedNode = selectedMember = -1;
    solved = false;
    _bbox();
    fitView();
    solve();
    return true;
  }

  String exportJson() => engine.toJson(handle);

  void _bbox() {
    minX = minY = double.infinity;
    maxX = maxY = double.negativeInfinity;
    for (var i = 0; i < nodeCount; i++) {
      minX = math.min(minX, nodeX(i));
      maxX = math.max(maxX, nodeX(i));
      minY = math.min(minY, nodeY(i));
      maxY = math.max(maxY, nodeY(i));
    }
    if (nodeCount == 0) minX = minY = maxX = maxY = 0;
    var sum = 0.0;
    for (var m = 0; m < memberCount; m++) {
      sum += memberLength(m);
    }
    avgLength = memberCount > 0 && sum > 0 ? sum / memberCount : 1;
  }

  /// Solves the selected load case in the engine and refreshes derived values.
  bool solve() {
    if (handle <= 0) return false;
    final sw = Stopwatch()..start();
    final rc = engine.solve(handle, caseIndex);
    if (rc != 0) {
      error = engine.lastError();
      solved = false;
      version++;
      notifyListeners();
      return false;
    }
    error = null;
    res = engine.resultInto(handle, res);
    stats = engine.statsInto(handle, stats);
    lastSolveMs = sw.elapsedMicroseconds / 1000.0;
    solved = true;
    _maxima();
    version++;
    notifyListeners();
    return true;
  }

  void _maxima() {
    var md = 0.0;
    for (var i = 0; i < nodeCount; i++) {
      md = math.max(md, math.max(disp(i, 0).abs(), disp(i, 1).abs()));
    }
    maxDisp = md;
    var mm = 0.0;
    for (var m = 0; m < memberCount; m++) {
      mm = math.max(mm, memberMaxM(m));
    }
    maxMoment = mm;
  }

  void setCase(int c) {
    caseIndex = c;
    solve();
  }

  /// Moves node [index] to (x, y) in the engine and re-solves the current case.
  void moveNode(int index, double x, double y) {
    engine.setNode(handle, index, x, y);
    // keep the Dart-side geometry copy in sync with the engine
    geo[index * Layout.nodeStride + 1] = x;
    geo[index * Layout.nodeStride + 2] = y;
    solve();
  }

  // ---- view ---------------------------------------------------------------
  void fitView() {
    final w = math.max(maxX - minX, 1e-6), h = math.max(maxY - minY, 1e-6);
    k = 0.9 * math.min(viewW / w, viewH / h);
    ox = viewW / 2 - (minX + maxX) / 2 * k;
    oy = viewH / 2 + (minY + maxY) / 2 * k;
  }

  void setViewSize(double w, double h) {
    if (w == viewW && h == viewH) return;
    viewW = w;
    viewH = h;
  }

  double worldX(double sx) => (sx - ox) / k;
  double worldY(double sy) => (oy - sy) / k;

  void panBy(double dx, double dy) {
    ox += dx;
    oy += dy;
    notifyListeners();
  }

  void zoomAt(double factor, double sx, double sy) {
    final nk = (k * factor).clamp(1e-3, 1e5);
    final f = nk / k;
    ox = sx - (sx - ox) * f;
    oy = sy - (sy - oy) * f;
    k = nk;
    notifyListeners();
  }

  void touch() {
    version++;
    notifyListeners();
  }

  void toggle({bool? deflected, bool? moment, bool? color}) {
    showDeflected = deflected ?? showDeflected;
    showMoment = moment ?? showMoment;
    colorByMoment = color ?? colorByMoment;
    notifyListeners();
  }

  void setDeflectionSlider(double v) {
    deflectionSlider = v;
    notifyListeners();
  }

  /// World-units of exaggeration applied to displacements.
  double get deflectionScale => maxDisp > 0 ? deflectionSlider * avgLength / maxDisp : 0;

  /// World-units per N*m for moment diagram ordinates.
  double get momentScale => maxMoment > 0 ? 0.4 * avgLength / maxMoment : 0;

  int nearestNode(double sx, double sy, double radiusPx) {
    var best = -1;
    var bestD = radiusPx * radiusPx;
    for (var i = 0; i < nodeCount; i++) {
      final dx = ox + nodeX(i) * k - sx, dy = oy - nodeY(i) * k - sy;
      final d = dx * dx + dy * dy;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  @override
  void dispose() {
    if (handle > 0) engine.free(handle);
    super.dispose();
  }
}

/// Application state: the current model and results, display options, and the view transform.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../engine/engine.dart';

/// World (metres, Y up) to screen: `sx = x * zoom + ox`, `sy = oy - y * zoom`.
class ViewTransform {
  double zoom = 1;
  double ox = 0;
  double oy = 0;

  Offset toScreen(double x, double y) => Offset(x * zoom + ox, oy - y * zoom);
  Offset toWorld(Offset p) => Offset((p.dx - ox) / zoom, (oy - p.dy) / zoom);

  /// Zooms by `factor` keeping the world point under `focus` fixed.
  void zoomAt(Offset focus, double factor) {
    final next = (zoom * factor).clamp(1e-3, 1e5);
    final f = next / zoom;
    ox = focus.dx - (focus.dx - ox) * f;
    oy = focus.dy - (focus.dy - oy) * f;
    zoom = next;
  }
}

/// One drag step as seen by the frame log (SPEC 5.5).
class DragSample {
  DragSample(this.solveMs, this.lagFrames);

  final double solveMs;
  final int lagFrames;
}

class AppState extends ChangeNotifier {
  AppState(this.engine);

  final Engine engine;
  final ViewTransform view = ViewTransform();

  ModelData? model;
  SolveData? solution;
  int caseIndex = 0;
  String? error;
  String modelName = 'no model';

  bool showDeflected = true;
  bool showMoment = true;
  bool colorByMoment = true;
  bool showLoads = true;

  /// Deflection magnification in metres of drawing per metre of displacement; 0 until the first solve.
  double deflectionScale = 0;
  double deflectionScaleMax = 1;

  /// Moment diagram height in metres per N*m; fixed per model so it does not pulse while dragging.
  double momentScale = 0;

  int? selectedMember;
  int? selectedNode;

  /// Bumped when node positions or the member set change / when a new solution arrives.
  int geometryVersion = 0;
  int solutionVersion = 0;
  bool needsFit = true;

  /// Incremented by the canvas on every paint; used to measure drag lag in frames.
  int paintCount = 0;

  /// Size of the canvas as of the last paint.
  Size canvasSize = Size.zero;
  bool busy = false;
  double lastCallMs = 0;
  final List<DragSample> dragLog = [];

  // Drag pump: only the newest requested position is solved, so slow solves never queue up.
  ({int pos, double x, double y, int inputPaint})? _pendingMove;
  bool _pumping = false;

  void _fail(Object e) {
    error = e is EngineError ? e.toString() : 'Unexpected error: $e';
    busy = false;
    notifyListeners();
  }

  /// Redraw after a change that does not touch model or results (pan, zoom).
  void repaint() => notifyListeners();

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<void> generate(int bays, int stories) =>
      _install(() => engine.generate(bays, stories), 'frame ${bays}x$stories');

  Future<void> loadJson(String json, String name) => _install(() => engine.load(json), name);

  /// Creates the model in the engine, solves case 0, then publishes model and results together so the
  /// canvas never draws a model whose results are still being computed.
  Future<void> _install(Future<ModelData> Function() create, String name) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final m = await create();
      final sw = Stopwatch()..start();
      final s = await engine.solve(0);
      lastCallMs = sw.elapsedMicroseconds / 1000;
      _adopt(m, name);
      _applySolution(s);
    } catch (e) {
      _fail(e);
    }
  }

  Future<String> exportJson() => engine.export();

  void _adopt(ModelData m, String name) {
    model = m;
    modelName = name;
    solution = null;
    caseIndex = 0;
    selectedMember = null;
    selectedNode = null;
    deflectionScale = 0;
    momentScale = 0;
    needsFit = true;
    geometryVersion++;
    solutionVersion++;
  }

  Future<void> solveCurrent() async {
    if (model == null) return;
    busy = true;
    notifyListeners();
    try {
      final sw = Stopwatch()..start();
      final s = await engine.solve(caseIndex);
      lastCallMs = sw.elapsedMicroseconds / 1000;
      _applySolution(s);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> selectCase(int i) async {
    caseIndex = i;
    await solveCurrent();
  }

  void _applySolution(SolveData s) {
    solution = s;
    model?.memberLength.setAll(0, s.memberLength);
    solutionVersion++;
    busy = false;
    if (deflectionScale == 0 || momentScale == 0) _autoScales(s);
    notifyListeners();
  }

  /// Picks drawing scales from the first solution of a model.
  void _autoScales(SolveData s) {
    final m = model!;
    var maxDisp = 0.0;
    for (var i = 0; i < m.nodeCount; i++) {
      maxDisp = math.max(maxDisp, math.max(s.disp[i * 3].abs(), s.disp[i * 3 + 1].abs()));
    }
    var maxM = 0.0;
    for (final v in s.memberMaxAbsM) {
      maxM = math.max(maxM, v);
    }
    final extent = modelExtent();
    final typical = m.memberCount == 0 ? 1.0 : _median(m.memberLength);
    if (maxDisp > 0) deflectionScale = 0.02 * extent / maxDisp;
    deflectionScaleMax = math.max(deflectionScale, 1e-9) * 6;
    if (maxM > 0) momentScale = 0.35 * typical / maxM;
  }

  double _median(Float64List v) {
    final c = List<double>.of(v)..sort();
    return c[c.length ~/ 2];
  }

  /// Larger side of the model's bounding box, in metres.
  double modelExtent() {
    final b = bounds();
    return math.max(b.right - b.left, b.bottom - b.top).clamp(1e-6, double.infinity);
  }

  ({double left, double top, double right, double bottom}) bounds() {
    final m = model;
    if (m == null || m.nodeCount == 0) return (left: 0, top: 0, right: 1, bottom: 1);
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (var i = 0; i < m.nodeCount; i++) {
      final x = m.nodeXy[i * 2], y = m.nodeXy[i * 2 + 1];
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }
    return (left: minX, top: minY, right: maxX, bottom: maxY);
  }

  void fitView(Size size) {
    final b = bounds();
    final w = math.max(b.right - b.left, 1e-3), h = math.max(b.bottom - b.top, 1e-3);
    const margin = 40.0;
    final zoom = math.max(1e-3, math.min((size.width - 2 * margin) / w, (size.height - 2 * margin) / h));
    view.zoom = zoom;
    view.ox = (size.width - w * zoom) / 2 - b.left * zoom;
    view.oy = (size.height + h * zoom) / 2 + b.top * zoom;
    needsFit = false;
  }

  void setDeflectionScale(double v) {
    deflectionScale = v;
    solutionVersion++;
    notifyListeners();
  }

  void toggle({bool? deflected, bool? moment, bool? color, bool? loads}) {
    showDeflected = deflected ?? showDeflected;
    showMoment = moment ?? showMoment;
    colorByMoment = color ?? colorByMoment;
    showLoads = loads ?? showLoads;
    solutionVersion++;
    notifyListeners();
  }

  void selectMember(int? index) {
    selectedMember = index;
    notifyListeners();
  }

  /// Nearest node within `radiusPx` of the screen point, as a position, or null.
  int? hitNode(Offset screen, double radiusPx) {
    final m = model;
    if (m == null) return null;
    final w = view.toWorld(screen);
    final r = radiusPx / view.zoom;
    var best = -1;
    var bestD = r * r;
    for (var i = 0; i < m.nodeCount; i++) {
      final dx = m.nodeXy[i * 2] - w.dx, dy = m.nodeXy[i * 2 + 1] - w.dy;
      final d = dx * dx + dy * dy;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best < 0 ? null : best;
  }

  /// Interactive drag: record the newest position and make sure a solve is running.
  void dragNode(int pos, double x, double y) {
    selectedNode = pos;
    _pendingMove = (pos: pos, x: x, y: y, inputPaint: paintCount);
    if (!_pumping) _pump();
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (_pendingMove != null) {
        final move = _pendingMove!;
        _pendingMove = null;
        final s = await solveMove(move.pos, move.x, move.y);
        await SchedulerBinding.instance.endOfFrame;
        dragLog.add(DragSample(s.engineMs, math.max(0, paintCount - move.inputPaint - 1)));
        if (dragLog.length > 1000) dragLog.removeRange(0, 500);
      }
    } catch (e) {
      _fail(e);
    } finally {
      _pumping = false;
    }
  }

  /// Moves a node and solves the current case; used by the drag pump and the drag benchmark.
  Future<SolveData> solveMove(int pos, double x, double y) async {
    final m = model!;
    m.nodeXy[pos * 2] = x;
    m.nodeXy[pos * 2 + 1] = y;
    geometryVersion++;
    final sw = Stopwatch()..start();
    final s = await engine.moveAndSolve(pos, x, y, caseIndex);
    lastCallMs = sw.elapsedMicroseconds / 1000;
    _applySolution(s);
    return s;
  }
}

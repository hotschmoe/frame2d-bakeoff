import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

import 'app_state.dart';
import 'engine/engine.dart';
import 'io/platform.dart';

/// Bench modes (SPEC 5.5). Results are printed as one `BENCH {...}` line (stdout on desktop, console.log on web).
class Bench {
  Bench(this.mode, this.engine, this.state);
  final String mode;
  final Engine engine;
  final AppState? state;

  void _emit(Map<String, Object?> m) => emitBench('BENCH ${jsonEncode(m)}');

  /// Completes after the next frame has been built and painted.
  Future<void> _nextFrame() {
    final c = Completer<void>();
    SchedulerBinding.instance.addPostFrameCallback((_) => c.complete());
    SchedulerBinding.instance.scheduleFrame();
    return c.future;
  }

  final List<double> paintMs = [];
  final List<double> buildMs = [], rasterMs = [];

  void _onTimings(List<FrameTiming> t) {
    for (final f in t) {
      buildMs.add(f.buildDuration.inMicroseconds / 1000.0);
      rasterMs.add(f.rasterDuration.inMicroseconds / 1000.0);
    }
  }

  double _med(List<double> v) => v.isEmpty ? 0.0 : _pct(List<double>.of(v)..sort(), 0.5);

  static double _pct(List<double> sorted, double p) =>
      sorted[math.min(sorted.length - 1, (p * sorted.length).floor())];

  Map<String, Object?> _stats(String mode, List<double> frames, List<double> solves, int lagMax) {
    final f = List<double>.of(frames)..sort();
    final s = List<double>.of(solves)..sort();
    return {
      'mode': mode,
      'p50': _pct(f, 0.50),
      'p95': _pct(f, 0.95),
      'p99': _pct(f, 0.99),
      'max': f.last,
      'solve_p50': s.isEmpty ? 0.0 : _pct(s, 0.50),
      'lag_max': lagMax,
      'rss_mb': rssMb(),
      'paint_p50': _med(paintMs),
      'build_p50': _med(buildMs),
      'raster_p50': _med(rasterMs),
    };
  }

  Future<void> run() async {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    switch (mode) {
      case 'drag':
        await _drag();
      case 'render':
        await _render();
      case 'startup':
        await _startup();
      case 'ready':
        await _ready();
      case 'boundary':
        _boundary();
      default:
        emitBench('BENCH ${jsonEncode({'mode': mode, 'error': 'unknown bench mode'})}');
    }
    await finishBench();
  }

  Future<void> _startup() async {
    final s = state!;
    s.generate(50, 50);
    await _nextFrame();
    _emit({'mode': 'startup', 'first_frame_ms': sinceStartMs(engine)});
  }

  Future<void> _ready() async {
    await _nextFrame();
    _emit({'mode': 'ready', 'tti_ms': sinceStartMs(engine)});
  }

  Future<void> _drag() async {
    final s = state!;
    const bays = 50, stories = 50, frames = 600;
    s.generate(bays, stories);
    s.toggle(deflected: true, moment: false);
    await _nextFrame();
    final nodeId = stories * (bays + 1) + bays ~/ 2 + 1;
    var idx = 0;
    for (var i = 0; i < s.nodeCount; i++) {
      if (s.nodeId(i) == nodeId) idx = i;
    }
    s.selectedNode = idx;
    final bx = s.nodeX(idx), by = s.nodeY(idx);
    final frameMs = <double>[], solveMs = <double>[];
    paintMs.clear();
    buildMs.clear();
    rasterMs.clear();
    final sw = Stopwatch()..start();
    for (var f = 0; f < frames; f++) {
      final t0 = sw.elapsedMicroseconds;
      final a = 2 * math.pi * f / frames;
      s.moveNode(idx, bx + 0.5 * math.cos(a), by + 0.5 * math.sin(a));
      solveMs.add(s.lastSolveMs);
      await _nextFrame();
      frameMs.add((sw.elapsedMicroseconds - t0) / 1000.0);
      paintMs.add(s.paintMs);
    }
    // the solve runs synchronously on the UI thread, so a result is always drawn in the frame of its input
    _emit(_stats('drag', frameMs, solveMs, 0));
  }

  Future<void> _render() async {
    final s = state!;
    const frames = 600;
    s.generate(200, 200);
    s.toggle(deflected: false, moment: true, color: true);
    await _nextFrame();
    final baseK = s.k;
    final cy = (s.minY + s.maxY) / 2, w = s.maxX - s.minX;
    final frameMs = <double>[];
    paintMs.clear();
    buildMs.clear();
    rasterMs.clear();
    final sw = Stopwatch()..start();
    for (var f = 0; f < frames; f++) {
      final t0 = sw.elapsedMicroseconds;
      final p = f / (frames - 1);
      final zoom = 1 + 7 * (1 - (1 - 2 * p).abs());
      s.k = baseK * zoom;
      final cx = s.minX + p * w;
      s.ox = s.viewW / 2 - cx * s.k;
      s.oy = s.viewH / 2 + cy * s.k;
      s.touch();
      await _nextFrame();
      frameMs.add((sw.elapsedMicroseconds - t0) / 1000.0);
      paintMs.add(s.paintMs);
    }
    _emit(_stats('render', frameMs, const [], 0));
  }

  void _boundary() {
    const calls = 1000000, echoCalls = 1000, n = 38103;
    engine.noop();
    final sw = Stopwatch()..start();
    for (var i = 0; i < calls; i++) {
      engine.noop();
    }
    final noopNs = sw.elapsedMicroseconds * 1000.0 / calls;
    var sink = 0.0;
    engine.echo(n);
    sw
      ..reset()
      ..start();
    for (var i = 0; i < echoCalls; i++) {
      final v = engine.echo(n);
      sink += v[0] + v[n - 1];
    }
    final transferUs = sw.elapsedMicroseconds / echoCalls;
    _emit({
      'mode': 'boundary',
      'noop_ns': noopNs,
      'transfer_us': transferUs,
      'mechanism': engine.mechanism,
      'check': sink,
    });
  }
}

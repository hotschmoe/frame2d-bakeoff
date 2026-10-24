import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart' show kIsWasm;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../engine/frame_engine.dart';
import '../state/app_state.dart';
import 'platform.dart';

/// Bench modes of SPEC 5.5: drag, render, startup, ready, boundary.
const benchModes = {'drag', 'render', 'startup', 'ready', 'boundary'};

void _emit(Map<String, Object?> fields) {
  benchEmit('BENCH ${jsonEncode(fields)}');
}

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p).round();
  return sorted[idx];
}

double _round(double v) => (v * 1000).roundToDouble() / 1000;

/// The boundary bench needs no UI: it times the call path into the engine.
void runBoundaryBench(FrameEngine engine) {
  for (var i = 0; i < 20000; i++) {
    engine.noop();
  }
  const noopCalls = 1000000;
  var sw = Stopwatch()..start();
  for (var i = 0; i < noopCalls; i++) {
    engine.noop();
  }
  final noopNs = sw.elapsedMicroseconds * 1000.0 / noopCalls;

  const n = 38103;
  const echoCalls = 1000;
  var sink = 0.0;
  for (var i = 0; i < 20; i++) {
    final v = engine.echo(n);
    sink += v[0] + v[n - 1];
  }
  sw = Stopwatch()..start();
  for (var i = 0; i < echoCalls; i++) {
    final v = engine.echo(n);
    sink += v[0] + v[n - 1];
  }
  final transferUs = sw.elapsedMicroseconds / echoCalls;
  if (sink.isNaN) benchEmit('unreachable');
  _emit({
    'mode': 'boundary',
    'noop_ns': _round(noopNs),
    'transfer_us': _round(transferUs),
    'mechanism': engine.transferMechanism,
    'backend': engine.backend,
  });
  benchFinish();
}

/// Wraps the app and runs one of the frame-driven bench modes once the first frame is up.
class BenchHost extends StatefulWidget {
  const BenchHost({super.key, required this.mode, required this.state, required this.child});

  final String mode;
  final AppState state;
  final Widget child;

  @override
  State<BenchHost> createState() => _BenchHostState();
}

class _BenchHostState extends State<BenchHost> with SingleTickerProviderStateMixin {
  final List<FrameTiming> _timings = [];
  Ticker? _ticker;
  bool _started = false;

  AppState get s => widget.state;
  FrameEngine get engine => s.engine;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    if (widget.mode == 'ready') {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _emit({'mode': 'ready', 'tti_ms': _round(engine.sinceStartMs()), 'backend': engine.backend});
        benchFinish();
      });
    } else if (widget.mode == 'startup') {
      SchedulerBinding.instance.addPostFrameCallback((_) => _startupAfterFirstFrame());
    } else {
      // Two frames: the first lays out and fits the view, the second is a steady-state frame.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        SchedulerBinding.instance.addPostFrameCallback((_) => _begin());
        SchedulerBinding.instance.scheduleFrame();
      });
    }
  }

  void _onTimings(List<FrameTiming> t) => _timings.addAll(t);

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker?.dispose();
    super.dispose();
  }

  Future<void> _startupAfterFirstFrame() async {
    // UI-thread work for the first frame is done here; add the raster time the engine reports for it.
    final built = engine.sinceStartMs();
    for (var i = 0; i < 100 && _timings.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    var firstFrame = built;
    if (_timings.isNotEmpty) {
      final t = _timings.first;
      final rasterUs = t.timestampInMicroseconds(FramePhase.rasterFinish) - t.timestampInMicroseconds(FramePhase.buildFinish);
      firstFrame = built + rasterUs / 1000.0;
    }
    _emit({'mode': 'startup', 'first_frame_ms': _round(firstFrame), 'backend': engine.backend});
    benchFinish();
  }

  void _begin() {
    if (_started) return;
    _started = true;
    _timings.clear();
    if (widget.mode == 'drag') {
      _runDrag();
    } else {
      _runRender();
    }
  }

  /// Runs [frame] once per rendered frame, [frames] times, then reports.
  void _drive(int frames, void Function(int i) frame, Future<void> Function(List<double> tickMs) done) {
    var i = 0;
    Duration? last;
    final tickMs = <double>[];
    _ticker = createTicker((elapsed) {
      if (last != null) tickMs.add((elapsed - last!).inMicroseconds / 1000.0);
      last = elapsed;
      if (i >= frames) {
        _ticker!.stop();
        done(tickMs);
        return;
      }
      frame(i++);
    })
      ..start();
  }

  /// frame_ms of each frame from the engine's frame timings (vsync start to raster finish), or tick
  /// intervals when the platform reports none.
  Future<List<double>> _frameTimes(int frames, List<double> tickMs) async {
    for (var i = 0; i < 100 && _timings.length < frames; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_timings.isEmpty) return tickMs;
    final take = _timings.length > frames ? _timings.sublist(_timings.length - frames) : _timings;
    return [
      for (final t in take)
        (t.timestampInMicroseconds(FramePhase.rasterFinish) - t.timestampInMicroseconds(FramePhase.vsyncStart)) / 1000.0,
    ];
  }

  Map<String, Object?> _summary(String mode, List<double> frames) {
    final sorted = List<double>.of(frames)..sort();
    final ui = [for (final t in _timings) t.buildDuration.inMicroseconds / 1000.0]..sort();
    final raster = [for (final t in _timings) t.rasterDuration.inMicroseconds / 1000.0]..sort();
    return {
      'ui_p50': _round(_percentile(ui, 0.5)),
      'raster_p50': _round(_percentile(raster, 0.5)),
      'mode': mode,
      'p50': _round(_percentile(sorted, 0.50)),
      'p95': _round(_percentile(sorted, 0.95)),
      'p99': _round(_percentile(sorted, 0.99)),
      'max': _round(sorted.isEmpty ? 0 : sorted.last),
    };
  }

  void _runDrag() {
    const frames = 600;
    final bays = 50, stories = 50;
    final id = stories * (bays + 1) + bays ~/ 2 + 1;
    final index = s.nodeIds.indexOf(id);
    final x0 = s.nodeXy[index * 2], y0 = s.nodeXy[index * 2 + 1];
    s.select(index);
    final solveMs = <double>[];
    _drive(frames, (i) {
      final a = 2 * math.pi * i / frames;
      s.moveNode(index, x0 + 0.5 * math.cos(a), y0 + 0.5 * math.sin(a));
      solveMs.add(s.lastSolveMs);
    }, (tickMs) async {
      final ft = await _frameTimes(frames, tickMs);
      final solveSorted = List<double>.of(solveMs)..sort();
      _emit({
        ..._summary('drag', ft),
        'solve_p50': _round(_percentile(solveSorted, 0.5)),
        // The solve runs synchronously on the UI thread, so a result always lands in its own frame.
        'lag_max': 0,
        'rss_mb': residentMemoryMb(),
        'backend': engine.backend,
      });
      benchFinish();
    });
  }

  void _runRender() {
    const frames = 600;
    var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
    final xy = s.nodeXy;
    for (var k = 0; k < xy.length; k += 2) {
      minX = math.min(minX, xy[k]);
      maxX = math.max(maxX, xy[k]);
      minY = math.min(minY, xy[k + 1]);
      maxY = math.max(maxY, xy[k + 1]);
    }
    final base = s.scale;
    _drive(frames, (i) {
      final t = i / (frames - 1);
      final zoom = 1 + 7 * math.sin(math.pi * t);
      s.setView(minX + (maxX - minX) * t, (minY + maxY) / 2, base * zoom);
    }, (tickMs) async {
      final ft = await _frameTimes(frames, tickMs);
      _emit({
        ..._summary('render', ft),
        'rss_mb': residentMemoryMb(),
        'backend': engine.backend,
      });
      benchFinish();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Prepares the model a bench mode needs before the first frame.
String? prepareBench(String mode, AppState state, {int? size}) {
  switch (mode) {
    case 'drag':
    case 'startup':
      return state.generate(50, 50);
    case 'render':
      state.showMoment = true;
      state.colorByMoment = true;
      return state.generate(size ?? 200, size ?? 200);
    default:
      return null;
  }
}

String describe() => kIsWasm ? 'dart2wasm' : 'dart2js/native';

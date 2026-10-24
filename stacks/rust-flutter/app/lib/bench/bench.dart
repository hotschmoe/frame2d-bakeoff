/// Benchmark modes (SPEC 5.5): drag, render, startup, ready, boundary.
///
/// Desktop: `--bench=<mode>`; web: `?bench=<mode>`. Results are `BENCH {json}` lines.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';

import '../state/app_state.dart';
import 'bench_platform.dart';

/// The requested bench mode from command-line arguments or the page URL, if any.
String? benchModeFrom(List<String> args) {
  for (final a in args) {
    if (a.startsWith('--bench=')) return a.substring('--bench='.length);
  }
  final q = Uri.base.queryParameters['bench'];
  return (q == null || q.isEmpty) ? null : q;
}

void _emit(Map<String, Object?> result) => benchPrint('BENCH ${jsonEncode(result)}');

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final i = (p / 100 * sorted.length).ceil() - 1;
  return sorted[i.clamp(0, sorted.length - 1)];
}

double _round(double v) => (v * 1000).roundToDouble() / 1000;

Map<String, Object?> _frameSummary(String mode, List<double> frames, List<double> solves, int lagMax) {
  final f = List<double>.of(frames)..sort();
  final s = List<double>.of(solves)..sort();
  return {
    'mode': mode,
    'p50': _round(_percentile(f, 50)),
    'p95': _round(_percentile(f, 95)),
    'p99': _round(_percentile(f, 99)),
    'max': _round(f.isEmpty ? 0 : f.last),
    'solve_p50': _round(_percentile(s, 50)),
    'lag_max': lagMax,
    'rss_mb': rssMb() == null ? null : _round(rssMb()!),
  };
}

Future<void> _nextFrame() => SchedulerBinding.instance.endOfFrame;

/// Frame count override for quick local runs (`--frames=60` / `?frames=60`); the spec value is 600.
int benchFrames(List<String> args, {int fallback = 600}) {
  for (final a in args) {
    if (a.startsWith('--frames=')) return int.tryParse(a.substring('--frames='.length)) ?? fallback;
  }
  return int.tryParse(Uri.base.queryParameters['frames'] ?? '') ?? fallback;
}

Future<void> runBench(String mode, AppState state, {int frames = 600}) async {
  try {
    switch (mode) {
      case 'ready':
        await _nextFrame();
        _emit({'mode': 'ready', 'tti_ms': _round(msSinceStart())});
      case 'startup':
        await _startup(state);
      case 'drag':
        await _drag(state, frames);
      case 'render':
        await _render(state, frames);
      case 'boundary':
        await _boundary(state);
      default:
        benchPrint('BENCH {"mode":"$mode","error":"unknown bench mode"}');
    }
  } catch (e, st) {
    benchPrint('BENCH {"mode":"$mode","error":${jsonEncode('$e')}}');
    benchPrint('$st');
  }
  await benchFinish();
}

Future<void> _startup(AppState state) async {
  await state.generate(50, 50);
  _requireOk(state);
  await _nextFrame();
  await _nextFrame();
  _emit({'mode': 'startup', 'first_frame_ms': _round(msSinceStart())});
}

void _requireOk(AppState state) {
  if (state.error != null) throw StateError(state.error!);
}

Future<void> _drag(AppState state, int frames) async {
  const bays = 50, stories = 50;
  await state.generate(bays, stories);
  _requireOk(state);
  final m = state.model!;
  final nodeId = stories * (bays + 1) + bays ~/ 2 + 1;
  final pos = m.nodeIds.indexOf(nodeId);
  final x0 = m.nodeXy[pos * 2], y0 = m.nodeXy[pos * 2 + 1];
  state.selectedNode = pos;
  await _nextFrame();
  await _nextFrame();

  final frameMs = <double>[], solveMs = <double>[];
  var lagMax = 0;
  final clock = Stopwatch()..start();
  var last = clock.elapsedMicroseconds;
  for (var k = 0; k < frames; k++) {
    final angle = 2 * math.pi * k / frames;
    final issuedAt = state.paintCount;
    final s = await state.solveMove(pos, x0 + 0.5 * math.cos(angle), y0 + 0.5 * math.sin(angle));
    final lag = state.paintCount - issuedAt; // frames drawn while the result was pending
    await _nextFrame();
    final now = clock.elapsedMicroseconds;
    frameMs.add((now - last) / 1000);
    last = now;
    solveMs.add(s.engineMs);
    lagMax = math.max(lagMax, lag);
  }
  _emit(_frameSummary('drag', frameMs, solveMs, lagMax));
}

Future<void> _render(AppState state, int frames) async {
  state.toggle(deflected: false, moment: true, color: true);
  await state.generate(200, 200);
  _requireOk(state);
  final engineMs = state.solution!.engineMs;
  await _nextFrame();
  await _nextFrame();

  final b = state.bounds();
  final view = state.view;
  final base = view.zoom; // "1x" is the fit-to-window zoom
  final cy = (b.top + b.bottom) / 2;
  final size = state.canvasSize;
  final frameMs = <double>[];
  final clock = Stopwatch()..start();
  var last = clock.elapsedMicroseconds;
  for (var k = 0; k < frames; k++) {
    final t = k / (frames - 1);
    final zoomFactor = 1 + 7 * (1 - (2 * t - 1).abs()); // 1x -> 8x -> 1x
    view.zoom = base * zoomFactor;
    final cx = b.left + t * (b.right - b.left); // pan across the full width
    view.ox = size.width / 2 - cx * view.zoom;
    view.oy = size.height / 2 + cy * view.zoom;
    state.repaint();
    await _nextFrame();
    final now = clock.elapsedMicroseconds;
    frameMs.add((now - last) / 1000);
    last = now;
  }
  _emit(_frameSummary('render', frameMs, [engineMs], 0));
}

Future<void> _boundary(AppState state) async {
  final engine = state.engine;
  const noopCalls = 1000000, echoCalls = 1000, echoN = 38103;
  for (var i = 0; i < 10000; i++) {
    engine.noop();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < noopCalls; i++) {
    engine.noop();
  }
  final noopNs = sw.elapsedMicroseconds * 1000 / noopCalls;

  var check = 0.0;
  for (var i = 0; i < 20; i++) {
    check += engine.echo(echoN).last;
  }
  sw
    ..reset()
    ..start();
  Float64List data = Float64List(0);
  for (var i = 0; i < echoCalls; i++) {
    data = engine.echo(echoN);
    check += data[data.length - 1];
  }
  final transferUs = sw.elapsedMicroseconds / echoCalls;
  if (data.length != echoN || check < 0) throw StateError('echo returned ${data.length} values');
  _emit({
    'mode': 'boundary',
    'noop_ns': _round(noopNs),
    'transfer_us': _round(transferUs),
    'mechanism': engine.mechanism,
  });
}

import 'dart:typed_data';

import 'engine_stub.dart'
    if (dart.library.js_interop) 'engine_web.dart'
    if (dart.library.ffi) 'engine_native.dart' as impl;

/// Timings and sizes of the last solve, as reported by the engine.
class SolveStats {
  const SolveStats({
    required this.assembleMs,
    required this.factorMs,
    required this.solveMs,
    required this.freeDofs,
    required this.profileBefore,
    required this.profileAfter,
  });

  final double assembleMs;
  final double factorMs;
  final double solveMs;
  final int freeDofs;
  final int profileBefore;
  final int profileAfter;

  static const empty = SolveStats(
    assembleMs: 0,
    factorMs: 0,
    solveMs: 0,
    freeDofs: 0,
    profileBefore: 0,
    profileAfter: 0,
  );
}

/// The analysis engine (Zig). Native builds reach it through dart:ffi, web builds through a WASM module.
///
/// Every array returned here is Dart-owned (a copy), never a view onto engine memory, so it stays intact
/// whatever the engine does next (reload, export, WASM memory growth). Geometry lists are replaced on every
/// load; [nodeXy] is kept current by [setNodeXY]. Result getters copy into [into] when it has the right
/// length (pass the list from the previous call: no allocation per solve), else into a new list.
/// The buffer contract with the engine is described in docs/zig-dart-bridge.md 2.5 and engine_core.dart.
abstract class FrameEngine {
  /// Short description of the bridge, e.g. `ffi` or `wasm`.
  String get backend;

  /// Loads a model. Returns null on success or a human readable error.
  String? loadJson(String text);

  /// Generates the B x S moment frame (SPEC 4.8). Returns null on success or an error.
  String? generate(int bays, int stories);

  int get nodeCount;
  int get memberCount;
  int get caseCount;
  String caseName(int k);

  Int32List get nodeIds;

  /// x0, y0, x1, y1, ...; [setNodeXY] keeps it current.
  Float64List get nodeXy;

  /// Per node bit mask: 1 = ux, 2 = uy, 4 = rz restrained.
  Uint8List get nodeRestraint;
  Int32List get memberIds;

  /// Node indices i0, j0, i1, j1, ...
  Uint32List get memberEnds;
  Float64List get memberLength;

  void setNodeXY(int index, double x, double y);

  /// Solves the load cases in [mask] (bit k = case k). Returns null on success or an error.
  String? solve(int mask);
  SolveStats get stats;

  /// Per case results (copies), null when the case was not solved.
  Float64List? displacements(int k, {Float64List? into});
  Float64List? endForces(int k, {Float64List? into});
  Float64List? maxMoment(int k, {Float64List? into});

  /// members * 11 bending moments along each member.
  Float64List? stationMoments(int k, {Float64List? into});
  double residual(int k);

  /// Current model as JSON text.
  String exportModelJson();

  /// Results of the solved cases as JSON text (SPEC results format).
  String exportResultsJson();

  /// The engine's buffer generation (bumps whenever engine memory a view could point at was freed, moved or,
  /// on web, grown). Diagnostics and tests; callers never hold views, so they need not check it.
  int get generation;

  /// Milliseconds since process start (desktop) or navigation start (web).
  double sinceStartMs();

  // Boundary probes (SPEC 5.5).
  void noop();

  /// A transient view (not a copy): valid only until the next engine call.
  Float64List echo(int n);

  /// How [echo] results reach Dart: `zero-copy view` or `memcpy`.
  String get transferMechanism;

  static Future<FrameEngine> create() => impl.createEngine();
}

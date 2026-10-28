import 'dart:convert';
import 'dart:typed_data';

import 'frame_engine.dart';

/// The engine's published buffers; one `f2d_xxx(..., out)` slice getter each (src/bridge/exports.zig).
enum Buf {
  error,
  nodeIds,
  nodeXy,
  restraint,
  memberIds,
  memberEnds,
  memberLen,
  caseName,
  stats,
  disp,
  endForces,
  maxM,
  stationsM,
  exportModel,
  exportResults,
}

class _View {
  _View(this.k, this.gen, this.list);
  final int k;
  final int gen;
  final TypedData list;
}

/// Backend-independent half of the bridge. Implements the buffer contract of docs/zig-dart-bridge.md 2.5:
///
/// - the engine returns address + length + generation together ([fetchSlice]);
/// - views over engine memory are cached per buffer and reused only while [generation] is unchanged
///   (native: the engine counter; web: the engine counter and the identity of `memory.buffer`), otherwise
///   they are fetched again;
/// - nothing handed to callers is a view: geometry is copied once per model, results are copied with
///   `setRange` into Dart-owned lists the caller passes back in (no allocation in steady state), strings
///   are decoded immediately. Engine memory can grow, move or be freed without affecting held data.
abstract class EngineCore implements FrameEngine {
  // ---- backend primitives ----

  /// Calls the slice getter of [b] (case or index [k]) and stores the result; returns the status.
  /// [slicePtr] / [sliceLen] / [sliceGen] describe the slice until the next fetch.
  int fetchSlice(Buf b, int k);
  int get slicePtr;
  int get sliceLen;
  int get sliceGen;

  /// Transient typed views over engine memory (never returned to callers).
  Float64List viewF64(int ptr, int n);
  Int32List viewI32(int ptr, int n);
  Uint32List viewU32(int ptr, int n);
  Uint8List viewU8(int ptr, int n);

  int rawLoadJson(Uint8List bytes);
  int rawGenerate(int bays, int stories);
  int rawSolve(int mask);
  void rawSetNodeXY(int index, double x, double y);
  int rawEcho(int n);

  // ---- views, re-fetched when the generation moved ----

  final List<_View?> _views = List<_View?>.filled(Buf.values.length, null);

  TypedData? _view(Buf b, int k, TypedData Function(int ptr, int n) make) {
    final c = _views[b.index];
    if (c != null && c.k == k && c.gen == generation) return c.list;
    if (fetchSlice(b, k) != 0) {
      _views[b.index] = null;
      return null;
    }
    final v = make(slicePtr, sliceLen);
    _views[b.index] = _View(k, generation, v);
    return v;
  }

  Float64List? _f64(Buf b, [int k = 0]) => _view(b, k, viewF64) as Float64List?;

  /// Copies a buffer into [into] when it has the right length, else into a new list.
  Float64List? _copyOut(Buf b, int k, Float64List? into) {
    final v = _f64(b, k);
    if (v == null) return null;
    final dst = (into != null && into.length == v.length) ? into : Float64List(v.length);
    dst.setRange(0, v.length, v);
    return dst;
  }

  /// UTF-8 text slices (errors, case names, JSON exports) are decoded right away.
  String _text(Buf b, [int k = 0]) {
    if (fetchSlice(b, k) != 0) return '';
    return utf8.decode(viewU8(slicePtr, sliceLen));
  }

  // ---- geometry: Dart-owned copies, replaced (never mutated) on a new model ----

  Int32List _nodeIds = Int32List(0);
  Float64List _nodeXy = Float64List(0);
  Uint8List _restraint = Uint8List(0);
  Int32List _memberIds = Int32List(0);
  Uint32List _memberEnds = Uint32List(0);
  Float64List _memberLen = Float64List(0);
  bool _lengthsStale = false;

  T _copyGeometry<T>(Buf b, T Function(TypedData v) copy, TypedData Function(int ptr, int n) make, T empty) {
    final v = _view(b, 0, make);
    return v == null ? empty : copy(v);
  }

  void _refreshGeometry() {
    _nodeIds = _copyGeometry(Buf.nodeIds, (v) => Int32List.fromList(v as Int32List), viewI32, Int32List(0));
    _nodeXy = _copyGeometry(Buf.nodeXy, (v) => Float64List.fromList(v as Float64List), viewF64, Float64List(0));
    _restraint = _copyGeometry(Buf.restraint, (v) => Uint8List.fromList(v as Uint8List), viewU8, Uint8List(0));
    _memberIds = _copyGeometry(Buf.memberIds, (v) => Int32List.fromList(v as Int32List), viewI32, Int32List(0));
    _memberEnds = _copyGeometry(Buf.memberEnds, (v) => Uint32List.fromList(v as Uint32List), viewU32, Uint32List(0));
    _memberLen = _copyGeometry(Buf.memberLen, (v) => Float64List.fromList(v as Float64List), viewF64, Float64List(0));
    _lengthsStale = false;
  }

  String? _status(int code) {
    switch (code) {
      case 0:
        return null;
      case 1:
        final e = _text(Buf.error);
        return e.isEmpty ? 'model error' : e;
      case 2:
        return 'out of memory';
      default:
        return 'no model loaded';
    }
  }

  String? _afterLoad(int code) {
    final err = _status(code);
    if (err == null) _refreshGeometry();
    return err;
  }

  @override
  String? loadJson(String text) => _afterLoad(rawLoadJson(utf8.encode(text)));

  @override
  String? generate(int bays, int stories) => _afterLoad(rawGenerate(bays, stories));

  @override
  String caseName(int k) => _text(Buf.caseName, k);

  @override
  Int32List get nodeIds => _nodeIds;
  @override
  Float64List get nodeXy => _nodeXy;
  @override
  Uint8List get nodeRestraint => _restraint;
  @override
  Int32List get memberIds => _memberIds;
  @override
  Uint32List get memberEnds => _memberEnds;

  @override
  Float64List get memberLength {
    if (_lengthsStale) {
      final v = _f64(Buf.memberLen);
      if (v != null && v.length == _memberLen.length) _memberLen.setRange(0, v.length, v);
      _lengthsStale = false;
    }
    return _memberLen;
  }

  @override
  void setNodeXY(int index, double x, double y) {
    if (index < 0 || index * 2 + 1 >= _nodeXy.length) return;
    _nodeXy[index * 2] = x;
    _nodeXy[index * 2 + 1] = y;
    rawSetNodeXY(index, x, y);
    _lengthsStale = true;
  }

  @override
  String? solve(int mask) => _status(rawSolve(mask));

  @override
  SolveStats get stats {
    final s = _f64(Buf.stats);
    if (s == null || s.length < 6) return SolveStats.empty;
    return SolveStats(
      assembleMs: s[0],
      factorMs: s[1],
      solveMs: s[2],
      freeDofs: s[3].toInt(),
      profileBefore: s[4].toInt(),
      profileAfter: s[5].toInt(),
    );
  }

  @override
  Float64List? displacements(int k, {Float64List? into}) => _copyOut(Buf.disp, k, into);
  @override
  Float64List? endForces(int k, {Float64List? into}) => _copyOut(Buf.endForces, k, into);
  @override
  Float64List? maxMoment(int k, {Float64List? into}) => _copyOut(Buf.maxM, k, into);
  @override
  Float64List? stationMoments(int k, {Float64List? into}) => _copyOut(Buf.stationsM, k, into);

  @override
  String exportModelJson() => _text(Buf.exportModel);
  @override
  String exportResultsJson() => _text(Buf.exportResults);

  @override
  Float64List echo(int n) => viewF64(rawEcho(n), n);
}

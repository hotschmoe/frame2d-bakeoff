import 'dart:typed_data';

import 'engine_stub.dart'
    if (dart.library.ffi) 'engine_ffi.dart'
    if (dart.library.js_interop) 'engine_web.dart' as impl;

/// Layout constants shared with the Zig session API (zig/src/session.zig).
class Layout {
  static const nodeStride = 4; // id, x, y, restraint bitmask
  static const memberStride = 3; // id, node index i, node index j
  static const resMember = 18; // 6 end forces, max |M|, 11 M stations
  static const statCount = 7;

  static int geometryLength(int nodes, int members) => nodes * nodeStride + members * memberStride;
  static int resultLength(int nodes, int members) => nodes * 3 + members * resMember;
}

/// Thin typed view of the Zig engine bridge. All analysis happens behind this interface.
abstract class Engine {
  /// Creates the platform engine: dart:ffi on desktop, Zig wasm32 module on web.
  static Future<Engine> create() => impl.createEngine();

  /// "zero-copy view" (desktop) or "memcpy" (web): how result buffers cross the boundary.
  String get mechanism;

  void noop();

  /// Boundary benchmark only. Native: a zero-copy view of the engine's echo buffer, valid until the next echo call
  /// (which may reallocate it); do not keep it.
  Float64List echo(int n);
  double processAgeMs();

  /// Returns a handle (> 0) or a negative error code; see [lastError].
  int loadJson(String json);
  int gen(int bays, int stories);
  void free(int h);
  String lastError();
  /// All zero for a dead (freed) handle.
  (int nodes, int members, int cases) counts(int h);

  // Lifetime rule: nothing returned below is a view into engine memory. Native session buffers live only until
  // free(h) and are overwritten by the next solve; web views detach whenever wasm memory grows. So what the UI keeps
  // across calls is always a Dart-owned list. A dead handle yields an empty list / leaves dst untouched.

  /// Dart-owned copy of the session geometry (allocated once per model).
  Float64List geometry(int h);

  /// Latest results of [h], as a list the caller may keep: native copies into [dst] (no allocation; reuse it on every
  /// solve) and returns it; web returns the fresh copy the loader already made. [dst] must hold resultLength(h).
  Float64List resultInto(int h, Float64List dst);

  /// Same contract as [resultInto] for the [Layout.statCount] solve statistics.
  Float64List statsInto(int h, Float64List dst);
  List<String> caseIds(int h);
  void setNode(int h, int index, double x, double y);
  int solve(int h, int caseIndex);
  String toJson(int h);
}

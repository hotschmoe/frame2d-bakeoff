import 'dart:typed_data';

import 'engine_stub.dart'
    if (dart.library.ffi) 'engine_ffi.dart'
    if (dart.library.js_interop) 'engine_web.dart' as impl;

/// Layout constants shared with the Go session package (bridge/session).
class Layout {
  static const nodeStride = 4; // id, x, y, restraint bitmask
  static const memberStride = 3; // id, node index i, node index j
  static const resMember = 18; // 6 end forces, max |M|, 11 M stations
  static const statCount = 7;
}

/// Thin typed view of the Go engine bridge. All analysis happens behind this interface.
abstract class Engine {
  /// Creates the platform engine: dart:ffi on desktop, Go js/wasm on web.
  static Future<Engine> create() => impl.createEngine();

  /// "zero-copy view" (desktop) or "memcpy" (web): how result buffers cross the boundary.
  String get mechanism;

  void noop();
  Float64List echo(int n);
  double processAgeMs();

  /// Returns a handle (> 0) or a negative error code; see [lastError].
  int loadJson(String json);
  int gen(int bays, int stories);
  void free(int h);
  String lastError();
  (int nodes, int members, int cases) counts(int h);
  Float64List geometry(int h, int length);
  Float64List result(int h, int length);
  Float64List stats(int h);
  List<String> caseIds(int h);
  void setNode(int h, int index, double x, double y);
  int solve(int h, int caseIndex);
  String toJson(int h);
}

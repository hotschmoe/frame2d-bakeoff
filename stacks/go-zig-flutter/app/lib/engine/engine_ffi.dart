import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../generated/engine_bindings.dart';
import 'engine.dart';

Future<Engine> createEngine() async => FfiEngine();

/// dart:ffi bridge to the Zig shared library. Results are copied (setRange, a few us for 38k doubles) out of the
/// session-owned Zig buffers into Dart-owned lists the caller reuses, so no view into engine memory outlives a call.
/// Every read is sized from f2d_counts of the same handle, and a dead handle (pointer null, counts zero) reads nothing.
class FfiEngine implements Engine {
  /// [libPath] overrides the library lookup (tests load build/dev directly).
  FfiEngine([String? libPath]) : _b = EngineBindings(ffi.DynamicLibrary.open(libPath ?? _libName()));
  final EngineBindings _b;
  // out-parameter scratch, allocated once for the engine's lifetime (no per-call malloc on the solve path)
  final ffi.Pointer<ffi.Int> _cnt = malloc<ffi.Int>(3);

  static String _libName() {
    if (Platform.isWindows) return 'frame2d_engine.dll';
    if (Platform.isMacOS) return 'libframe2d_engine.dylib';
    return 'libframe2d_engine.so';
  }

  @override
  String get mechanism => 'zero-copy view';

  @override
  void noop() => _b.f2d_noop();

  @override
  Float64List echo(int n) => _b.f2d_echo(n).cast<ffi.Double>().asTypedList(n);

  @override
  double processAgeMs() => _b.f2d_process_age_ms();

  @override
  int loadJson(String json) {
    final bytes = utf8.encode(json);
    final p = malloc<ffi.Uint8>(bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      return _b.f2d_load_json(p.cast(), bytes.length);
    } finally {
      malloc.free(p);
    }
  }

  @override
  int gen(int bays, int stories) => _b.f2d_gen(bays, stories);

  @override
  void free(int h) => _b.f2d_free(h);

  @override
  String lastError() => _b.f2d_last_error().cast<Utf8>().toDartString();

  @override
  (int, int, int) counts(int h) {
    _b.f2d_counts(h, _cnt);
    return (_cnt[0], _cnt[1], _cnt[2]);
  }

  @override
  Float64List geometry(int h) {
    final (n, m, _) = counts(h);
    final p = _b.f2d_geometry(h);
    if (p == ffi.nullptr) return Float64List(0);
    final len = Layout.geometryLength(n, m);
    return Float64List(len)..setRange(0, len, p.cast<ffi.Double>().asTypedList(len));
  }

  @override
  Float64List resultInto(int h, Float64List dst) {
    final (n, m, _) = counts(h);
    final p = _b.f2d_result(h);
    final len = Layout.resultLength(n, m);
    if (p != ffi.nullptr && len <= dst.length) dst.setRange(0, len, p.cast<ffi.Double>().asTypedList(len));
    return dst;
  }

  @override
  Float64List statsInto(int h, Float64List dst) {
    final p = _b.f2d_stats(h);
    if (p != ffi.nullptr) dst.setRange(0, Layout.statCount, p.cast<ffi.Double>().asTypedList(Layout.statCount));
    return dst;
  }

  @override
  List<String> caseIds(int h) {
    var cap = 1024;
    while (true) {
      final buf = malloc<ffi.Char>(cap);
      try {
        final n = _b.f2d_case_ids(h, buf, cap);
        if (n + 1 > cap) {
          cap = n + 1; // too small: the engine reported the needed length
          continue;
        }
        if (n <= 0) return const [];
        return (jsonDecode(buf.cast<Utf8>().toDartString(length: n)) as List).cast<String>();
      } finally {
        malloc.free(buf);
      }
    }
  }

  @override
  void setNode(int h, int index, double x, double y) => _b.f2d_set_node(h, index, x, y);

  @override
  int solve(int h, int caseIndex) => _b.f2d_solve(h, caseIndex);

  @override
  String toJson(int h) {
    final len = malloc<ffi.Int>(1);
    try {
      // pointer and length come back from one call; decode (copy) before any other engine call
      final p = _b.f2d_to_json(h, len);
      if (p == ffi.nullptr) return '';
      return utf8.decode(p.cast<ffi.Uint8>().asTypedList(len[0]));
    } finally {
      malloc.free(len);
    }
  }
}

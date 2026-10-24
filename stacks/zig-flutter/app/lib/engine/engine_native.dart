import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';


import '../generated/frame2d_bindings.dart';
import 'frame_engine.dart';

/// Desktop bridge: dart:ffi calls into frame2d_engine.dll (or .so/.dylib) next to the executable.
/// Result arrays are zero-copy views over the engine's memory.
Future<FrameEngine> createEngine() async {
  final dir = File(Platform.resolvedExecutable).parent.path;
  final name = Platform.isWindows
      ? 'frame2d_engine.dll'
      : Platform.isMacOS
          ? 'libframe2d_engine.dylib'
          : 'libframe2d_engine.so';
  final lib = ffi.DynamicLibrary.open('$dir${Platform.pathSeparator}$name');
  return NativeEngine(Frame2dBindings(lib));
}

class NativeEngine implements FrameEngine {
  NativeEngine(this._b);

  final Frame2dBindings _b;

  @override
  String get backend => 'ffi';

  @override
  String get transferMechanism => 'zero-copy view';

  String _lastError() {
    final n = _b.f2d_error_len();
    return utf8.decode(_b.f2d_error_ptr().asTypedList(n));
  }

  String? _status(int code) {
    switch (code) {
      case 0:
        return null;
      case 1:
        return _lastError();
      case 2:
        return 'out of memory';
      default:
        return 'no model loaded';
    }
  }

  @override
  String? loadJson(String text) {
    final bytes = utf8.encode(text);
    final buf = _b.f2d_alloc(bytes.length);
    if (buf == ffi.nullptr) return 'out of memory';
    buf.asTypedList(bytes.length).setAll(0, bytes);
    final code = _b.f2d_load_json(buf, bytes.length);
    _b.f2d_free(buf, bytes.length);
    return _status(code);
  }

  @override
  String? generate(int bays, int stories) => _status(_b.f2d_generate(bays, stories));

  @override
  int get nodeCount => _b.f2d_node_count();
  @override
  int get memberCount => _b.f2d_member_count();
  @override
  int get caseCount => _b.f2d_case_count();

  @override
  String caseName(int k) => utf8.decode(_b.f2d_case_name_ptr(k).asTypedList(_b.f2d_case_name_len(k)));

  @override
  Int32List get nodeIds => _b.f2d_node_ids().asTypedList(nodeCount);
  @override
  Float64List get nodeXy => _b.f2d_node_xy().asTypedList(nodeCount * 2);
  @override
  Uint8List get nodeRestraint => _b.f2d_node_restraint().asTypedList(nodeCount);
  @override
  Int32List get memberIds => _b.f2d_member_ids().asTypedList(memberCount);
  @override
  Uint32List get memberEnds => _b.f2d_member_ends().asTypedList(memberCount * 2);
  @override
  Float64List get memberLength => _b.f2d_member_len().asTypedList(memberCount);

  @override
  void setNodeXY(int index, double x, double y) => _b.f2d_set_node_xy(index, x, y);

  @override
  String? solve(int mask) => _status(_b.f2d_solve(mask));

  @override
  SolveStats get stats {
    final s = _b.f2d_stats().asTypedList(6);
    return SolveStats(
      assembleMs: s[0],
      factorMs: s[1],
      solveMs: s[2],
      freeDofs: s[3].toInt(),
      profileBefore: s[4].toInt(),
      profileAfter: s[5].toInt(),
    );
  }

  Float64List? _view(ffi.Pointer<ffi.Double> p, int n) => p == ffi.nullptr ? null : p.asTypedList(n);

  @override
  Float64List? displacements(int k) => _view(_b.f2d_disp(k), nodeCount * 3);
  @override
  Float64List? endForces(int k) => _view(_b.f2d_end_forces(k), memberCount * 6);
  @override
  Float64List? maxMoment(int k) => _view(_b.f2d_max_m(k), memberCount);
  @override
  Float64List? stationMoments(int k) => _view(_b.f2d_stations_m(k), memberCount * 11);
  @override
  double residual(int k) => _b.f2d_residual(k);

  @override
  String exportModelJson() {
    final n = _b.f2d_export_model();
    return utf8.decode(_b.f2d_out_ptr().asTypedList(n));
  }

  @override
  double sinceStartMs() {
    final t = _b.f2d_process_uptime_ms();
    return t >= 0 ? t : _fallback.elapsedMicroseconds / 1000.0;
  }

  static final Stopwatch _fallback = Stopwatch()..start();

  @override
  void noop() => _b.f2d_noop();

  @override
  Float64List echo(int n) => _b.f2d_echo(n).asTypedList(n);
}

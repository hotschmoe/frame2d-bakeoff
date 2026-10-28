import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import '../generated/frame2d_bindings.dart';
import 'engine_core.dart';
import 'frame_engine.dart';

/// Desktop bridge: dart:ffi calls into frame2d_engine.dll (or .so/.dylib) next to the executable.
Future<FrameEngine> createEngine() async {
  final dir = File(Platform.resolvedExecutable).parent.path;
  return openNativeEngine('$dir${Platform.pathSeparator}$engineLibraryName');
}

String get engineLibraryName => Platform.isWindows
    ? 'frame2d_engine.dll'
    : Platform.isMacOS
        ? 'libframe2d_engine.dylib'
        : 'libframe2d_engine.so';

/// Opens the engine library at [path] (tests load the one built by `zig build bridge-test-libs`).
FrameEngine openNativeEngine(String path) => NativeEngine(Frame2dBindings(ffi.DynamicLibrary.open(path)));

class NativeEngine extends EngineCore {
  NativeEngine(this._b) {
    // One out-slot for every slice getter, allocated once (8-byte aligned, lives as long as the engine).
    final raw = _b.f2d_alloc(ffi.sizeOf<f2d_slice>() + 8);
    if (raw == ffi.nullptr) throw StateError('engine: out of memory');
    _slotPtr = ffi.Pointer<f2d_slice>.fromAddress((raw.address + 7) & ~7);
    _slot = _slotPtr.ref;
  }

  final Frame2dBindings _b;
  late final ffi.Pointer<f2d_slice> _slotPtr;
  late final f2d_slice _slot;

  @override
  String get backend => 'ffi';

  @override
  String get transferMechanism => 'zero-copy view';

  @override
  int get generation => _b.f2d_generation();

  @override
  int fetchSlice(Buf b, int k) {
    final o = _slotPtr;
    return switch (b) {
      Buf.error => _b.f2d_error(o),
      Buf.nodeIds => _b.f2d_node_ids(o),
      Buf.nodeXy => _b.f2d_node_xy(o),
      Buf.restraint => _b.f2d_node_restraint(o),
      Buf.memberIds => _b.f2d_member_ids(o),
      Buf.memberEnds => _b.f2d_member_ends(o),
      Buf.memberLen => _b.f2d_member_len(o),
      Buf.caseName => _b.f2d_case_name(k, o),
      Buf.stats => _b.f2d_stats(o),
      Buf.disp => _b.f2d_disp(k, o),
      Buf.endForces => _b.f2d_end_forces(k, o),
      Buf.maxM => _b.f2d_max_m(k, o),
      Buf.stationsM => _b.f2d_stations_m(k, o),
      Buf.exportModel => _b.f2d_export_model(o),
      Buf.exportResults => _b.f2d_export_results(o),
    };
  }

  @override
  int get slicePtr => _slot.ptr;
  @override
  int get sliceLen => _slot.len;
  @override
  int get sliceGen => _slot.gen;

  // asTypedList on a null pointer throws, and an empty slice may carry address 0.
  @override
  Float64List viewF64(int ptr, int n) =>
      n == 0 ? Float64List(0) : ffi.Pointer<ffi.Double>.fromAddress(ptr).asTypedList(n);
  @override
  Int32List viewI32(int ptr, int n) =>
      n == 0 ? Int32List(0) : ffi.Pointer<ffi.Int32>.fromAddress(ptr).asTypedList(n);
  @override
  Uint32List viewU32(int ptr, int n) =>
      n == 0 ? Uint32List(0) : ffi.Pointer<ffi.Uint32>.fromAddress(ptr).asTypedList(n);
  @override
  Uint8List viewU8(int ptr, int n) =>
      n == 0 ? Uint8List(0) : ffi.Pointer<ffi.Uint8>.fromAddress(ptr).asTypedList(n);

  @override
  int rawLoadJson(Uint8List bytes) {
    final n = bytes.length;
    final buf = _b.f2d_alloc(n == 0 ? 1 : n);
    if (buf == ffi.nullptr) return 2;
    buf.asTypedList(n).setAll(0, bytes);
    final code = _b.f2d_load_json(buf, n);
    _b.f2d_free(buf, n == 0 ? 1 : n);
    return code;
  }

  @override
  int rawGenerate(int bays, int stories) => _b.f2d_generate(bays, stories);
  @override
  int rawSolve(int mask) => _b.f2d_solve(mask);
  @override
  void rawSetNodeXY(int index, double x, double y) => _b.f2d_set_node_xy(index, x, y);
  @override
  int rawEcho(int n) => _b.f2d_echo(n).address;

  @override
  int get nodeCount => _b.f2d_node_count();
  @override
  int get memberCount => _b.f2d_member_count();
  @override
  int get caseCount => _b.f2d_case_count();
  @override
  double residual(int k) => _b.f2d_residual(k);

  @override
  double sinceStartMs() {
    final t = _b.f2d_process_uptime_ms();
    return t >= 0 ? t : _fallback.elapsedMicroseconds / 1000.0;
  }

  static final Stopwatch _fallback = Stopwatch()..start();

  @override
  void noop() => _b.f2d_noop();
}

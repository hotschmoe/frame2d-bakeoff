// ignore_for_file: non_constant_identifier_names, library_private_types_in_public_api
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'engine_core.dart';
import 'frame_engine.dart';

/// Same constant as Flutter's kIsWasm; spelled out so this file also compiles without Flutter (the
/// node-based bridge test in test_web/ builds it with plain `dart compile js|wasm`).
const bool _isDart2Wasm = bool.fromEnvironment('dart.tool.dart2wasm');

@JS('fetch')
external JSPromise<JSObject> _fetch(String url);

@JS('performance')
external _Performance get _performance;

extension type _Performance._(JSObject _) implements JSObject {
  external double now();
}

@JS('WebAssembly.instantiateStreaming')
external JSPromise<JSObject> _instantiateStreaming(JSPromise<JSObject> response, JSObject imports);

@JS('WebAssembly.instantiate')
external JSPromise<JSObject> _instantiate(JSAny bytes, JSObject imports);

extension type _Response._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('Float64Array')
extension type _F64._(JSFloat64Array _) implements JSFloat64Array {
  external factory _F64(JSArrayBuffer b, int off, int len);
}

@JS('Int32Array')
extension type _I32._(JSInt32Array _) implements JSInt32Array {
  external factory _I32(JSArrayBuffer b, int off, int len);
}

@JS('Uint32Array')
extension type _U32._(JSUint32Array _) implements JSUint32Array {
  external factory _U32(JSArrayBuffer b, int off, int len);
}

@JS('Uint8Array')
extension type _U8._(JSUint8Array _) implements JSUint8Array {
  external factory _U8(JSArrayBuffer b, int off, int len);
}

/// The exported C ABI of frame2d_engine.wasm (src/bridge/exports.zig). `out` is the address of an
/// f2d_slice (wasm32: u32 ptr, u32 len, u32 gen, u32 pad).
extension type _Exports._(JSObject _) implements JSObject {
  external JSObject get memory;
  external void f2d_noop();
  external int f2d_echo(int n);
  external int f2d_generation();
  external int f2d_alloc(int n);
  external void f2d_free(int p, int n);
  external int f2d_load_json(int p, int len);
  external int f2d_generate(int bays, int stories);
  external int f2d_error(int out);
  external int f2d_node_count();
  external int f2d_member_count();
  external int f2d_case_count();
  external int f2d_node_ids(int out);
  external int f2d_node_xy(int out);
  external int f2d_node_restraint(int out);
  external int f2d_member_ids(int out);
  external int f2d_member_ends(int out);
  external int f2d_member_len(int out);
  external int f2d_case_name(int k, int out);
  external void f2d_set_node_xy(int idx, double x, double y);
  external int f2d_solve(int mask);
  external int f2d_stats(int out);
  external int f2d_disp(int k, int out);
  external int f2d_end_forces(int k, int out);
  external int f2d_max_m(int k, int out);
  external int f2d_stations_m(int k, int out);
  external double f2d_residual(int k);
  external int f2d_export_model(int out);
  external int f2d_export_results(int out);
}

/// Web bridge: the Zig engine compiled to wasm32, called through dart:js_interop.
Future<FrameEngine> createEngine() async {
  final url = Uri.base.resolve('frame2d_engine.wasm').toString();
  final imports = engineImports();
  JSObject result;
  try {
    result = await _instantiateStreaming(_fetch(url), imports).toDart;
  } catch (_) {
    // Servers that do not send application/wasm: compile from bytes instead.
    final response = _Response._(await _fetch(url).toDart);
    result = await _instantiate(await response.arrayBuffer().toDart, imports).toDart;
  }
  final instance = result['instance'] as JSObject;
  return WebEngine.fromExports(instance['exports'] as JSObject);
}

/// The import object the engine module needs.
JSObject engineImports() {
  final env = JSObject()..['f2d_now_ms'] = (() => _performance.now()).toJS;
  return JSObject()..['env'] = env;
}

/// Views under dart2js are zero-copy JS typed arrays; under dart2wasm `toDart` wraps the JS view (reads go
/// through JS). Both detach when the module grows its memory: [generation] tracks `memory.buffer` identity
/// on top of the engine counter, and nothing outlives a call except Dart-owned copies (EngineCore).
class WebEngine extends EngineCore {
  WebEngine.fromExports(JSObject exports) : _x = _Exports._(exports) {
    final raw = _x.f2d_alloc(16 + 8);
    if (raw == 0) throw StateError('engine: out of memory');
    _slotAddr = (raw + 7) & ~7;
    _sync();
  }

  final _Exports _x;
  late final int _slotAddr;
  JSArrayBuffer? _buf;
  Uint32List _slotView = Uint32List(0);
  int _bufEpoch = 0;

  int _lastEngineGen = -1;
  int _lastBufEpoch = -1;
  int _gen = 0;

  int _sp = 0, _sl = 0, _sg = 0;

  /// Current `memory.buffer`; a new identity means the memory grew and every older view is detached.
  JSArrayBuffer _sync() {
    final b = _x.memory['buffer'] as JSArrayBuffer;
    final old = _buf;
    if (old == null || !b.strictEquals(old).toDart) {
      _buf = b;
      _bufEpoch++;
      _slotView = _U32(b, _slotAddr, 4).toDart;
    }
    return b;
  }

  @override
  String get backend => _isDart2Wasm ? 'wasm (dart2wasm)' : 'wasm (dart2js)';

  @override
  String get transferMechanism => _isDart2Wasm ? 'memcpy' : 'zero-copy view';

  @override
  int get generation {
    final g = _x.f2d_generation();
    _sync();
    if (g != _lastEngineGen || _bufEpoch != _lastBufEpoch) {
      _lastEngineGen = g;
      _lastBufEpoch = _bufEpoch;
      _gen++;
    }
    return _gen;
  }

  @override
  int fetchSlice(Buf b, int k) {
    final o = _slotAddr;
    final code = switch (b) {
      Buf.error => _x.f2d_error(o),
      Buf.nodeIds => _x.f2d_node_ids(o),
      Buf.nodeXy => _x.f2d_node_xy(o),
      Buf.restraint => _x.f2d_node_restraint(o),
      Buf.memberIds => _x.f2d_member_ids(o),
      Buf.memberEnds => _x.f2d_member_ends(o),
      Buf.memberLen => _x.f2d_member_len(o),
      Buf.caseName => _x.f2d_case_name(k, o),
      Buf.stats => _x.f2d_stats(o),
      Buf.disp => _x.f2d_disp(k, o),
      Buf.endForces => _x.f2d_end_forces(k, o),
      Buf.maxM => _x.f2d_max_m(k, o),
      Buf.stationsM => _x.f2d_stations_m(k, o),
      Buf.exportModel => _x.f2d_export_model(o),
      Buf.exportResults => _x.f2d_export_results(o),
    };
    _sync(); // an export may have grown memory: read the slot through the current buffer
    final s = _slotView;
    _sp = s[0];
    _sl = s[1];
    _sg = s[2];
    return code;
  }

  @override
  int get slicePtr => _sp;
  @override
  int get sliceLen => _sl;
  @override
  int get sliceGen => _sg;

  @override
  Float64List viewF64(int ptr, int n) => _F64(_sync(), ptr, n).toDart;
  @override
  Int32List viewI32(int ptr, int n) => _I32(_sync(), ptr, n).toDart;
  @override
  Uint32List viewU32(int ptr, int n) => _U32(_sync(), ptr, n).toDart;
  @override
  Uint8List viewU8(int ptr, int n) => _U8(_sync(), ptr, n).toDart;

  @override
  int rawLoadJson(Uint8List bytes) {
    final n = bytes.length;
    final ptr = _x.f2d_alloc(n == 0 ? 1 : n);
    if (ptr == 0) return 2;
    _U8(_sync(), ptr, n).callMethod('set'.toJS, bytes.toJS);
    final code = _x.f2d_load_json(ptr, n);
    _x.f2d_free(ptr, n == 0 ? 1 : n);
    return code;
  }

  @override
  int rawGenerate(int bays, int stories) => _x.f2d_generate(bays, stories);
  @override
  int rawSolve(int mask) => _x.f2d_solve(mask);
  @override
  void rawSetNodeXY(int index, double x, double y) => _x.f2d_set_node_xy(index, x, y);
  @override
  int rawEcho(int n) => _x.f2d_echo(n);

  @override
  int get nodeCount => _x.f2d_node_count();
  @override
  int get memberCount => _x.f2d_member_count();
  @override
  int get caseCount => _x.f2d_case_count();
  @override
  double residual(int k) => _x.f2d_residual(k);

  @override
  double sinceStartMs() => _performance.now();

  @override
  void noop() => _x.f2d_noop();
}

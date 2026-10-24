// ignore_for_file: non_constant_identifier_names, library_private_types_in_public_api
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWasm;

import 'frame_engine.dart';

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

/// The exported C ABI of frame2d_engine.wasm (src/bridge/exports.zig).
extension type _Exports._(JSObject _) implements JSObject {
  external JSObject get memory;
  external void f2d_noop();
  external int f2d_echo(int n);
  external int f2d_alloc(int n);
  external void f2d_free(int p, int n);
  external int f2d_load_json(int p, int len);
  external int f2d_generate(int bays, int stories);
  external int f2d_error_ptr();
  external int f2d_error_len();
  external int f2d_node_count();
  external int f2d_member_count();
  external int f2d_case_count();
  external int f2d_node_ids();
  external int f2d_node_xy();
  external int f2d_node_restraint();
  external int f2d_member_ids();
  external int f2d_member_ends();
  external int f2d_member_len();
  external int f2d_case_name_ptr(int k);
  external int f2d_case_name_len(int k);
  external void f2d_set_node_xy(int idx, double x, double y);
  external int f2d_solve(int mask);
  external int f2d_stats();
  external int f2d_disp(int k);
  external int f2d_end_forces(int k);
  external int f2d_max_m(int k);
  external int f2d_stations_m(int k);
  external double f2d_residual(int k);
  external int f2d_export_model();
  external int f2d_out_ptr();
}

/// Web bridge: the Zig engine compiled to wasm32, called through dart:js_interop.
/// Results are read through typed-array views over WASM memory. The JS Float64Array view is zero-copy under
/// dart2js (`flutter build web`), but dart2wasm (`--wasm`) has to copy it into a Dart typed list.
Future<FrameEngine> createEngine() async {
  final url = Uri.base.resolve('frame2d_engine.wasm').toString();
  final env = JSObject()..['f2d_now_ms'] = (() => _performance.now()).toJS;
  final imports = JSObject()..['env'] = env;
  JSObject result;
  try {
    result = await _instantiateStreaming(_fetch(url), imports).toDart;
  } catch (_) {
    // Servers that do not send application/wasm: compile from bytes instead.
    final response = _Response._(await _fetch(url).toDart);
    result = await _instantiate(await response.arrayBuffer().toDart, imports).toDart;
  }
  final instance = result['instance'] as JSObject;
  return WebEngine(_Exports._(instance['exports'] as JSObject));
}

class WebEngine implements FrameEngine {
  WebEngine(this._x);

  final _Exports _x;

  // Geometry is copied once per model; coordinates are kept in Dart and mirrored into the engine.
  Int32List _nodeIds = Int32List(0);
  Float64List _nodeXy = Float64List(0);
  Uint8List _restraint = Uint8List(0);
  Int32List _memberIds = Int32List(0);
  Uint32List _memberEnds = Uint32List(0);
  Float64List _memberLen = Float64List(0);
  bool _lengthsStale = false;

  @override
  String get backend => kIsWasm ? 'wasm (dart2wasm)' : 'wasm (dart2js)';

  @override
  String get transferMechanism => kIsWasm ? 'memcpy' : 'zero-copy view';

  JSObject get _buffer => _x.memory['buffer'] as JSObject;

  T _view<T extends JSObject>(String ctor, int ptr, int len) {
    final c = globalContext[ctor] as JSFunction;
    return c.callAsConstructorVarArgs<T>([_buffer, ptr.toJS, len.toJS]);
  }

  Float64List _f64(int ptr, int n) => _view<JSFloat64Array>('Float64Array', ptr, n).toDart;
  Int32List _i32(int ptr, int n) => _view<JSInt32Array>('Int32Array', ptr, n).toDart;
  Uint32List _u32(int ptr, int n) => _view<JSUint32Array>('Uint32Array', ptr, n).toDart;
  Uint8List _u8(int ptr, int n) => _view<JSUint8Array>('Uint8Array', ptr, n).toDart;

  Float64List _copy(Float64List v) => Float64List.fromList(v);

  String _lastError() => utf8.decode(_u8(_x.f2d_error_ptr(), _x.f2d_error_len()));

  String? _status(int code) {
    switch (code) {
      case 0:
        _refreshGeometry();
        return null;
      case 1:
        return _lastError();
      case 2:
        return 'out of memory';
      default:
        return 'no model loaded';
    }
  }

  void _refreshGeometry() {
    final nn = _x.f2d_node_count();
    final nm = _x.f2d_member_count();
    if (nn == 0) return;
    _nodeIds = Int32List.fromList(_i32(_x.f2d_node_ids(), nn));
    _nodeXy = _copy(_f64(_x.f2d_node_xy(), nn * 2));
    _restraint = Uint8List.fromList(_u8(_x.f2d_node_restraint(), nn));
    _memberIds = Int32List.fromList(_i32(_x.f2d_member_ids(), nm));
    _memberEnds = Uint32List.fromList(_u32(_x.f2d_member_ends(), nm * 2));
    _memberLen = _copy(_f64(_x.f2d_member_len(), nm));
    _lengthsStale = false;
  }

  @override
  String? loadJson(String text) {
    final bytes = utf8.encode(text);
    final ptr = _x.f2d_alloc(bytes.length);
    if (ptr == 0) return 'out of memory';
    _view<JSUint8Array>('Uint8Array', ptr, bytes.length).callMethod('set'.toJS, bytes.toJS);
    final code = _x.f2d_load_json(ptr, bytes.length);
    _x.f2d_free(ptr, bytes.length);
    return _status(code);
  }

  @override
  String? generate(int bays, int stories) => _status(_x.f2d_generate(bays, stories));

  @override
  int get nodeCount => _x.f2d_node_count();
  @override
  int get memberCount => _x.f2d_member_count();
  @override
  int get caseCount => _x.f2d_case_count();

  @override
  String caseName(int k) => utf8.decode(_u8(_x.f2d_case_name_ptr(k), _x.f2d_case_name_len(k)));

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
      _memberLen = _copy(_f64(_x.f2d_member_len(), memberCount));
      _lengthsStale = false;
    }
    return _memberLen;
  }

  @override
  void setNodeXY(int index, double x, double y) {
    _nodeXy[index * 2] = x;
    _nodeXy[index * 2 + 1] = y;
    _x.f2d_set_node_xy(index, x, y);
    _lengthsStale = true;
  }

  @override
  String? solve(int mask) {
    final code = _x.f2d_solve(mask);
    return code == 0 ? null : _status(code);
  }

  @override
  SolveStats get stats {
    final s = _f64(_x.f2d_stats(), 6);
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
  Float64List? displacements(int k) {
    final p = _x.f2d_disp(k);
    return p == 0 ? null : _f64(p, nodeCount * 3);
  }

  @override
  Float64List? endForces(int k) {
    final p = _x.f2d_end_forces(k);
    return p == 0 ? null : _f64(p, memberCount * 6);
  }

  @override
  Float64List? maxMoment(int k) {
    final p = _x.f2d_max_m(k);
    return p == 0 ? null : _f64(p, memberCount);
  }

  @override
  Float64List? stationMoments(int k) {
    final p = _x.f2d_stations_m(k);
    return p == 0 ? null : _f64(p, memberCount * 11);
  }

  @override
  double residual(int k) => _x.f2d_residual(k);

  @override
  String exportModelJson() {
    final n = _x.f2d_export_model();
    return utf8.decode(_u8(_x.f2d_out_ptr(), n));
  }

  @override
  double sinceStartMs() => _performance.now();

  @override
  void noop() => _x.f2d_noop();

  @override
  Float64List echo(int n) => _f64(_x.f2d_echo(n), n);
}

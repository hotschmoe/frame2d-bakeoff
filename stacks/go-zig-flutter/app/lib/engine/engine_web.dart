import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'engine.dart';

Future<Engine> createEngine() async {
  final ready = globalContext.getProperty<JSPromise>('f2dReady'.toJS);
  await ready.toDart;
  return WasmEngine(globalContext.getProperty<F2dApi>('f2dEngine'.toJS));
}

extension type F2dApi(JSObject _) implements JSObject {
  external void noop();
  external JSFloat64Array echo(int n);
  external int loadJson(String json);
  external int gen(int b, int s);
  external void free(int h);
  external String lastError();
  external JSFloat64Array counts(int h);
  external JSFloat64Array geometry(int h);
  external JSFloat64Array result(int h);
  external JSFloat64Array stats(int h);
  external String caseIds(int h);
  external void setNode(int h, int i, double x, double y);
  external int solve(int h, int c);
  external String toJson(int h);
}

/// Zig wasm32 engine (web/f2d_loader.js). Every buffer is copied into a fresh JS Float64Array (memcpy).
class WasmEngine implements Engine {
  WasmEngine(this._a);
  final F2dApi _a;

  @override
  String get mechanism => 'memcpy';

  @override
  void noop() => _a.noop();

  @override
  Float64List echo(int n) => _a.echo(n).toDart;

  @override
  double processAgeMs() => 0;

  @override
  int loadJson(String json) => _a.loadJson(json);

  @override
  int gen(int bays, int stories) => _a.gen(bays, stories);

  @override
  void free(int h) => _a.free(h);

  @override
  String lastError() => _a.lastError();

  @override
  (int, int, int) counts(int h) {
    final c = _a.counts(h).toDart;
    return (c[0].toInt(), c[1].toInt(), c[2].toInt());
  }

  // The loader slices every buffer out of wasm memory (a fresh JS array, never a view on memory.buffer, which
  // memory.grow detaches), so the returned list is already caller-owned; dst is not needed.
  @override
  Float64List geometry(int h) => _a.geometry(h).toDart;

  @override
  Float64List resultInto(int h, Float64List dst) => _a.result(h).toDart;

  @override
  Float64List statsInto(int h, Float64List dst) => _a.stats(h).toDart;

  @override
  List<String> caseIds(int h) => (jsonDecode(_a.caseIds(h)) as List).cast<String>();

  @override
  void setNode(int h, int index, double x, double y) => _a.setNode(h, index, x, y);

  @override
  int solve(int h, int caseIndex) => _a.solve(h, caseIndex);

  @override
  String toJson(int h) => _a.toJson(h);
}

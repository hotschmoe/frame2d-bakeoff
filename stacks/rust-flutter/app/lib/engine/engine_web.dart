/// Web engine: the Rust engine compiled to WASM (wasm-bindgen), called through dart:js_interop.
///
/// `web/index.html` instantiates the module and publishes it as `window.f2d`; `window.f2dReady` resolves
/// when the WASM is ready. Solves run synchronously on the main thread.
// ignore_for_file: non_constant_identifier_names
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'engine.dart';

Engine createEngine() => WebEngine();

@JS('f2d')
external _Module get _f2d;

@JS('f2dReady')
external JSPromise<JSAny?> get _f2dReady;

extension type _Module._(JSObject _) implements JSObject {
  external _ModelView engine_generate(int bays, int stories);
  external _ModelView engine_load(String json);
  external String engine_export();
  external _SolveView engine_solve(int caseIndex);
  external _SolveView engine_move_and_solve(int nodePos, double x, double y, int caseIndex);
  external void f2d_noop();
  external JSFloat64Array f2d_echo(int n);
}

extension type _ModelView._(JSObject _) implements JSObject {
  external JSInt32Array get node_ids;
  external JSFloat64Array get node_xy;
  external JSUint8Array get node_support;
  external JSInt32Array get member_ids;
  external JSUint32Array get member_nodes;
  external JSFloat64Array get member_length;
  external JSUint32Array get member_material;
  external JSUint32Array get member_section;
  external JSArray<JSString> get material_names;
  external JSArray<JSString> get section_names;
  external JSArray<JSString> get case_ids;
  external JSUint32Array get nodal_load_ix;
  external JSFloat64Array get nodal_load_f;
  external JSUint32Array get udl_ix;
  external JSFloat64Array get udl_w;
  external void free();
}

extension type _SolveView._(JSObject _) implements JSObject {
  external int get case_index;
  external JSFloat64Array get disp;
  external JSFloat64Array get end_forces;
  external JSFloat64Array get stations_m;
  external JSFloat64Array get member_max_abs_m;
  external JSFloat64Array get member_max_abs_v;
  external JSFloat64Array get member_axial;
  external JSFloat64Array get member_length;
  external JSFloat64Array get reactions;
  external double get equilibrium_residual;
  external double get assemble_ms;
  external double get factor_ms;
  external double get solve_ms;
  external int get free_dofs;
  external int get profile_before;
  external int get profile_after;
  external void free();
}

class WebEngine implements Engine {
  @override
  Future<void> init() async {
    await _f2dReady.toDart;
  }

  T _guard<T>(T Function() call) {
    try {
      return call();
    } catch (e) {
      throw EngineError.from(e);
    }
  }

  @override
  Future<ModelData> generate(int bays, int stories) async =>
      _guard(() => _model(_f2d.engine_generate(bays, stories)));

  @override
  Future<ModelData> load(String json) async => _guard(() => _model(_f2d.engine_load(json)));

  @override
  Future<String> export() async => _guard(() => _f2d.engine_export());

  @override
  Future<SolveData> solve(int caseIndex) async => _guard(() => _solve(_f2d.engine_solve(caseIndex)));

  @override
  Future<SolveData> moveAndSolve(int nodePos, double x, double y, int caseIndex) async =>
      _guard(() => _solve(_f2d.engine_move_and_solve(nodePos, x, y, caseIndex)));

  @override
  void noop() => _f2d.f2d_noop();

  @override
  Float64List echo(int n) => _f2d.f2d_echo(n).toDart;

  @override
  String get mechanism => 'wasm-bindgen-copy (Float64Array copied out of WASM linear memory)';

  List<String> _strings(JSArray<JSString> a) => [for (final s in a.toDart) s.toDart];

  ModelData _model(_ModelView v) {
    final data = ModelData(
      nodeIds: v.node_ids.toDart,
      nodeXy: v.node_xy.toDart,
      nodeSupport: v.node_support.toDart,
      memberIds: v.member_ids.toDart,
      memberNodes: v.member_nodes.toDart,
      memberLength: v.member_length.toDart,
      memberMaterial: v.member_material.toDart,
      memberSection: v.member_section.toDart,
      materialNames: _strings(v.material_names),
      sectionNames: _strings(v.section_names),
      caseIds: _strings(v.case_ids),
      nodalLoadIx: v.nodal_load_ix.toDart,
      nodalLoadF: v.nodal_load_f.toDart,
      udlIx: v.udl_ix.toDart,
      udlW: v.udl_w.toDart,
    );
    v.free();
    return data;
  }

  SolveData _solve(_SolveView v) {
    final data = SolveData(
      caseIndex: v.case_index,
      disp: v.disp.toDart,
      endForces: v.end_forces.toDart,
      stationsM: v.stations_m.toDart,
      memberMaxAbsM: v.member_max_abs_m.toDart,
      memberMaxAbsV: v.member_max_abs_v.toDart,
      memberAxial: v.member_axial.toDart,
      memberLength: v.member_length.toDart,
      reactions: v.reactions.toDart,
      equilibriumResidual: v.equilibrium_residual,
      assembleMs: v.assemble_ms,
      factorMs: v.factor_ms,
      solveMs: v.solve_ms,
      freeDofs: v.free_dofs,
      profileBefore: v.profile_before,
      profileAfter: v.profile_after,
    );
    v.free();
    return data;
  }
}

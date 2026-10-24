/// Desktop engine: flutter_rust_bridge over dart:ffi into `frame2d_bridge`.
library;

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;

import '../generated/api.dart' as api;
import '../generated/frb_generated.dart';
import 'engine.dart';

Engine createEngine() => NativeEngine();

class NativeEngine implements Engine {
  @override
  Future<void> init() {
    final name = Platform.isWindows
        ? 'frame2d_bridge.dll'
        : Platform.isMacOS
            ? 'libframe2d_bridge.dylib'
            : 'libframe2d_bridge.so';
    return RustLib.init(externalLibrary: ExternalLibrary.open(name));
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      throw EngineError.from(e);
    }
  }

  @override
  Future<ModelData> generate(int bays, int stories) =>
      _guard(() async => _model(await api.engineGenerate(bays: bays, stories: stories)));

  @override
  Future<ModelData> load(String json) => _guard(() async => _model(await api.engineLoad(json: json)));

  @override
  Future<String> export() => _guard(api.engineExport);

  @override
  Future<SolveData> solve(int caseIndex) =>
      _guard(() async => _solve(await api.engineSolve(caseIndex: caseIndex)));

  @override
  Future<SolveData> moveAndSolve(int nodePos, double x, double y, int caseIndex) => _guard(
        () async => _solve(await api.engineMoveAndSolve(nodePos: nodePos, x: x, y: y, caseIndex: caseIndex)),
      );

  @override
  void noop() => api.f2DNoop();

  @override
  Float64List echo(int n) => api.f2DEcho(n: n);

  @override
  String get mechanism => 'frb-sync-sse (Rust serializes to a byte buffer, Dart copies it into a Float64List)';

  ModelData _model(api.ModelView v) => ModelData(
        nodeIds: v.nodeIds,
        nodeXy: v.nodeXy,
        nodeSupport: v.nodeSupport,
        memberIds: v.memberIds,
        memberNodes: v.memberNodes,
        memberLength: v.memberLength,
        memberMaterial: v.memberMaterial,
        memberSection: v.memberSection,
        materialNames: v.materialNames,
        sectionNames: v.sectionNames,
        caseIds: v.caseIds,
        nodalLoadIx: v.nodalLoadIx,
        nodalLoadF: v.nodalLoadF,
        udlIx: v.udlIx,
        udlW: v.udlW,
      );

  SolveData _solve(api.SolveView v) => SolveData(
        caseIndex: v.caseIndex,
        disp: v.disp,
        endForces: v.endForces,
        stationsM: v.stationsM,
        memberMaxAbsM: v.memberMaxAbsM,
        memberMaxAbsV: v.memberMaxAbsV,
        memberAxial: v.memberAxial,
        memberLength: v.memberLength,
        reactions: v.reactions,
        equilibriumResidual: v.equilibriumResidual,
        assembleMs: v.assembleMs,
        factorMs: v.factorMs,
        solveMs: v.solveMs,
        freeDofs: v.freeDofs,
        profileBefore: v.profileBefore,
        profileAfter: v.profileAfter,
      );
}

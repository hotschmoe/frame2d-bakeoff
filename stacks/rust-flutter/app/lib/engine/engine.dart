/// The engine as the UI sees it. Two implementations: flutter_rust_bridge (desktop FFI) and
/// wasm-bindgen (web). All analysis happens in Rust; these types only carry its flat arrays.
library;

import 'dart:typed_data';

/// A model error or engine failure; `code` is the SPEC 4.6 error code.
class EngineError implements Exception {
  EngineError(this.code, this.detail);

  final String code;
  final String detail;

  /// Parses the `code|detail` strings produced by the Rust side, tolerating wrappers added by the runtime.
  factory EngineError.from(Object error) {
    var text = error.toString();
    for (final prefix in ['Exception: ', 'Error: ', 'JavaScriptError: ']) {
      if (text.startsWith(prefix)) text = text.substring(prefix.length);
    }
    final bar = text.indexOf('|');
    if (bar > 0 && bar < 24 && !text.substring(0, bar).contains(' ')) {
      return EngineError(text.substring(0, bar), text.substring(bar + 1));
    }
    return EngineError('engine', text);
  }

  @override
  String toString() => '$code: $detail';
}

/// Geometry and loads of the current model. Nodes and members are in ascending id order.
class ModelData {
  ModelData({
    required this.nodeIds,
    required this.nodeXy,
    required this.nodeSupport,
    required this.memberIds,
    required this.memberNodes,
    required this.memberLength,
    required this.memberMaterial,
    required this.memberSection,
    required this.materialNames,
    required this.sectionNames,
    required this.caseIds,
    required this.nodalLoadIx,
    required this.nodalLoadF,
    required this.udlIx,
    required this.udlW,
  });

  final Int32List nodeIds;

  /// x, y per node. Mutated while a node is dragged.
  final Float64List nodeXy;

  /// Bit 0 = ux, bit 1 = uy, bit 2 = rz restrained.
  final Uint8List nodeSupport;
  final Int32List memberIds;

  /// i, j node positions per member.
  final Uint32List memberNodes;
  final Float64List memberLength;
  final Uint32List memberMaterial;
  final Uint32List memberSection;
  final List<String> materialNames;
  final List<String> sectionNames;
  final List<String> caseIds;

  /// Per nodal load: case index, node position; and fx, fy, mz.
  final Uint32List nodalLoadIx;
  final Float64List nodalLoadF;

  /// Per member UDL: case index, member position; and w.
  final Uint32List udlIx;
  final Float64List udlW;

  int get nodeCount => nodeIds.length;
  int get memberCount => memberIds.length;
}

/// Results of one load case.
class SolveData {
  SolveData({
    required this.caseIndex,
    required this.disp,
    required this.endForces,
    required this.stationsM,
    required this.memberMaxAbsM,
    required this.memberMaxAbsV,
    required this.memberAxial,
    required this.memberLength,
    required this.reactions,
    required this.equilibriumResidual,
    required this.assembleMs,
    required this.factorMs,
    required this.solveMs,
    required this.freeDofs,
    required this.profileBefore,
    required this.profileAfter,
  });

  final int caseIndex;

  /// ux, uy, rz per node.
  final Float64List disp;
  final Float64List endForces;

  /// 11 bending moment stations per member.
  final Float64List stationsM;
  final Float64List memberMaxAbsM;
  final Float64List memberMaxAbsV;
  final Float64List memberAxial;

  /// Current member lengths (they change while a node is dragged).
  final Float64List memberLength;

  /// Node position, fx, fy, mz per reaction.
  final Float64List reactions;
  final double equilibriumResidual;
  final double assembleMs;
  final double factorMs;
  final double solveMs;
  final int freeDofs;
  final int profileBefore;
  final int profileAfter;

  /// Engine time for assembly, factorization and solution.
  double get engineMs => assembleMs + factorMs + solveMs;
}

abstract class Engine {
  /// Loads the native library or WASM module.
  Future<void> init();

  Future<ModelData> generate(int bays, int stories);
  Future<ModelData> load(String json);
  Future<String> export();
  Future<SolveData> solve(int caseIndex);

  /// Moves a node (by position) and solves one case in a single boundary crossing.
  Future<SolveData> moveAndSolve(int nodePos, double x, double y, int caseIndex);

  /// Boundary benchmark entry points (SPEC 5.5 `boundary`): synchronous on purpose.
  void noop();
  Float64List echo(int n);

  /// How array data crosses the language boundary, for the boundary bench line.
  String get mechanism;
}

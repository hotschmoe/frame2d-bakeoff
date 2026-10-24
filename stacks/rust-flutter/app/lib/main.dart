import 'package:flutter/material.dart';

import 'bench/bench.dart';
import 'engine/engine_factory.dart';
import 'state/app_state.dart';
import 'ui/frame_app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = benchModeFrom(args);
  final engine = createEngine();
  try {
    await engine.init();
  } catch (e) {
    runApp(MaterialApp(home: Scaffold(body: Center(child: Text('Could not start the engine: $e')))));
    return;
  }
  final state = AppState(engine);
  runApp(FrameApp(state: state));
  if (mode != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => runBench(mode, state, frames: benchFrames(args)));
  } else {
    state.generate(3, 3);
  }
}

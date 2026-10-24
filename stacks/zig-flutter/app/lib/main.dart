import 'package:flutter/material.dart';

import 'bench/bench.dart';
import 'bench/platform.dart';
import 'engine/frame_engine.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = benchModeFrom(args);
  final engine = await FrameEngine.create();
  final state = AppState(engine);

  if (mode == 'boundary') {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('boundary bench')))));
    runBoundaryBench(engine);
    return;
  }
  if (mode != null && benchModes.contains(mode)) {
    if (benchParam(args, 'defl') == '0') state.showDeflected = false;
    if (benchParam(args, 'moment') == '0') state.showMoment = false;
    if (benchParam(args, 'color') == '0') state.colorByMoment = false;
    final err = prepareBench(mode, state, size: int.tryParse(benchParam(args, 'size') ?? ''));
    if (err != null) {
      benchEmit('BENCH {"mode":"$mode","error":${_quote(err)}}');
      benchFinish();
    }
    runApp(Frame2dApp(state: state, benchMode: mode));
    return;
  }
  runApp(Frame2dApp(state: state));
}

String _quote(String s) => '"${s.replaceAll('"', "'")}"';

class Frame2dApp extends StatelessWidget {
  const Frame2dApp({super.key, required this.state, this.benchMode});

  final AppState state;
  final String? benchMode;

  @override
  Widget build(BuildContext context) {
    final home = HomePage(state: state);
    return MaterialApp(
      title: 'Frame2D',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2B59C3), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF2B59C3), brightness: Brightness.dark, useMaterial3: true),
      home: benchMode == null ? home : BenchHost(mode: benchMode!, state: state, child: home),
    );
  }
}

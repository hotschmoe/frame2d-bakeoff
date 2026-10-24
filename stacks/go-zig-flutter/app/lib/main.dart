import 'package:flutter/material.dart';

import 'app_state.dart';
import 'bench.dart';
import 'engine/engine.dart';
import 'io/platform.dart';
import 'ui/home.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = benchMode(args);
  final engine = await Engine.create();
  final state = AppState(engine);
  if (mode == 'boundary') {
    // pure boundary measurement: no UI needed
    await Bench(mode!, engine, null).run();
    return;
  }
  runApp(FrameApp(state: state, mode: mode));
}

class FrameApp extends StatefulWidget {
  const FrameApp({super.key, required this.state, this.mode});
  final AppState state;
  final String? mode;

  @override
  State<FrameApp> createState() => _FrameAppState();
}

class _FrameAppState extends State<FrameApp> {
  @override
  void initState() {
    super.initState();
    final mode = widget.mode;
    if (mode != null) {
      // start once the first frame is up so benches measure a running app
      WidgetsBinding.instance.addPostFrameCallback((_) => Bench(mode, widget.state.engine, widget.state).run());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.state.generate(10, 10));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame2D',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1565C0), useMaterial3: true),
      home: Home(state: widget.state, compact: widget.mode == 'drag' || widget.mode == 'render'),
    );
  }
}

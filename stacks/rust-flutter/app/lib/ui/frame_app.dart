/// Application shell: toolbar, canvas, member table and status bar.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'canvas_view.dart';
import 'file_io.dart';
import 'member_table.dart';

class FrameApp extends StatelessWidget {
  const FrameApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame2D',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)), useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: HomePage(state: state),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 900;
            final canvas = CanvasView(state: state);
            final table = MemberTable(state: state);
            return Column(
              children: [
                Toolbar(state: state),
                ErrorBanner(state: state),
                Expanded(
                  child: wide
                      ? Row(
                          children: [
                            Expanded(child: canvas),
                            const VerticalDivider(width: 1),
                            SizedBox(width: 500, child: table),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(flex: 3, child: canvas),
                            const Divider(height: 1),
                            Expanded(flex: 2, child: table),
                          ],
                        ),
                ),
                StatusBar(state: state),
              ],
            );
          },
        ),
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final e = state.error;
        if (e == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(e, style: TextStyle(color: scheme.onErrorContainer))),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: scheme.onErrorContainer,
                  onPressed: state.clearError,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class Toolbar extends StatelessWidget {
  const Toolbar({super.key, required this.state});

  final AppState state;

  Future<void> _open() async {
    try {
      final picked = await pickModelFile();
      if (picked != null) await state.loadJson(picked.text, picked.name);
    } catch (e) {
      state.error = 'Could not open file: $e';
      state.repaint();
    }
  }

  Future<void> _save() async {
    try {
      await saveModelFile(await state.exportJson());
    } catch (e) {
      state.error = 'Could not save file: $e';
      state.repaint();
    }
  }

  Future<void> _generate(BuildContext context) async {
    final size = await showDialog<(int, int)>(context: context, builder: (_) => const GenerateDialog());
    if (size != null) await state.generate(size.$1, size.$2);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final m = state.model;
            return Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Frame2D', style: theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: _open,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open'),
                ),
                OutlinedButton.icon(
                  onPressed: m == null ? null : _save,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _generate(context),
                  icon: const Icon(Icons.grid_on, size: 18),
                  label: const Text('Generate'),
                ),
                FilledButton(
                  onPressed: m == null || state.busy ? null : state.solveCurrent,
                  child: const Text("Solve"), // BENCH-EDIT:ui
                ),
                if (m != null && m.caseIds.length > 1)
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: [for (var i = 0; i < m.caseIds.length; i++) ButtonSegment(value: i, label: Text(m.caseIds[i]))],
                    selected: {state.caseIndex},
                    onSelectionChanged: (s) => state.selectCase(s.first),
                  ),
                FilterChip(
                  label: const Text('Moment'),
                  selected: state.showMoment,
                  onSelected: (v) => state.toggle(moment: v),
                ),
                FilterChip(
                  label: const Text('Deflected'),
                  selected: state.showDeflected,
                  onSelected: (v) => state.toggle(deflected: v),
                ),
                FilterChip(
                  label: const Text('Colour by |M|'),
                  selected: state.colorByMoment,
                  onSelected: (v) => state.toggle(color: v),
                ),
                FilterChip(
                  label: const Text('Loads'),
                  selected: state.showLoads,
                  onSelected: (v) => state.toggle(loads: v),
                ),
                if (state.deflectionScale > 0)
                  SizedBox(
                    width: 220,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Scale', style: theme.textTheme.labelMedium),
                        Expanded(
                          child: Slider(
                            value: state.deflectionScale.clamp(0.0, state.deflectionScaleMax),
                            max: state.deflectionScaleMax,
                            onChanged: state.setDeflectionScale,
                          ),
                        ),
                        Text('${state.deflectionScale.toStringAsFixed(0)}×', style: theme.textTheme.labelMedium),
                      ],
                    ),
                  ),
                if (state.busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class GenerateDialog extends StatefulWidget {
  const GenerateDialog({super.key});

  @override
  State<GenerateDialog> createState() => _GenerateDialogState();
}

class _GenerateDialogState extends State<GenerateDialog> {
  final _bays = TextEditingController(text: '10');
  final _stories = TextEditingController(text: '10');
  String? _problem;

  @override
  void dispose() {
    _bays.dispose();
    _stories.dispose();
    super.dispose();
  }

  void _submit() {
    final b = int.tryParse(_bays.text.trim());
    final s = int.tryParse(_stories.text.trim());
    if (b == null || s == null || b < 1 || s < 1 || b > 400 || s > 400) {
      setState(() => _problem = 'Enter whole numbers from 1 to 400.');
      return;
    }
    Navigator.of(context).pop((b, s));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Generate moment frame'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _bays,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Bays (B)'),
          ),
          TextField(
            controller: _stories,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Storeys (S)'),
            onSubmitted: (_) => _submit(),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Generate')),
      ],
    );
  }
}

class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.state});

  final AppState state;

  String _describe() {
    final m = state.model;
    if (m == null) return 'Generate or open a model to begin.';
    final sol = state.solution;
    final parts = <String>[
      state.modelName,
      '${m.nodeCount} nodes',
      '${m.memberCount} members',
    ];
    if (sol != null) {
      parts.add('${sol.freeDofs} free DOF');
      parts.add('profile ${sol.profileBefore} to ${sol.profileAfter}');
      parts.add('engine ${sol.engineMs.toStringAsFixed(1)} ms (call ${state.lastCallMs.toStringAsFixed(1)} ms)');
      parts.add('residual ${sol.equilibriumResidual.toStringAsExponential(1)}');
    }
    final mem = state.selectedMember;
    if (mem != null && mem < m.memberCount) {
      var text = 'Member ${m.memberIds[mem]}  L=${m.memberLength[mem].toStringAsFixed(3)} m';
      if (sol != null) {
        text += '  max|M|=${(sol.memberMaxAbsM[mem] / 1000).toStringAsFixed(2)} kN·m'
            '  N=${(sol.memberAxial[mem] / 1000).toStringAsFixed(2)} kN';
      }
      parts.add(text);
    }
    final node = state.selectedNode;
    if (node != null && node < m.nodeCount) {
      var text = 'Node ${m.nodeIds[node]} (${m.nodeXy[node * 2].toStringAsFixed(2)}, ${m.nodeXy[node * 2 + 1].toStringAsFixed(2)})';
      if (sol != null) {
        text += '  ux=${(sol.disp[node * 3] * 1000).toStringAsFixed(3)} mm  uy=${(sol.disp[node * 3 + 1] * 1000).toStringAsFixed(3)} mm';
      }
      parts.add(text);
    }
    if (state.dragLog.isNotEmpty) {
      final last = state.dragLog.last;
      parts.add('drag: solve ${last.solveMs.toStringAsFixed(1)} ms, lag ${last.lagFrames} frames');
    }
    return parts.join('   |   ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Align(
            alignment: Alignment.centerLeft,
            child: Text(_describe(), style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }
}

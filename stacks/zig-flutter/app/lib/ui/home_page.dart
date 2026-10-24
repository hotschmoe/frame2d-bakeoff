import 'package:flutter/material.dart';

import '../files/file_io.dart';
import '../state/app_state.dart';
import 'canvas_view.dart';
import 'member_table.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Toolbar(state: state),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final canvas = CanvasView(state: state);
                final table = MemberTable(state: state);
                if (c.maxWidth >= 900) {
                  return Row(children: [
                    Expanded(child: canvas),
                    const VerticalDivider(width: 1),
                    SizedBox(width: 520, child: table),
                  ]);
                }
                return Column(children: [
                  Expanded(flex: 3, child: canvas),
                  const Divider(height: 1),
                  Expanded(flex: 2, child: table),
                ]);
              }),
            ),
            const Divider(height: 1),
            StatusBar(state: state),
          ],
        ),
      ),
    );
  }
}

class Toolbar extends StatelessWidget {
  const Toolbar({super.key, required this.state});

  final AppState state;

  Future<void> _open(BuildContext context) async {
    try {
      final text = await openModelText();
      if (text != null) state.loadText(text);
    } catch (e) {
      state.report('Open failed: $e');
    }
  }

  Future<void> _save() async {
    if (!state.hasModel) return;
    try {
      await saveModelText('frame2d-model.json', state.exportJson());
    } catch (e) {
      state.report('Save failed: $e');
    }
  }

  Future<void> _generate(BuildContext context) async {
    final result = await showDialog<(int, int)>(context: context, builder: (_) => const GenerateDialog());
    if (result != null) {
      // Let the dialog close before the (possibly long) generate + solve blocks the UI thread.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state.generate(result.$1, result.$2);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(onPressed: () => _open(context), child: const Text('Open')),
              OutlinedButton(onPressed: state.hasModel ? _save : null, child: const Text('Save')),
              OutlinedButton(onPressed: () => _generate(context), child: const Text('Generate')),
              FilledButton(onPressed: state.hasModel ? state.solveAll : null, child: const Text("Solve")), // BENCH-EDIT:ui
              OutlinedButton(onPressed: state.hasModel ? state.fitView : null, child: const Text('Fit')),
              if (state.caseNames.isNotEmpty)
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (var k = 0; k < state.caseNames.length; k++)
                      ButtonSegment(value: k, label: Text(state.caseNames[k])),
                  ],
                  selected: {state.caseIndex},
                  onSelectionChanged: (v) => state.selectCase(v.first),
                ),
              _Toggle('Deflected', state.showDeflected, state.setShowDeflected),
              SizedBox(
                width: 140,
                child: Slider(
                  value: state.deflSlider,
                  onChanged: state.showDeflected ? state.setDeflSlider : null,
                ),
              ),
              _Toggle('Moments', state.showMoment, state.setShowMoment),
              _Toggle('Color by |M|', state.colorByMoment, state.setColorByMoment),
            ],
          ),
        );
      },
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.label, this.value, this.onChanged);

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Switch(value: value, onChanged: onChanged),
      Text(label),
    ]);
  }
}

class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final st = state.stats;
        final text = state.error != null
            ? 'Error: ${state.error}'
            : !state.hasModel
                ? 'Open a model or press Generate'
                : '${state.nodeCount} nodes  ${state.memberCount} members  ${st.freeDofs} free DOFs  '
                    'profile ${st.profileBefore} → ${st.profileAfter}  '
                    'assemble ${st.assembleMs.toStringAsFixed(1)} / factor ${st.factorMs.toStringAsFixed(1)} / '
                    'solve ${st.solveMs.toStringAsFixed(1)} ms  residual ${state.residual.toStringAsExponential(1)}';
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: state.error != null ? Theme.of(context).colorScheme.errorContainer : null,
          child: Text(text, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        );
      },
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

  @override
  void dispose() {
    _bays.dispose();
    _stories.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = int.tryParse(_bays.text);
    final s = int.tryParse(_stories.text);
    final valid = b != null && s != null && b > 0 && s > 0 && b <= 400 && s <= 400;
    return AlertDialog(
      title: const Text('Generate moment frame'),
      content: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 110,
          child: TextField(
            controller: _bays,
            decoration: const InputDecoration(labelText: 'Bays (B)'),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 110,
          child: TextField(
            controller: _stories,
            decoration: const InputDecoration(labelText: 'Stories (S)'),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: valid ? () => Navigator.pop(context, (b, s)) : null, child: const Text('Generate')),
      ],
    );
  }
}

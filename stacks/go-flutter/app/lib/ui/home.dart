import 'package:flutter/material.dart';

import '../app_state.dart';
import '../io/platform.dart';
import 'canvas_view.dart';
import 'member_table.dart';

/// Main screen: toolbar, canvas and member table.
class Home extends StatefulWidget {
  const Home({super.key, required this.state, this.compact = false});
  final AppState state;

  /// Bench modes hide the table so frames measure the canvas only (the table is measured in the UI).
  final bool compact;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  AppState get s => widget.state;

  Future<void> _generate() async {
    final b = TextEditingController(text: '10'), st = TextEditingController(text: '10');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generate frame'),
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 100, child: TextField(controller: b, decoration: const InputDecoration(labelText: 'Bays B'), keyboardType: TextInputType.number)),
          const SizedBox(width: 16),
          SizedBox(width: 100, child: TextField(controller: st, decoration: const InputDecoration(labelText: 'Stories S'), keyboardType: TextInputType.number)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Generate')),
        ],
      ),
    );
    if (ok == true) {
      final bays = int.tryParse(b.text) ?? 0, stories = int.tryParse(st.text) ?? 0;
      if (bays >= 1 && stories >= 1) s.generate(bays, stories);
    }
  }

  Future<void> _open() async {
    final text = await openJsonFile(context);
    if (text != null) s.loadJson(text);
  }

  Future<void> _save() async {
    if (s.handle > 0) await saveJsonFile(context, 'model.json', s.exportJson());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        _toolbar(),
        ListenableBuilder(listenable: s, builder: (context, _) => s.error != null ? _errorBanner() : const SizedBox.shrink()),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final canvas = CanvasView(state: s);
            if (widget.compact) return canvas;
            if (c.maxWidth < 900) {
              return Column(children: [Expanded(flex: 3, child: canvas), const Divider(height: 1), Expanded(flex: 2, child: MemberTable(state: s))]);
            }
            return Row(children: [
              Expanded(child: canvas),
              const VerticalDivider(width: 1),
              SizedBox(width: 520, child: MemberTable(state: s)),
            ]);
          }),
        ),
        _statusBar(),
      ]),
    );
  }

  Widget _errorBanner() => Container(
        width: double.infinity,
        color: const Color(0xFFFFEBEE),
        padding: const EdgeInsets.all(8),
        child: Text('Model error: ${s.error}', style: const TextStyle(color: Color(0xFFB71C1C))),
      );

  Widget _toolbar() {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Material(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton(onPressed: s.solve, child: const Text("Solve")), // BENCH-EDIT:ui
            OutlinedButton(onPressed: _generate, child: const Text('Generate...')),
            OutlinedButton(onPressed: _open, child: const Text('Open')),
            OutlinedButton(onPressed: _save, child: const Text('Save')),
            OutlinedButton(onPressed: () { s.fitView(); s.touch(); }, child: const Text('Fit')),
            if (s.caseIds.isNotEmpty)
              DropdownButton<int>(
                value: s.caseIndex.clamp(0, s.caseIds.length - 1),
                items: [for (var i = 0; i < s.caseIds.length; i++) DropdownMenuItem(value: i, child: Text('Case ${s.caseIds[i]}'))],
                onChanged: (v) => s.setCase(v ?? 0),
              ),
            FilterChip(label: const Text('Deflected'), selected: s.showDeflected, onSelected: (v) => s.toggle(deflected: v)),
            FilterChip(label: const Text('Moment diagram'), selected: s.showMoment, onSelected: (v) => s.toggle(moment: v)),
            FilterChip(label: const Text('Color by |M|'), selected: s.colorByMoment, onSelected: (v) => s.toggle(color: v)),
            const Text('Scale'),
            SizedBox(
              width: 160,
              child: Slider(value: s.deflectionSlider, min: 0, max: 5, onChanged: s.setDeflectionSlider),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _statusBar() {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final st = s.stats;
        return Container(
          width: double.infinity,
          color: const Color(0xFFECEFF1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Text(
            s.handle <= 0
                ? 'No model'
                : '${s.nodeCount} nodes, ${s.memberCount} members, ${st[0].toInt()} free DOFs, profile ${st[1].toInt()} -> ${st[2].toInt()} | '
                    'solve ${s.lastSolveMs.toStringAsFixed(1)} ms (assemble ${st[3].toStringAsFixed(1)}, factor ${st[4].toStringAsFixed(1)}, solve ${st[5].toStringAsFixed(1)}) | '
                    'equilibrium ${st[6].toStringAsExponential(1)} | drag a node to re-solve',
            style: const TextStyle(fontSize: 12),
          ),
        );
      },
    );
  }
}

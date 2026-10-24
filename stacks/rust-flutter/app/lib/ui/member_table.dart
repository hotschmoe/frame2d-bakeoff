/// Virtualized, sortable member table. Only visible rows are built, so 20,100 members stay smooth.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../state/app_state.dart';

enum _Col {
  id('ID', 0.8, false),
  nodeI('I', 0.8, false),
  nodeJ('J', 0.8, false),
  length('L (m)', 1.0, true),
  section('Section', 1.0, false),
  maxM('|M| kNm', 1.5, true),
  maxV('|V| kN', 1.4, true),
  axial('N kN', 1.2, true);

  const _Col(this.title, this.flex, this.numeric);
  final String title;
  final double flex;
  final bool numeric;
}

const double _rowHeight = 26;

class MemberTable extends StatefulWidget {
  const MemberTable({super.key, required this.state});

  final AppState state;

  @override
  State<MemberTable> createState() => _MemberTableState();
}

class _MemberTableState extends State<MemberTable> {
  _Col _sortCol = _Col.id;
  bool _ascending = true;
  Int32List _order = Int32List(0);
  Object? _orderKey;
  final ScrollController _scroll = ScrollController();

  AppState get s => widget.state;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double _value(_Col c, int k) {
    final m = s.model!;
    final sol = s.solution;
    switch (c) {
      case _Col.id:
        return m.memberIds[k].toDouble();
      case _Col.nodeI:
        return m.nodeIds[m.memberNodes[k * 2]].toDouble();
      case _Col.nodeJ:
        return m.nodeIds[m.memberNodes[k * 2 + 1]].toDouble();
      case _Col.length:
        return m.memberLength[k];
      case _Col.section:
        return m.memberSection[k].toDouble();
      case _Col.maxM:
        return sol?.memberMaxAbsM[k] ?? 0;
      case _Col.maxV:
        return sol?.memberMaxAbsV[k] ?? 0;
      case _Col.axial:
        return sol?.memberAxial[k] ?? 0;
    }
  }

  /// Sort order is rebuilt only when the sort, the model, or (for result columns) the results change.
  Int32List _sorted() {
    final m = s.model!;
    final resultCol = _sortCol.index >= _Col.maxM.index;
    final key = (m, _sortCol, _ascending, m.memberCount, resultCol ? s.solutionVersion : 0, _sortCol == _Col.length ? s.geometryVersion : 0);
    if (_orderKey == key) return _order;
    final n = m.memberCount;
    final keys = Float64List(n);
    for (var k = 0; k < n; k++) {
      keys[k] = _value(_sortCol, k);
    }
    final idx = List<int>.generate(n, (i) => i);
    idx.sort((a, b) {
      final c = keys[a].compareTo(keys[b]);
      return c != 0 ? c : a.compareTo(b);
    });
    _order = Int32List.fromList(_ascending ? idx : idx.reversed.toList());
    _orderKey = key;
    return _order;
  }

  String _cell(_Col c, int k) {
    final m = s.model!;
    switch (c) {
      case _Col.id:
        return '${m.memberIds[k]}';
      case _Col.nodeI:
        return '${m.nodeIds[m.memberNodes[k * 2]]}';
      case _Col.nodeJ:
        return '${m.nodeIds[m.memberNodes[k * 2 + 1]]}';
      case _Col.length:
        return m.memberLength[k].toStringAsFixed(3);
      case _Col.section:
        return m.sectionNames[m.memberSection[k]];
      case _Col.maxM:
        return s.solution == null ? '-' : (s.solution!.memberMaxAbsM[k] / 1000).toStringAsFixed(2);
      case _Col.maxV:
        return s.solution == null ? '-' : (s.solution!.memberMaxAbsV[k] / 1000).toStringAsFixed(2);
      case _Col.axial:
        return s.solution == null ? '-' : (s.solution!.memberAxial[k] / 1000).toStringAsFixed(2);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final m = s.model;
        final theme = Theme.of(context);
        if (m == null) return const Center(child: Text('No model'));
        final order = _sorted();
        final style = theme.textTheme.bodySmall!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
        return Column(
          children: [
            Material(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Row(
                children: [
                  for (final c in _Col.values)
                    Expanded(
                      flex: (c.flex * 10).round(),
                      child: InkWell(
                        onTap: () => setState(() {
                          if (_sortCol == c) {
                            _ascending = !_ascending;
                          } else {
                            _sortCol = c;
                            _ascending = true;
                          }
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          child: Row(
                            mainAxisAlignment: c.numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
                            children: [
                              Flexible(
                                child: Text(
                                  c.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelMedium!.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                              if (_sortCol == c)
                                Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward, size: 12),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                child: ListView.builder(
                  controller: _scroll,
                  itemExtent: _rowHeight,
                  itemCount: order.length,
                  itemBuilder: (context, row) {
                    final k = order[row];
                    final selected = s.selectedMember == k;
                    return InkWell(
                      onTap: () => s.selectMember(selected ? null : k),
                      child: Container(
                        color: selected ? theme.colorScheme.primaryContainer : null,
                        child: Row(
                          children: [
                            for (final c in _Col.values)
                              Expanded(
                                flex: (c.flex * 10).round(),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  child: Align(
                                    alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
                                    child: Text(_cell(c, k), style: style, maxLines: 1),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

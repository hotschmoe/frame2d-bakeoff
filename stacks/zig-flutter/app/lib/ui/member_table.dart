import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Virtualized, sortable member table: only the visible rows are built, so 20,100 rows stay smooth.
class MemberTable extends StatefulWidget {
  const MemberTable({super.key, required this.state});

  final AppState state;

  @override
  State<MemberTable> createState() => _MemberTableState();
}

class _Column {
  const _Column(this.title, this.flex, this.resultDependent);

  final String title;
  final int flex;
  final bool resultDependent;
}

class _MemberTableState extends State<MemberTable> {
  static const _columns = [
    _Column('ID', 2, false),
    _Column('i', 2, false),
    _Column('j', 2, false),
    _Column('L (m)', 3, false),
    _Column('N (kN)', 3, true),
    _Column('V (kN)', 3, true),
    _Column('M_i (kNm)', 3, true),
    _Column('max|M| (kNm)', 4, true),
  ];
  static const _rowHeight = 26.0;

  int _sortCol = 0;
  bool _ascending = true;
  List<int> _order = const [];
  int _orderStamp = -1;
  int _orderCount = -1;
  int _orderKey = -1;

  AppState get s => widget.state;

  double _value(int col, int k) {
    switch (col) {
      case 0:
        return s.memberIds[k].toDouble();
      case 1:
        return s.nodeIds[s.memberEnds[k * 2]].toDouble();
      case 2:
        return s.nodeIds[s.memberEnds[k * 2 + 1]].toDouble();
      case 3:
        return s.memberLength[k];
      case 4:
        return (s.endForces?[k * 6] ?? 0) / 1000;
      case 5:
        return (s.endForces?[k * 6 + 1] ?? 0) / 1000;
      case 6:
        return (s.endForces?[k * 6 + 2] ?? 0) / 1000;
      default:
        return (s.maxM?[k] ?? 0) / 1000;
    }
  }

  void _ensureOrder() {
    final n = s.memberCount;
    final col = _columns[_sortCol];
    final key = _sortCol * 2 + (_ascending ? 1 : 0);
    // Results change every frame while a node is dragged: keep the previous order until the drag ends.
    final resultsChanged = col.resultDependent && s.stamp != _orderStamp && !s.dragging;
    final geometryChanged = n != _orderCount;
    if (!resultsChanged && !geometryChanged && key == _orderKey && _order.isNotEmpty) return;
    if (_order.length != n) {
      _order = List<int>.generate(n, (i) => i);
    }
    final order = List<int>.of(_order);
    final c = _sortCol;
    final sign = _ascending ? 1 : -1;
    if (c == 0 && _ascending) {
      for (var i = 0; i < n; i++) {
        order[i] = i;
      }
    } else {
      final keys = List<double>.generate(n, (k) => _value(c, k));
      order.sort((a, b) {
        final r = keys[a].compareTo(keys[b]);
        return r != 0 ? r * sign : a.compareTo(b);
      });
    }
    _order = order;
    _orderStamp = s.stamp;
    _orderCount = n;
    _orderKey = key;
  }

  String _fmt(int col, double v) {
    if (col <= 2) return v.toInt().toString();
    return v.toStringAsFixed(col == 3 ? 3 : 2);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final theme = Theme.of(context);
        if (!s.hasModel || s.memberCount == 0) {
          return const Center(child: Text('No model'));
        }
        _ensureOrder();
        final mono = theme.textTheme.bodySmall!.copyWith(fontFamily: 'Consolas', fontFamilyFallback: const ['monospace']);
        return Column(
          children: [
            Container(
              height: 32,
              color: theme.colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  for (var c = 0; c < _columns.length; c++)
                    Expanded(
                      flex: _columns[c].flex,
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
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              '${_columns[c].title}${_sortCol == c ? (_ascending ? ' ▲' : ' ▼') : ''}',
                              style: theme.textTheme.labelSmall,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemExtent: _rowHeight,
                itemCount: s.memberCount,
                itemBuilder: (context, row) {
                  final k = _order[row];
                  return Container(
                    color: row.isEven ? null : theme.colorScheme.surfaceContainerLow,
                    child: Row(
                      children: [
                        for (var c = 0; c < _columns.length; c++)
                          Expanded(
                            flex: _columns[c].flex,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(_fmt(c, _value(c, k)), style: mono, maxLines: 1, overflow: TextOverflow.clip),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

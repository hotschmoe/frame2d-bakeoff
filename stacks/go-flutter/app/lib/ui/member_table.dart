import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';

class _Col {
  const _Col(this.title, this.width, this.value, {this.digits = 2, this.needsResult = true});
  final String title;
  final double width;
  final double Function(AppState s, int m) value;
  final int digits;
  final bool needsResult;
}

final _cols = <_Col>[
  _Col('ID', 64, (s, m) => s.memberId(m).toDouble(), digits: 0, needsResult: false),
  _Col('i', 56, (s, m) => s.nodeId(s.memberI(m)).toDouble(), digits: 0, needsResult: false),
  _Col('j', 56, (s, m) => s.nodeId(s.memberJ(m)).toDouble(), digits: 0, needsResult: false),
  _Col('L (m)', 72, (s, m) => s.memberLength(m), digits: 3, needsResult: false),
  _Col('N_i (kN)', 84, (s, m) => s.endForce(m, 0) / 1e3),
  _Col('V_i (kN)', 84, (s, m) => s.endForce(m, 1) / 1e3),
  _Col('M_i (kNm)', 92, (s, m) => s.endForce(m, 2) / 1e3),
  _Col('max|M| (kNm)', 104, (s, m) => s.memberMaxM(m) / 1e3),
];

/// Virtualized, sortable member table (only visible rows are built, so 20,100 rows stay smooth).
class MemberTable extends StatefulWidget {
  const MemberTable({super.key, required this.state});
  final AppState state;

  @override
  State<MemberTable> createState() => _MemberTableState();
}

class _MemberTableState extends State<MemberTable> {
  int _sortCol = 0;
  bool _asc = true;
  List<int> _order = const [];
  int _orderVersion = -1;
  int _orderCount = -1;
  Timer? _debounce;
  final _scroll = ScrollController();

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.addListener(_onState);
  }

  @override
  void dispose() {
    s.removeListener(_onState);
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // Result values change on every drag frame; refresh the table at most ~5x per second.
  void _onState() {
    if (_orderCount != s.memberCount) {
      _resort();
    } else if (_debounce?.isActive != true) {
      _debounce = Timer(const Duration(milliseconds: 200), () {
        if (mounted && _orderVersion != s.version) _resort();
      });
    }
  }

  void _resort() {
    final n = s.memberCount;
    final col = _cols[_sortCol];
    final keys = List<double>.generate(n, (m) => col.value(s, m));
    final order = List<int>.generate(n, (i) => i);
    order.sort((a, b) {
      final c = keys[a].compareTo(keys[b]);
      return _asc ? c : -c;
    });
    setState(() {
      _order = order;
      _orderVersion = s.version;
      _orderCount = n;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_orderCount != s.memberCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _orderCount != s.memberCount) _resort();
      });
    }
    final total = _cols.fold<double>(0, (a, c) => a + c.width);
    return Column(children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: total,
          child: Row(children: [
            for (var i = 0; i < _cols.length; i++)
              InkWell(
                onTap: () {
                  _asc = _sortCol == i ? !_asc : true;
                  _sortCol = i;
                  _resort();
                },
                child: Container(
                  width: _cols[i].width,
                  height: 30,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '${_cols[i].title}${_sortCol == i ? (_asc ? ' ▲' : ' ▼') : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                    overflow: TextOverflow.clip,
                    maxLines: 1,
                  ),
                ),
              ),
          ]),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.builder(
          controller: _scroll,
          itemExtent: 24,
          itemCount: _order.length,
          itemBuilder: (context, row) {
            final m = _order[row];
            final selected = s.selectedMember == m;
            return InkWell(
              onTap: () {
                s.selectedMember = m;
                s.touch();
              },
              child: Container(
                color: selected ? const Color(0x33D81B60) : (row.isEven ? null : const Color(0x0A000000)),
                child: Row(children: [
                  for (final c in _cols)
                    SizedBox(
                      width: c.width,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          s.solved || !c.needsResult ? c.value(s, m).toStringAsFixed(c.digits) : '-',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
                          maxLines: 1,
                        ),
                      ),
                    ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

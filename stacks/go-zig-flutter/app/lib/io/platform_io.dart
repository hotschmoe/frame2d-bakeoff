import 'dart:io';

import 'package:flutter/material.dart';

import '../engine/engine.dart';

/// `--bench=<mode>` on the command line selects a bench mode (SPEC 5.5).
String? benchMode(List<String> args) {
  for (final a in args) {
    if (a.startsWith('--bench=')) return a.substring(8);
  }
  return null;
}

/// Milliseconds since process start (measured inside the Go library from the OS process creation time).
double sinceStartMs(Engine e) => e.processAgeMs();

double? rssMb() => ProcessInfo.currentRss / (1024 * 1024);

/// BENCH lines go to stdout on desktop.
void emitBench(String line) {
  stdout.writeln(line);
}

Future<void> finishBench() async {
  await stdout.flush();
  exit(0);
}

Future<String?> _askPath(BuildContext context, String title, String initial) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 480, child: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'File path'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

/// Desktop open: ask for a path (no file-picker plugin) and read it.
Future<String?> openJsonFile(BuildContext context) async {
  final path = await _askPath(context, 'Open model JSON', 'model.json');
  if (path == null || path.isEmpty) return null;
  return File(path).readAsString();
}

Future<void> saveJsonFile(BuildContext context, String name, String content) async {
  final path = await _askPath(context, 'Save model JSON', name);
  if (path == null || path.isEmpty) return;
  await File(path).writeAsString(content);
}

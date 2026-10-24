import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../engine/engine.dart';

/// `?bench=<mode>` in the page URL selects a bench mode (SPEC 5.5).
String? benchMode(List<String> args) => Uri.base.queryParameters['bench'];

/// Milliseconds since navigation start.
double sinceStartMs(Engine e) => web.window.performance.now();

double? rssMb() => null;

/// BENCH lines go to console.log on web (Dart's print).
void emitBench(String line) {
  // ignore: avoid_print
  print(line);
}

Future<void> finishBench() async {}

/// Web open: a hidden <input type=file>.
Future<String?> openJsonFile(BuildContext context) {
  final done = Completer<String?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.json,application/json';
  input.onchange = ((web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) {
      done.complete(null);
      return;
    }
    files.item(0)!.text().toDart.then((t) => done.complete(t.toDart));
  }).toJS;
  input.click();
  return done.future;
}

/// Web save: a Blob download.
Future<void> saveJsonFile(BuildContext context, String name, String content) async {
  final blob = web.Blob([content.toJS].toJS, web.BlobPropertyBag(type: 'application/json'));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  a.click();
  web.URL.revokeObjectURL(url);
}

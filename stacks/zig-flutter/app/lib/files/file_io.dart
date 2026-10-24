import 'package:file_selector/file_selector.dart';

import 'save_stub.dart'
    if (dart.library.js_interop) 'save_web.dart'
    if (dart.library.io) 'save_native.dart' as saver;

const _jsonType = XTypeGroup(label: 'Frame2D model', extensions: ['json']);

/// Lets the user pick a model JSON file and returns its text, or null when cancelled.
Future<String?> openModelText() async {
  final file = await openFile(acceptedTypeGroups: const [_jsonType]);
  return file?.readAsString();
}

/// Saves [text] as a JSON file (a save dialog on desktop, a download on web).
Future<void> saveModelText(String suggestedName, String text) => saver.saveText(suggestedName, text);

/// Open and save model JSON through the platform file dialogs.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Lets the user pick a model file; returns its name and text, or null when cancelled.
Future<({String name, String text})?> pickModelFile() async {
  final file = await FilePicker.pickFile(
    dialogTitle: 'Open model',
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return (name: file.name, text: utf8.decode(bytes));
}

/// Saves model JSON; returns false when cancelled.
Future<bool> saveModelFile(String json) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: 'Save model',
    fileName: 'model.json',
    bytes: Uint8List.fromList(utf8.encode(json)),
    mimeType: 'application/json',
  );
  return uri != null;
}

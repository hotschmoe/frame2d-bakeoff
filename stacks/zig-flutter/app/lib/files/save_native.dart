import 'dart:io';

import 'package:file_selector/file_selector.dart';

Future<void> saveText(String suggestedName, String text) async {
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: const [XTypeGroup(label: 'Frame2D model', extensions: ['json'])],
  );
  if (location == null) return;
  await File(location.path).writeAsString(text);
}

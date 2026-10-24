import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Browsers cannot write to a chosen path, so saving is a download through a temporary link.
Future<void> saveText(String suggestedName, String text) async {
  final parts = [text.toJS].toJS;
  final options = JSObject()..['type'] = 'application/json'.toJS;
  final blob = (globalContext['Blob'] as JSFunction).callAsConstructor<JSObject>(parts, options);
  final url = (globalContext['URL'] as JSObject).callMethod<JSString>('createObjectURL'.toJS, blob).toDart;
  final document = globalContext['document'] as JSObject;
  final a = document.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
  a['href'] = url.toJS;
  a['download'] = suggestedName.toJS;
  a.callMethod('click'.toJS);
  (globalContext['URL'] as JSObject).callMethod('revokeObjectURL'.toJS, url.toJS);
}

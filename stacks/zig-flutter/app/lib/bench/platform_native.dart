import 'dart:io';

String? benchModeFrom(List<String> args) {
  for (var k = 0; k < args.length; k++) {
    final a = args[k];
    if (a.startsWith('--bench=')) return a.substring('--bench='.length);
    if (a == '--bench' && k + 1 < args.length) return args[k + 1];
  }
  return null;
}

String? benchParam(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

void benchEmit(String line) {
  stdout.writeln(line);
  final path = Platform.environment['F2D_BENCH_OUT'];
  if (path != null && path.isNotEmpty) {
    File(path).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }
}

void benchFinish() {
  stdout.flush().whenComplete(() => exit(0));
}

double? residentMemoryMb() => ProcessInfo.currentRss / (1024 * 1024);

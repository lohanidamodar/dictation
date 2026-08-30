import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Drives the real hotkey against the real app, many times over.
///
/// The bugs that mattered here were not ones a unit test could reach: the app
/// died after a few cycles, or after sitting idle, because of how Windows
/// schedules threads. Only pressing the key repeatedly, with varying gaps in
/// between, finds that — so this does exactly that and reads the app's own
/// trace to decide whether each round completed.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('exe', defaultsTo: r'C:\dev\dictate-oss.exe')
    ..addOption('rounds', defaultsTo: '8')
    ..addOption('hold', defaultsTo: '1500', help: 'Hotkey hold, ms.')
    ..addOption('gaps',
        defaultsTo: '1000,2000,5000,15000,30000',
        help: 'Idle gaps to cycle through, ms. Long ones matter most.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln('Usage: dart tool/soak.dart [options]\n${parser.usage}');
    return;
  }

  final rounds = int.parse(args.option('rounds')!);
  final hold = Duration(milliseconds: int.parse(args.option('hold')!));
  final gaps = args
      .option('gaps')!
      .split(',')
      .map((g) => Duration(milliseconds: int.parse(g.trim())))
      .toList();

  final trace = File('${Directory.systemTemp.path}\\soak-trace.log');
  if (trace.existsSync()) trace.deleteSync();

  stdout.writeln('starting ${args.option('exe')}');
  final app = await Process.start(
    args.option('exe')!,
    ['--console', '--yes', '--trace', trace.path],
  );
  app.stdout.drain<void>();
  app.stderr.transform(const SystemEncoding().decoder).listen(stderr.write);

  var failed = 0;
  try {
    if (!await _waitFor(trace, 'load.done', const Duration(minutes: 3))) {
      stderr.writeln('the app never finished loading');
      exitCode = 1;
      return;
    }
    stdout.writeln('loaded\n');

    for (var round = 1; round <= rounds; round++) {
      final gap = gaps[(round - 1) % gaps.length];
      final mark = trace.lengthSync();

      _holdHotkey(hold);
      final done = await _waitFor(
        trace,
        RegExp(r'\b(idle|error)\b'),
        const Duration(seconds: 45),
        from: mark,
      );

      final steps = _stepsSince(trace, mark);
      final ok = done && steps.any((s) => s.contains('transcribe.done'));
      if (!ok) failed++;
      stdout.writeln('round $round  ${ok ? "ok " : "FAIL"}  '
          'gap ${gap.inSeconds}s  ${steps.join(" → ")}');

      // A process that has died stops writing; catching it here says which
      // round killed it rather than leaving every later round to time out.
      if (!_isRunning(app.pid)) {
        stderr.writeln('the app is gone after round $round');
        failed++;
        break;
      }
      sleep(gap);
    }
  } finally {
    app.kill();
    await app.exitCode.timeout(const Duration(seconds: 10), onTimeout: () => -1);
  }

  stdout.writeln('\n${rounds - failed}/$rounds rounds completed');
  if (failed > 0) exitCode = 1;
}

/// Presses and releases the hotkey the way a person would.
///
/// Down, wait, up — three separate injections — because the app distinguishes
/// a press from a release and the whole point is to exercise a real hold. Key
/// codes rather than characters here: this has to reach `RegisterHotKey`,
/// which sees keys, not text.
void _holdHotkey(Duration hold) {
  const d = VIRTUAL_KEY(0x44);
  for (final key in [VK_CONTROL, VK_MENU, d]) {
    _key(key, down: true);
  }
  sleep(hold);
  for (final key in [d, VK_MENU, VK_CONTROL]) {
    _key(key, down: false);
  }
}

void _key(VIRTUAL_KEY virtualKey, {required bool down}) {
  final input = calloc<INPUT>();
  try {
    input.ref.type = INPUT_KEYBOARD;
    input.ref.ki.wVk = virtualKey;
    input.ref.ki.dwFlags =
        down ? const KEYBD_EVENT_FLAGS(0) : KEYEVENTF_KEYUP;
    SendInput(1, input, sizeOf<INPUT>());
  } finally {
    calloc.free(input);
  }
}

Future<bool> _waitFor(
  File trace,
  Pattern wanted,
  Duration limit, {
  int from = 0,
}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (trace.existsSync() && _since(trace, from).contains(wanted)) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

String _since(File trace, int from) {
  final raf = trace.openSync()..setPositionSync(from);
  try {
    return String.fromCharCodes(raf.readSync(raf.lengthSync() - from));
  } finally {
    raf.closeSync();
  }
}

List<String> _stepsSince(File trace, int from) => _since(trace, from)
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .map((line) => line.split('  ').last.trim())
    .toList();

/// Whether the app is still alive.
///
/// Asked through tasklist rather than a process handle: this needs a yes or a
/// no, and opening a handle to another process is more machinery than that
/// deserves.
bool _isRunning(int pid) {
  final result = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
  return '${result.stdout}'.contains('$pid');
}

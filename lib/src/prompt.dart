import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Asking the user something, from a program that usually has no window.
///
/// Started from a Start Menu shortcut there is no console: anything written to
/// stdout goes nowhere and `stdin` never answers, so a program that asks a
/// question that way simply hangs or silently assumes no. Started from a
/// terminal with `--console`, a dialog box would be the wrong thing. So the
/// caller says which it has, once, and the rest of the code just asks.
sealed class Prompter {
  const Prompter();

  /// Picks the way of asking that suits how the program was started.
  factory Prompter.forConsole({required bool hasConsole}) =>
      hasConsole ? const ConsolePrompter() : const WindowPrompter();

  /// Returns true only on a clear yes. Anything else — a closed dialog, a
  /// console that is not really there — is a no, because every question here
  /// precedes something irreversible or expensive.
  bool confirm(String title, String message);

  void tell(String title, String message);
}

class ConsolePrompter extends Prompter {
  const ConsolePrompter();

  @override
  bool confirm(String title, String message) {
    stdout.write('\n$title\n\n$message\n\nContinue? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    return answer == 'y' || answer == 'yes';
  }

  @override
  void tell(String title, String message) =>
      stderr.writeln('\n$title\n\n$message');
}

/// A plain Win32 message box.
///
/// Blocks the isolate that calls it, which is the point — the answer decides
/// what happens next. The tray icon lives on its own thread and stays alive
/// and responsive while this is up.
class WindowPrompter extends Prompter {
  const WindowPrompter();

  @override
  bool confirm(String title, String message) =>
      _show(title, message, MB_YESNO | MB_ICONQUESTION) == IDYES;

  @override
  void tell(String title, String message) =>
      _show(title, message, MB_OK | MB_ICONWARNING);

  MESSAGEBOX_RESULT _show(String title, String message, int style) {
    final text = message.toNativeUtf16();
    final caption = title.toNativeUtf16();
    try {
      // Foreground and topmost, because this can appear minutes after the
      // program was started and would otherwise open behind everything.
      return MessageBox(
        null,
        PCWSTR(text),
        PCWSTR(caption),
        MESSAGEBOX_STYLE(style | MB_SETFOREGROUND | MB_TOPMOST),
      ).value;
    } finally {
      calloc
        ..free(text)
        ..free(caption);
    }
  }
}

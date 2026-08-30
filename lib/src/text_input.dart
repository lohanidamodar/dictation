import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Types text into whatever control currently has focus, in any application.
///
/// `KEYEVENTF_UNICODE` sends the character itself rather than a key code, so
/// this is independent of the user's keyboard layout and handles Devanagari as
/// readily as ASCII — which matters, because the recogniser here produces both.
class TextInput {
  const TextInput({
    this.perCharacterDelay = const Duration(milliseconds: 2),
    this.settleDelay = const Duration(milliseconds: 120),
  });

  /// Pause between characters.
  ///
  /// Not politeness — necessity. Sending the whole string as one `SendInput`
  /// array reports every event delivered and then drops all but the first
  /// word: "Hello world 123" arrives as "Hello". One character per call, with
  /// a small gap, arrives intact. The API's success return cannot be trusted
  /// on a batch.
  final Duration perCharacterDelay;

  /// Time to let the hotkey's own modifiers come back up before typing.
  ///
  /// Ctrl or Alt still physically held will combine with the characters being
  /// injected and fire menu shortcuts in the target application instead.
  final Duration settleDelay;

  /// Sends [text] to the focused control. Returns how many characters landed.
  Future<int> type(String text) async {
    if (text.isEmpty) return 0;
    await Future<void>.delayed(settleDelay);

    // UTF-16 code units: a character outside the BMP is a surrogate pair and
    // is sent as two events, which is what the API expects.
    final units = text.codeUnits;
    var delivered = 0;

    for (final unit in units) {
      if (_sendUnit(unit)) delivered++;
      if (perCharacterDelay > Duration.zero) {
        await Future<void>.delayed(perCharacterDelay);
      }
    }
    return delivered;
  }

  bool _sendUnit(int unit) {
    final pair = calloc<INPUT>(2);
    try {
      for (var up = 0; up < 2; up++) {
        final input = pair + up;
        input.ref.type = INPUT_KEYBOARD;
        input.ref.ki.wScan = unit;
        input.ref.ki.dwFlags =
            up == 1 ? KEYEVENTF_UNICODE | KEYEVENTF_KEYUP : KEYEVENTF_UNICODE;
      }
      return SendInput(2, pair, sizeOf<INPUT>()).value == 2;
    } finally {
      calloc.free(pair);
    }
  }
}

/// The title of the window that will receive typed text.
///
/// Only for showing the user where their words are about to go; nothing
/// depends on it.
String focusedWindowTitle() {
  final window = GetForegroundWindow();
  final buffer = wsalloc(256);
  try {
    final length = GetWindowText(window, buffer, 256).value;
    return length > 0 ? buffer.toDartString() : '';
  } finally {
    free(buffer);
  }
}

/// Brings an already-open window to the front, if one is showing [file].
///
/// So "Edit settings" does not pile up a new editor window every time it is
/// clicked. Matched on the title, because launching through the shell hands
/// the file to whichever editor is associated with it and returns before that
/// editor has a window — there is no process id to hold on to.
///
/// Returns false when no such window is open, which is the caller's cue to
/// launch one.
bool focusWindowShowing(String file) {
  final name = file.split(RegExp(r'[\\/]')).last;
  if (name.isEmpty) return false;

  final buffer = wsalloc(256);
  try {
    var window = GetTopWindow(null).value;
    while (window != nullptr) {
      if (IsWindowVisible(window)) {
        final length = GetWindowText(window, buffer, 256).value;
        // "config.json - Notepad", and every editor's variation on it.
        if (length > 0 && buffer.toDartString().startsWith(name)) {
          // A process may not raise another's window unless it is allowed to;
          // showing it first covers the case where it is minimised.
          ShowWindow(window, SW_RESTORE);
          SetForegroundWindow(window);
          return true;
        }
      }
      window = GetWindow(window, GW_HWNDNEXT).value;
    }
    return false;
  } finally {
    free(buffer);
  }
}

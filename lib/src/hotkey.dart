/// A key combination, as Windows understands it.
class Hotkey {
  const Hotkey({required this.key, required this.modifiers, this.label = ''});

  /// A virtual key code — `VK_D` and friends.
  final int key;

  /// `MOD_CONTROL | MOD_ALT` and so on.
  final int modifiers;

  /// How to describe it to the user.
  final String label;

  /// Ctrl+Alt+D. Chosen because Windows itself and the common editors leave it
  /// alone; Win+key is reserved and Ctrl+Shift+letter collides constantly.
  static const defaultKey = Hotkey(
    key: 0x44, // VK_D
    modifiers: modControl | modAlt,
    label: 'Ctrl+Alt+D',
  );

  static const modAlt = 1;
  static const modControl = 2;
  static const modShift = 4;
  static const modWin = 8;
}

/// Reads a combination written the way a person would: `Ctrl+Alt+D`.
///
/// Returns null rather than throwing — this parses a config file someone
/// hand-edited, and a typo there should degrade to the default rather than
/// stop the program from starting.
Hotkey? parseHotkey(String spelled) {
  final parts = spelled
      .split('+')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;

  var modifiers = 0;
  String? keyName;
  for (final part in parts) {
    switch (part.toLowerCase()) {
      case 'ctrl' || 'control':
        modifiers |= Hotkey.modControl;
      case 'alt':
        modifiers |= Hotkey.modAlt;
      case 'shift':
        modifiers |= Hotkey.modShift;
      case 'win' || 'super' || 'meta':
        modifiers |= Hotkey.modWin;
      default:
        // The last non-modifier wins; "Ctrl+A+B" is a typo, not two keys.
        keyName = part;
    }
  }
  if (keyName == null) return null;

  final key = _virtualKey(keyName);
  if (key == null) return null;

  // A bare key with no modifier would swallow that key system-wide.
  if (modifiers == 0) return null;

  return Hotkey(key: key, modifiers: modifiers, label: _spell(modifiers, keyName));
}

String _spell(int modifiers, String key) => [
      if (modifiers & Hotkey.modControl != 0) 'Ctrl',
      if (modifiers & Hotkey.modAlt != 0) 'Alt',
      if (modifiers & Hotkey.modShift != 0) 'Shift',
      if (modifiers & Hotkey.modWin != 0) 'Win',
      key.length == 1 ? key.toUpperCase() : _titleCase(key),
    ].join('+');

String _titleCase(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

/// Virtual key code for a named key.
int? _virtualKey(String name) {
  final n = name.toLowerCase();
  if (n.length == 1) {
    final c = n.codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7A) return c - 0x20; // a-z -> VK_A..VK_Z
    if (c >= 0x30 && c <= 0x39) return c; // 0-9
  }
  return const <String, int>{
    'space': 0x20,
    'enter': 0x0D,
    'return': 0x0D,
    'tab': 0x09,
    'escape': 0x1B,
    'esc': 0x1B,
    'backspace': 0x08,
    'insert': 0x2D,
    'delete': 0x2E,
    'home': 0x24,
    'end': 0x23,
    'pageup': 0x21,
    'pagedown': 0x22,
    'left': 0x25,
    'up': 0x26,
    'right': 0x27,
    'down': 0x28,
    'f1': 0x70, 'f2': 0x71, 'f3': 0x72, 'f4': 0x73,
    'f5': 0x74, 'f6': 0x75, 'f7': 0x76, 'f8': 0x77,
    'f9': 0x78, 'f10': 0x79, 'f11': 0x7A, 'f12': 0x7B,
  }[n];
}

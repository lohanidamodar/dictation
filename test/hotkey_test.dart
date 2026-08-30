import 'package:dictation/dictation.dart';
import 'package:test/test.dart';

void main() {
  group('reads what a person would write', () {
    test('the ordinary case', () {
      final hotkey = parseHotkey('Ctrl+Alt+D')!;
      expect(hotkey.key, 0x44);
      expect(hotkey.modifiers, Hotkey.modControl | Hotkey.modAlt);
      expect(hotkey.label, 'Ctrl+Alt+D');
    });

    test('is not fussy about case or spacing', () {
      expect(parseHotkey('  ctrl + ALT + d ')!.label, 'Ctrl+Alt+D');
    });

    test('accepts the other names people use for a modifier', () {
      expect(parseHotkey('control+shift+space')!.modifiers,
          Hotkey.modControl | Hotkey.modShift);
      for (final spelling in ['win', 'super', 'meta']) {
        expect(parseHotkey('$spelling+alt+k')!.modifiers & Hotkey.modWin,
            Hotkey.modWin,
            reason: spelling);
      }
    });

    test('named keys, and function keys', () {
      expect(parseHotkey('Ctrl+Alt+Space')!.key, 0x20);
      expect(parseHotkey('Ctrl+Alt+F9')!.key, 0x78);
      expect(parseHotkey('Ctrl+Shift+PageDown')!.key, 0x22);
      expect(parseHotkey('Alt+7')!.key, 0x37);
    });

    test('spells the label back in a fixed order', () {
      // So two configs meaning the same thing look the same in the tray.
      expect(parseHotkey('alt+ctrl+shift+d')!.label, 'Ctrl+Alt+Shift+D');
      expect(parseHotkey('ctrl+alt+space')!.label, 'Ctrl+Alt+Space');
    });
  });

  group('refuses rather than doing something surprising', () {
    test('a bare key, which would swallow that key everywhere', () {
      // Registering "D" system-wide would take the letter away from every
      // other program on the machine.
      expect(parseHotkey('D'), isNull);
      expect(parseHotkey('Space'), isNull);
    });

    test('modifiers with nothing to press', () {
      expect(parseHotkey('Ctrl+Alt'), isNull);
      expect(parseHotkey(''), isNull);
      expect(parseHotkey('+++'), isNull);
    });

    test('a key it does not know', () {
      expect(parseHotkey('Ctrl+Alt+Nonsense'), isNull);
      expect(parseHotkey('Ctrl+Alt+F13'), isNull);
    });
  });

  test('two keys is a typo, and the last one wins', () {
    // Windows registers one key per combination, so this has to resolve to
    // something rather than fail — but it should resolve predictably.
    expect(parseHotkey('Ctrl+A+B')!.key, 0x42);
  });
}

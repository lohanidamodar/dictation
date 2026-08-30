import 'dart:convert';
import 'dart:io';

import 'package:dictation/dictation.dart';
import 'package:test/test.dart';

void main() {
  group('parseHotkey', () {
    test('reads a combination the way a person writes it', () {
      final hotkey = parseHotkey('Ctrl+Alt+D')!;
      expect(hotkey.key, 0x44);
      expect(hotkey.modifiers, Hotkey.modControl | Hotkey.modAlt);
      expect(hotkey.label, 'Ctrl+Alt+D');
    });

    test('ignores spacing and case', () {
      expect(parseHotkey('  ctrl + SHIFT + space ')!.label, 'Ctrl+Shift+Space');
    });

    test('accepts named keys and function keys', () {
      expect(parseHotkey('Ctrl+F9')!.key, 0x78);
      expect(parseHotkey('Alt+Space')!.key, 0x20);
      expect(parseHotkey('Ctrl+Alt+Delete')!.key, 0x2E);
    });

    test('accepts Win as a modifier', () {
      expect(parseHotkey('Win+Alt+K')!.modifiers,
          Hotkey.modWin | Hotkey.modAlt);
    });

    test('refuses a bare key, which would swallow it system-wide', () {
      // Registering "D" alone would take the letter from every application.
      expect(parseHotkey('D'), isNull);
      expect(parseHotkey('Space'), isNull);
    });

    test('refuses modifiers with no key', () {
      expect(parseHotkey('Ctrl+Alt'), isNull);
      expect(parseHotkey(''), isNull);
    });

    test('refuses a key it does not know', () {
      expect(parseHotkey('Ctrl+Banana'), isNull);
    });

    test('spells the label back in a canonical order', () {
      // However the user wrote it, the label reads the same way.
      expect(parseHotkey('alt+ctrl+d')!.label, 'Ctrl+Alt+D');
    });
  });

  group('DictationConfig', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dictation'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes a default file on first run', () async {
      final path = '${dir.path}/config.json';
      final config = await DictationConfig.loadOrCreate(path);

      expect(File(path).existsSync(), isTrue);
      expect(config.hotkey.label, 'Ctrl+Alt+D');
      // The file documents itself; the tray's "Edit settings" opens it.
      expect(File(path).readAsStringSync(), contains('Modifiers'));
    });

    test('survives a round trip', () async {
      final path = '${dir.path}/config.json';
      const original = DictationConfig(
        modelId: 'sense-voice-small',
        spokenPunctuation: true,
        showOverlay: false,
        minimumSeconds: 0.5,
      );
      await original.save(path);

      final back = await DictationConfig.loadOrCreate(path);
      expect(back.modelId, 'sense-voice-small');
      expect(back.spokenPunctuation, isTrue);
      expect(back.showOverlay, isFalse);
      expect(back.minimumSeconds, 0.5);
    });

    test('reads a hotkey the user edited by hand', () async {
      final path = '${dir.path}/config.json';
      File(path).writeAsStringSync(
        jsonEncode({'hotkey': {'key': 'Ctrl+Shift+Space'}}),
      );
      final config = await DictationConfig.loadOrCreate(path);
      expect(config.hotkey.label, 'Ctrl+Shift+Space');
    });

    test('falls back on a typo rather than refusing to start', () async {
      // Being unable to launch because of a typo is worse than launching on
      // the default and saying so.
      final path = '${dir.path}/config.json';
      File(path).writeAsStringSync(jsonEncode({'hotkey': {'key': 'Ctrl+???'}}));

      final config = await DictationConfig.loadOrCreate(path);
      expect(config.hotkey.label, 'Ctrl+Alt+D');
    });

    test('survives a malformed file', () async {
      final path = '${dir.path}/config.json';
      File(path).writeAsStringSync('{ not json at all');
      expect((await DictationConfig.loadOrCreate(path)).hotkey.label,
          'Ctrl+Alt+D');
    });

    test('names a model from the shared catalog', () {
      // The id is the store's directory name, so a config naming a model that
      // is not in the catalog would silently fall back at load time.
      const config = DictationConfig();
      expect(modelById(config.modelId), isNotNull);
    });
  });
}

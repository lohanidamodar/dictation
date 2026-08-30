import 'dart:convert';
import 'dart:io';

import 'hotkey.dart';

/// Everything the user can change, in one file they can open and edit.
///
/// JSON rather than a settings dialog: this is a tray app with no window, and
/// a text file the tray can open in Notepad is both less to build and easier
/// to copy between machines.
class DictationConfig {
  const DictationConfig({
    this.hotkey = Hotkey.defaultKey,
    this.modelId = 'parakeet-tdt-0.6b-v3-int8',
    this.nativeLibraryDir,
    this.vocabularyPath,
    this.spokenPunctuation = false,
    this.showOverlay = true,
    this.minimumSeconds = 0.3,
  });

  final Hotkey hotkey;
  /// Which recogniser to use, by its id in the shared model catalog.
  final String modelId;

  /// Directory holding `sherpa-onnx-c-api.dll` and `onnxruntime.dll`.
  final String? nativeLibraryDir;

  /// Corrections file; defaults to one beside the model store.
  final String? vocabularyPath;

  /// Treat "comma" and friends as the marks they name. Off by default — it is
  /// right for dictating notes and wrong the moment someone dictates prose
  /// about punctuation.
  final bool spokenPunctuation;

  final bool showOverlay;

  /// Shorter than this counts as a slip of the finger, not speech.
  final double minimumSeconds;

  Map<String, dynamic> toJson() => {
        'hotkey': {
          'key': hotkey.label,
          '_comment': 'e.g. "Ctrl+Alt+D", "Ctrl+Shift+Space", "Alt+X". '
              'Modifiers: Ctrl, Alt, Shift, Win.',
        },
        'model': modelId,
        if (nativeLibraryDir != null) 'nativeLibraryDir': nativeLibraryDir,
        if (vocabularyPath != null) 'vocabularyPath': vocabularyPath,
        'spokenPunctuation': spokenPunctuation,
        'showOverlay': showOverlay,
        'minimumSeconds': minimumSeconds,
      };

  static DictationConfig fromJson(Map<String, dynamic> json) {
    final hotkeyJson = json['hotkey'];
    final spelled = hotkeyJson is Map<String, dynamic>
        ? '${hotkeyJson['key'] ?? ''}'
        : '${hotkeyJson ?? ''}';

    return DictationConfig(
      // An unparseable combination falls back rather than refusing to start:
      // being unable to launch because of a typo in a config file is a worse
      // failure than running on the default key and saying so.
      hotkey: parseHotkey(spelled) ?? Hotkey.defaultKey,
      modelId: '${json['model'] ?? 'parakeet-tdt-0.6b-v3-int8'}',
      nativeLibraryDir: json['nativeLibraryDir'] as String?,
      vocabularyPath: json['vocabularyPath'] as String?,
      spokenPunctuation: json['spokenPunctuation'] == true,
      showOverlay: json['showOverlay'] != false,
      minimumSeconds:
          (json['minimumSeconds'] as num?)?.toDouble() ?? 0.3,
    );
  }

  /// Reads the config, writing a default one if it is not there yet.
  ///
  /// Creating it on first run means the tray's "Edit settings" always has
  /// something to open, and the file itself documents the options.
  static Future<DictationConfig> loadOrCreate(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      const fresh = DictationConfig();
      await fresh.save(path);
      return fresh;
    }
    try {
      return fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      // Malformed JSON: run on defaults rather than not at all.
      return const DictationConfig();
    }
  }

  Future<void> save(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
  }

  /// Where the config lives when nothing else is specified.
  static String defaultPath() {
    final home = Platform.environment['APPDATA'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return '$home${Platform.pathSeparator}Dictation'
        '${Platform.pathSeparator}config.json';
  }
}

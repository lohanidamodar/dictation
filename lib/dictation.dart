/// Hold a hotkey, speak, and the words are typed into whatever has focus.
///
/// Windows only: it records through `waveIn`, types through `SendInput`, and
/// puts its tray icon and status pill up through ordinary Win32 windows — all
/// from pure Dart over FFI. No Flutter, no plugins.
library;

// The model catalog and store are part of this app's surface: [Recogniser]
// takes a `VoiceModel`, and callers need the licence on it.
export 'package:voice_models/voice_models.dart';

export 'src/config.dart';
export 'src/dictation.dart';
export 'src/hotkey.dart' show Hotkey, parseHotkey;
export 'src/microphone.dart';
export 'src/prompt.dart';
export 'src/stt/engine.dart';
export 'src/stt/native_runtime.dart';
export 'src/stt/recogniser.dart';
export 'src/stt/sherpa_init.dart';
export 'src/stt/sherpa_stt.dart';
export 'src/stt/spoken_punctuation.dart';
export 'src/stt/vocabulary.dart';
export 'src/text_input.dart';
export 'src/ui_host.dart';

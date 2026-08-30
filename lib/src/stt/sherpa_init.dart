import 'dart:ffi';
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Loads the native sherpa-onnx library for the calling isolate.
///
/// Bindings are per-isolate state, so every isolate that touches a sherpa
/// engine must call this — the STT and TTS workers do it themselves on start.
///
/// [nativeLibraryPath] is the directory holding `libsherpa-onnx-c-api.so`
/// (`.dylib` / `.dll`). Pass null in Flutter builds, where the plugin puts the
/// library somewhere the system loader already looks.
void initSherpaBindings([String? nativeLibraryPath]) {
  _pinOnnxRuntime(nativeLibraryPath);
  sherpa.initBindings(nativeLibraryPath);
}

/// Loads our own `onnxruntime.dll` before sherpa can ask for one.
///
/// Windows ships an `onnxruntime.dll` in System32 — ORT 1.17 at the time of
/// writing — and it wins the default search order over the newer one beside
/// sherpa. The version mismatch is not detected gracefully: the process prints
/// "ORT Version is: 1.17.1" and then dies with an access violation inside
/// `sherpa-onnx-c-api.dll`.
///
/// Loading ours by absolute path first puts it in the process before anything
/// searches, so the System32 copy is never reached. Once loaded it stays
/// loaded, which is why doing this per isolate is both necessary and cheap.
void _pinOnnxRuntime(String? nativeLibraryPath) {
  if (!Platform.isWindows || nativeLibraryPath == null) return;
  final ort = '$nativeLibraryPath${Platform.pathSeparator}onnxruntime.dll';
  if (File(ort).existsSync()) DynamicLibrary.open(ort);
}

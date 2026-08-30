import 'dart:io';

import 'package:voice_models/voice_models.dart';

/// Finds the sherpa-onnx native libraries.
///
/// These are not a model and cannot be downloaded from Hugging Face, so unlike
/// the weights they have to be put somewhere by hand once. Rather than making
/// that a required setting, the obvious places are searched: beside the
/// executable, which is what a zipped release looks like, then a shared
/// `runtime` directory beside the models, which is where several PopupBits
/// apps can find one copy.
///
/// Returns null when nothing is found, which leaves the loader to search the
/// system path — and, if that fails too, to say so with a useful message.
String? resolveNativeLibraryDir([String? configured]) {
  for (final candidate in nativeLibrarySearchPath(configured)) {
    if (hasNativeLibraries(candidate)) return candidate;
  }
  return null;
}

/// The places [resolveNativeLibraryDir] looks, in order.
List<String> nativeLibrarySearchPath([String? configured]) {
  final sep = Platform.pathSeparator;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return [
    if (configured != null && configured.trim().isNotEmpty) configured.trim(),
    exeDir,
    '$exeDir${sep}runtime',
    '${popupBitsDataDir()}${sep}runtime',
  ];
}

/// Whether a directory holds the two libraries that must load together.
///
/// Both are checked, not just the sherpa one: a directory with the C API but
/// no ONNX Runtime beside it loads and then crashes inside the recogniser,
/// because the system's own copy of ONNX Runtime wins the search order and is
/// usually a different version.
bool hasNativeLibraries(String dir) {
  final sep = Platform.pathSeparator;
  const names = {
    'windows': ['sherpa-onnx-c-api.dll', 'onnxruntime.dll'],
    'macos': ['libsherpa-onnx-c-api.dylib', 'libonnxruntime.dylib'],
    'linux': ['libsherpa-onnx-c-api.so', 'libonnxruntime.so'],
  };
  final wanted = names[Platform.operatingSystem] ?? const <String>[];
  if (wanted.isEmpty) return false;
  return wanted.every((name) => File('$dir$sep$name').existsSync());
}

/// What to tell someone who has not installed the libraries yet.
String missingNativeLibrariesMessage([String? configured]) {
  final looked = nativeLibrarySearchPath(configured)
      .map((p) => '  $p')
      .join('\n');
  return 'Could not find the sherpa-onnx libraries. Looked in:\n$looked\n\n'
      'Download the Windows shared libraries from\n'
      '  https://github.com/k2-fsa/sherpa-onnx/releases\n'
      'and put sherpa-onnx-c-api.dll and onnxruntime.dll in one of those '
      'directories. See the README.';
}

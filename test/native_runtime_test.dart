import 'dart:io';

import 'package:dictation/dictation.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('runtime'));
  tearDown(() => dir.deleteSync(recursive: true));

  File touch(String name) =>
      File('${dir.path}${Platform.pathSeparator}$name')..writeAsStringSync('');

  final libraries = switch (Platform.operatingSystem) {
    'windows' => ('sherpa-onnx-c-api.dll', 'onnxruntime.dll'),
    'macos' => ('libsherpa-onnx-c-api.dylib', 'libonnxruntime.dylib'),
    _ => ('libsherpa-onnx-c-api.so', 'libonnxruntime.so'),
  };

  group('finding the libraries', () {
    test('an empty directory does not count', () {
      expect(hasNativeLibraries(dir.path), isFalse);
    });

    test('the sherpa library alone does not count', () {
      // This is the trap worth a test: with the C API present but no ONNX
      // Runtime beside it, the system's own copy wins the search order and the
      // recogniser dies inside native code with an access violation.
      touch(libraries.$1);
      expect(hasNativeLibraries(dir.path), isFalse);
    });

    test('both together count', () {
      touch(libraries.$1);
      touch(libraries.$2);
      expect(hasNativeLibraries(dir.path), isTrue);
      expect(resolveNativeLibraryDir(dir.path), dir.path);
    });

    test('a configured directory without them is not used', () {
      expect(resolveNativeLibraryDir(dir.path), isNot(dir.path));
    });
  });

  group('the search path', () {
    test('prefers what was configured', () {
      expect(nativeLibrarySearchPath('C:/somewhere').first, 'C:/somewhere');
    });

    test('ignores a blank setting rather than searching an empty path', () {
      expect(nativeLibrarySearchPath('   ').first, isNot('   '));
      expect(nativeLibrarySearchPath(''), nativeLibrarySearchPath(null));
    });

    test('looks beside the executable, which is what a zip unpacks to', () {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      expect(nativeLibrarySearchPath(null), contains(exeDir));
    });

    test('looks in the shared runtime directory beside the models', () {
      // One copy for every PopupBits app, rather than one per app.
      expect(
        nativeLibrarySearchPath(null),
        contains(endsWith('${Platform.pathSeparator}runtime')),
      );
    });
  });

  test('the message names every place that was searched', () {
    final message = missingNativeLibrariesMessage(dir.path);
    for (final place in nativeLibrarySearchPath(dir.path)) {
      expect(message, contains(place));
    }
    expect(message, contains('github.com/k2-fsa/sherpa-onnx/releases'));
  });
}

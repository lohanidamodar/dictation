import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:http/http.dart' as http;

/// Builds the Windows release: a portable folder, and a zip of it.
///
/// The folder is also what the installer packages, so both artefacts come from
/// one place and cannot drift apart. Models are deliberately not included —
/// they are hundreds of megabytes, their licences are not ours to pass on, and
/// the app fetches them on first run after showing the terms.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('out', defaultsTo: 'build', help: 'Where to build.')
    ..addOption('sherpa',
        defaultsTo: 'v1.13.4',
        help: 'sherpa-onnx release to take the libraries from. Must match the '
            'sherpa_onnx package version in pubspec.yaml.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln('Usage: dart tool/package.dart [options]\n${parser.usage}');
    return;
  }

  if (!Platform.isWindows) {
    stderr.writeln('This packages a Windows build, so it has to run on '
        'Windows — `dart compile exe` produces a binary for the platform it '
        'runs on.');
    exitCode = 1;
    return;
  }

  final version = _version();
  final out = Directory(args.option('out')!);
  final stage = Directory('${out.path}\\dictation-$version-windows-x64');

  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);

  stdout.writeln('dictation $version → ${stage.path}\n');

  await _compile(stage);
  await _addNativeLibraries(stage, args.option('sherpa')!, out);
  _addDocuments(stage);

  final zip = File('${stage.path}.zip');
  _zip(stage, zip);

  stdout
    ..writeln('\n${_relative(zip)}  ${_size(zip.lengthSync())}')
    ..writeln('${_relative(stage)}\\  (what the installer packages)')
    ..writeln('\nNext: iscc installer\\dictation.iss /DVersion=$version');
}

/// The version in pubspec.yaml, which is the one source of it.
String _version() {
  final line = File('pubspec.yaml')
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('version:'), orElse: () => '');
  final version = line.split(':').last.trim();
  if (version.isEmpty) {
    throw StateError('No version in pubspec.yaml. Run this from the repo root.');
  }
  return version;
}

Future<void> _compile(Directory stage) async {
  stdout.writeln('compiling…');
  final result = await Process.run(
    'dart',
    ['compile', 'exe', 'bin/dictate.dart', '-o', '${stage.path}\\dictate.exe'],
    runInShell: true,
  );
  if (result.exitCode != 0) {
    stderr.writeln(result.stdout);
    stderr.writeln(result.stderr);
    throw StateError('the build failed');
  }
  stdout.writeln('  dictate.exe  '
      '${_size(File('${stage.path}\\dictate.exe').lengthSync())}');
}

/// Fetches the sherpa-onnx libraries and puts them beside the executable.
///
/// The MT build, so the static C runtime is inside the DLLs and nobody has to
/// install a Visual C++ redistributable first. The no-tts build, because
/// nothing here synthesises speech.
///
/// Both libraries have to travel together: Windows resolves `onnxruntime.dll`
/// by search order, and a stray copy in System32 otherwise wins and crashes
/// inside native code.
Future<void> _addNativeLibraries(
  Directory stage,
  String release,
  Directory out,
) async {
  const wanted = {'sherpa-onnx-c-api.dll', 'onnxruntime.dll'};
  final name = 'sherpa-onnx-$release-win-x64-shared-MT-Release-no-tts-lib'
      '.tar.bz2';
  final cached = File('${out.path}\\cache\\$name');

  if (!cached.existsSync()) {
    final url = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
        '$release/$name';
    stdout.writeln('downloading $name…');
    cached.parent.createSync(recursive: true);

    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw StateError('$url returned HTTP ${response.statusCode}. Check that '
          '$release is a real sherpa-onnx release.');
    }
    cached.writeAsBytesSync(response.bodyBytes);
  }

  final tar = TarDecoder().decodeBytes(
    BZip2Decoder().decodeBytes(cached.readAsBytesSync()),
  );

  final found = <String>{};
  for (final entry in tar.files) {
    final leaf = entry.name.split('/').last;
    if (!wanted.contains(leaf)) continue;
    File('${stage.path}\\$leaf').writeAsBytesSync(entry.content as List<int>);
    found.add(leaf);
    stdout.writeln('  $leaf  ${_size(entry.size)}');
  }

  final missing = wanted.difference(found);
  if (missing.isNotEmpty) {
    throw StateError('$name does not contain ${missing.join(", ")}. It holds: '
        '${tar.files.map((f) => f.name).join(", ")}');
  }
}

/// Copies the things a redistributed build is obliged to carry.
void _addDocuments(Directory stage) {
  for (final name in ['README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md']) {
    final source = File(name);
    if (!source.existsSync()) {
      throw StateError('$name is missing. The libraries in this package are '
          'redistributed under licences that require their notices to travel '
          'with them.');
    }
    source.copySync('${stage.path}\\$name');
  }
  stdout.writeln('  README.md, LICENSE, THIRD-PARTY-NOTICES.md');
}

void _zip(Directory stage, File zip) {
  final archive = Archive();
  final root = stage.path.split(Platform.pathSeparator).last;

  for (final entry in stage.listSync(recursive: true).whereType<File>()) {
    final relative = entry.path
        .substring(stage.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    final bytes = entry.readAsBytesSync();
    // Under a folder named for the release, so unzipping into Downloads does
    // not scatter four files across it.
    archive.addFile(ArchiveFile('$root/$relative', bytes.length, bytes));
  }

  final encoded = ZipEncoder().encode(archive);
  zip.writeAsBytesSync(encoded);
}

String _size(int bytes) => bytes >= 1048576
    ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).round()} KB';

String _relative(FileSystemEntity entity) =>
    entity.path.replaceFirst('${Directory.current.path}${Platform.pathSeparator}', '');

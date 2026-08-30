import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dictation/dictation.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Hold a hotkey, speak, and the words are typed wherever the cursor is.
///
/// Raw recognition, deliberately: the point is that the words appear while the
/// thought is still in the air. A language-model cleanup pass punctuates
/// better and costs a second or two, which is the wrong trade for dictation.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('config', help: 'Settings file. Defaults to %APPDATA%.')
    ..addOption('native-lib',
        help: 'Directory holding sherpa-onnx-c-api.dll and onnxruntime.dll.')
    ..addOption('models', help: 'Model store. Defaults to %LOCALAPPDATA%.')
    ..addOption('trace', help: 'Append a step-by-step trace here.')
    ..addFlag('list-models',
        negatable: false, help: 'Show the models and their licences.')
    ..addFlag('yes',
        abbr: 'y',
        negatable: false,
        help: 'Accept model licences without asking. Read them first.')
    ..addFlag('console',
        negatable: false, help: 'Log each turn to the terminal.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln('Usage: dictate [options]\n${parser.usage}');
    return;
  }

  final store = ModelStore(
    root: args.option('models') == null
        ? null
        : Directory(args.option('models')!),
  );

  if (args.flag('list-models')) {
    stdout.writeln('models: ${store.root.path}\n');
    for (final model in voiceModelCatalog) {
      stdout
        ..writeln('${store.has(model) ? "installed" : "         "}  '
            '${model.id.padRight(28)} ${model.sizeLabel.padLeft(9)}')
        ..writeln('            ${model.licence.summary}')
        ..writeln('            ${model.licence.url}');
    }
    store.dispose();
    return;
  }

  if (!Platform.isWindows) {
    stderr.writeln('Windows only: this records with waveIn and types with '
        'SendInput.');
    exitCode = 1;
    return;
  }

  // Only one copy may run. The hotkey belongs to whichever process registers
  // it first, so a second copy would start, quietly fail to register, and sit
  // there looking exactly like a broken one.
  if (!_claimSingleInstance()) {
    stderr.writeln('Dictation is already running — look for its tray icon.');
    exitCode = 1;
    return;
  }

  final configPath = args.option('config') ?? DictationConfig.defaultPath();
  final config = await DictationConfig.loadOrCreate(configPath);

  final app = DictationApp(
    config: config,
    configPath: configPath,
    store: store,
    nativeLibraryDir: args.option('native-lib') ?? config.nativeLibraryDir,
    acceptLicences: args.flag('yes'),
    verbose: args.flag('console'),
    tracePath: args.option('trace'),
  );

  await runZonedGuarded(app.run, (error, stack) {
    stderr.writeln('UNCAUGHT: $error\n$stack');
  });
}

/// Takes a named mutex, which Windows releases when the process ends.
///
/// Bound by hand because the win32 package does not surface CreateMutexW. The
/// handle is deliberately never closed: it should live exactly as long as the
/// process, and letting it go would let a second copy in.
bool _claimSingleInstance() {
  final createMutex = DynamicLibrary.open('kernel32.dll').lookupFunction<
      IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
      int Function(Pointer<Void>, int, Pointer<Utf16>)>('CreateMutexW');

  final name = r'Global\PopupBitsDictation'.toNativeUtf16();
  try {
    createMutex(nullptr, 1, name);
    return GetLastError() != WIN32_ERROR(ERROR_ALREADY_EXISTS);
  } finally {
    calloc.free(name);
  }
}

/// Owns the UI thread and the dictation loop.
class DictationApp {
  DictationApp({
    required this.config,
    required this.configPath,
    required this.store,
    this.nativeLibraryDir,
    this.acceptLicences = false,
    this.verbose = false,
    this.tracePath,
  });

  DictationConfig config;
  final String configPath;
  final ModelStore store;
  final String? nativeLibraryDir;

  /// Skip the licence prompt. Only ever set by `--yes`, never by default: a
  /// model's terms are the user's to accept, not the program's.
  final bool acceptLicences;

  final bool verbose;
  final String? tracePath;

  UiHost? _ui;
  Dictation? _dictation;
  SttEngine? _stt;
  bool _paused = false;
  final _quit = Completer<void>();

  Future<void> run() async {
    try {
      _ui = await UiHost.start(
        hotkeyModifiers: config.hotkey.modifiers,
        hotkeyKey: config.hotkey.key,
        hotkeyLabel: config.hotkey.label,
      );
    } on UiHostException catch (e) {
      stderr.writeln(e.message);
      exitCode = 1;
      return;
    }

    _ui!.events.listen(
      (event) => _guard('ui', () => _onUiEvent(event)),
      onError: (Object e) => _log('ui error: $e'),
    );

    await _load();
    await _quit.future;
    await _shutdown();
  }

  Future<void> _load() async {
    _ui?.setStatus(UiStatus.loading);
    _trace('load.begin');

    final model = modelById(config.modelId) ?? Recogniser.supported.first;
    final nativeDir = resolveNativeLibraryDir(nativeLibraryDir);
    if (nativeDir == null) {
      _ui?.setStatus(UiStatus.failed);
      stderr.writeln(missingNativeLibrariesMessage(nativeLibraryDir));
      _trace('load.no-native-libs');
      return;
    }
    final recogniser = Recogniser(store: store, nativeLibraryDir: nativeDir);

    try {
      _stt = await recogniser.open(
        model,
        onLicence: _confirmLicence,
        onProgress: (p) {
          if (verbose && (p.fraction * 100).round() % 10 == 0) {
            stdout.writeln('  ${(p.fraction * 100).round()}%  ${p.file}');
          }
        },
      );
    } on ModelDeclined catch (e) {
      _ui?.setStatus(UiStatus.failed);
      stderr.writeln('$e');
      return;
    } catch (e) {
      _ui?.setStatus(UiStatus.failed);
      _log('could not load ${model.name}: $e');
      return;
    }

    final vocabulary = await Vocabulary.load(config.vocabularyPath ??
        '${store.root.path}${Platform.pathSeparator}vocabulary.json');

    final dictation = Dictation(
      stt: _stt!,
      vocabulary: vocabulary,
      punctuation:
          config.spokenPunctuation ? const SpokenPunctuation() : null,
      minimumSeconds: config.minimumSeconds,
      ownsStt: false,
    )..onTrace = _trace;

    _dictation = dictation;
    dictation.events.listen(
      (event) => _guard('event', () => _onDictationEvent(event)),
      onError: (Object e) => _log('event error: $e'),
    );

    _ui?.setStatus(UiStatus.ready);
    _trace('load.done');
    if (verbose) {
      stdout
        ..writeln('${model.name} — ${model.licence.name}')
        ..writeln('Hold ${config.hotkey.label} and speak. '
            'Settings: $configPath');
    }
  }

  /// Asks before downloading weights.
  ///
  /// The terms are the publisher's, not ours, and one of the models here is
  /// not under an open-source licence at all. Printing the licence and waiting
  /// is the least this can do.
  Future<bool> _confirmLicence(VoiceModel model) async {
    if (acceptLicences) return true;

    stdout
      ..writeln('\n${model.name} — ${model.sizeLabel}')
      ..writeln('  licence: ${model.licence.name}')
      ..writeln('  terms:   ${model.licence.url}')
      ..writeln('  source:  ${model.source}');
    if (model.licence.notes case final notes?) {
      stdout.writeln('  note:    $notes');
    }
    if (model.licence.attribution case final credit?) {
      stdout.writeln('  credit:  $credit');
    }
    stdout.write('\nDownload it? [y/N] ');

    final answer = stdin.readLineSync()?.trim().toLowerCase();
    return answer == 'y' || answer == 'yes';
  }

  void _onUiEvent(UiEvent event) {
    switch (event) {
      case UiHotkeyPressed():
        if (!_paused) _dictation?.onHotkeyPressed();
      case UiHotkeyReleased():
        if (!_paused) {
          unawaited(_dictation?.onHotkeyReleased() ?? Future<void>.value());
        }
      case UiMenuChosen(:final id):
        unawaited(_onMenu(id));
      case UiFailed(:final message):
        _log('ui: $message');
      case UiReady():
        break;
    }
  }

  void _onDictationEvent(DictationEvent event) {
    final ui = _ui;
    switch (event) {
      case DictationListening(:final target):
        ui
          ?..setStatus(UiStatus.listening)
          ..showOverlay(UiOverlayState.listening);
        if (verbose) {
          stdout.writeln('listening → ${target.isEmpty ? "?" : target}');
        }

      case DictationLevel(:final level):
        ui?.showOverlay(UiOverlayState.listening, level: level);

      case DictationRecognising():
        ui
          ?..setStatus(UiStatus.recognising)
          ..showOverlay(UiOverlayState.working);

      case DictationTyped(:final text, :final elapsed):
        ui
          ?..setStatus(UiStatus.ready)
          ..hideOverlay();
        if (verbose) stdout.writeln('${elapsed.inMilliseconds}ms  "$text"');

      case DictationNothingHeard():
        ui
          ?..setStatus(UiStatus.ready)
          ..hideOverlay();
        if (verbose) stdout.writeln('nothing heard');

      case DictationFailed(:final message):
        ui?.showOverlay(UiOverlayState.failed);
        // Left up for a moment: an error that vanishes instantly is one the
        // user never gets to read.
        Timer(const Duration(seconds: 3), () {
          ui
            ?..setStatus(UiStatus.ready)
            ..hideOverlay();
        });
        _log('error: $message');
    }
  }

  Future<void> _onMenu(int id) async {
    switch (id) {
      case UiMenu.pause:
        _paused = !_paused;
        _dictation?.enabled = !_paused;
        _ui?.setStatus(
          _paused ? UiStatus.paused : UiStatus.ready,
          paused: _paused,
        );

      case UiMenu.settings:
        // Raise the editor if it is already open on this file, rather than
        // opening another window on top of the last one.
        if (!focusWindowShowing(configPath)) {
          await Process.start(
            'cmd',
            ['/c', 'start', '', configPath],
            mode: ProcessStartMode.detached,
          );
        }

      case UiMenu.reload:
        await _reload();

      case UiMenu.quit:
        if (!_quit.isCompleted) _quit.complete();
    }
  }

  /// Applies an edited settings file without restarting.
  ///
  /// Everything except the hotkey can be rebuilt in place. The hotkey belongs
  /// to the UI thread, so changing it needs a restart — said out loud rather
  /// than silently ignoring the new value.
  Future<void> _reload() async {
    _ui?.setStatus(UiStatus.loading);
    final previous = config.hotkey.label;

    await _dictation?.dispose();
    _dictation = null;
    await _stt?.dispose();
    _stt = null;

    config = await DictationConfig.loadOrCreate(configPath);
    if (config.hotkey.label != previous) {
      _log('hotkey changed to ${config.hotkey.label}; restart to apply it');
    }
    await _load();
  }

  void _guard(String what, FutureOr<void> Function() body) {
    try {
      final result = body();
      if (result is Future<void>) {
        result.catchError((Object e) => _log('$what failed: $e'));
      }
    } catch (e) {
      _log('$what failed: $e');
    }
  }

  void _log(String message) {
    if (verbose) stderr.writeln(message);
    _trace(message);
  }

  /// Appends a step to the trace file, flushed immediately.
  ///
  /// A native crash takes the process without unwinding, so buffered output is
  /// lost. Each line is written and closed on its own for that reason.
  void _trace(String step) {
    final path = tracePath;
    if (path == null) return;
    try {
      File(path).writeAsStringSync(
        '${DateTime.now().toIso8601String()}  $step\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Tracing must never be the thing that breaks the run.
    }
  }

  Future<void> _shutdown() async {
    await _dictation?.dispose();
    await _stt?.dispose();
    await _ui?.dispose();
    store.dispose();
  }
}

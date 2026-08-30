import 'dart:async';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'engine.dart';
import 'sherpa_init.dart';

/// Which sherpa-onnx recogniser family to build. All are non-streaming: the
/// VAD has already cut the audio into utterances by the time we decode.
enum SttModelKind { senseVoice, whisper, nemoCtc, transducer }

/// Sendable recogniser description. Native handles can't cross isolates, so the
/// worker is given paths and builds its own recogniser on the other side.
class SttConfig {
  const SttConfig.senseVoice({
    required this.model,
    required this.tokens,
    this.language = '',
    this.numThreads = 2,
    this.nativeLibraryPath,
  }) : kind = SttModelKind.senseVoice,
       encoder = '',
       decoder = '',
       joiner = '';

  const SttConfig.whisper({
    required this.encoder,
    required this.decoder,
    required this.tokens,
    this.language = 'en',
    this.numThreads = 2,
    this.nativeLibraryPath,
  }) : kind = SttModelKind.whisper,
       model = '',
       joiner = '';

  /// NeMo Conformer-CTC — the family AI4Bharat's IndicConformer belongs to,
  /// which is how Nepali and Sanskrit get a dedicated recogniser rather than a
  /// multilingual model's long tail. Export the `.nemo` checkpoint to ONNX
  /// first; see `tool/export_indicconformer.py`.
  const SttConfig.nemoCtc({
    required this.model,
    required this.tokens,
    this.numThreads = 2,
    this.nativeLibraryPath,
  }) : kind = SttModelKind.nemoCtc,
       encoder = '',
       decoder = '',
       joiner = '',
       language = '';

  /// NeMo transducer — the family Parakeet TDT belongs to.
  ///
  /// Worth the extra weight for English: it punctuates and capitalises as it
  /// decodes, so the text arrives closer to readable than a CTC model's
  /// unbroken stream, and there is that much less for a cleanup pass to guess
  /// at afterwards. Three files rather than one, because a transducer decodes
  /// with an encoder, a prediction network and a joiner.
  const SttConfig.transducer({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    this.numThreads = 2,
    this.nativeLibraryPath,
  }) : kind = SttModelKind.transducer,
       model = '',
       language = '';

  final SttModelKind kind;
  final String model;
  final String encoder;
  final String decoder;

  /// Transducer only.
  final String joiner;

  final String tokens;
  final String language;
  final int numThreads;

  /// Directory holding `libsherpa-onnx-c-api.*`. Null uses the system loader
  /// path, which is what Flutter builds rely on.
  final String? nativeLibraryPath;
}

/// STT running on a dedicated long-lived isolate.
///
/// Decoding is a blocking FFI call that can take hundreds of milliseconds, so
/// it must not share an isolate with the audio loop. The isolate owns its
/// recogniser for its whole life — model load is far too expensive per call.
class SherpaSttEngine implements SttEngine {
  SherpaSttEngine._(
    this._isolate,
    this._fromWorker,
    this._toWorker,
    this._responses,
  );

  static Future<SherpaSttEngine> spawn(SttConfig config) async {
    final fromWorker = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, (
      fromWorker.sendPort,
      config,
    ), debugName: 'stt');

    final responses = StreamController<(int, String)>.broadcast();
    final toWorker = Completer<SendPort>();

    fromWorker.listen((msg) {
      switch (msg) {
        case SendPort p:
          toWorker.complete(p);
        case (int id, String text):
          responses.add((id, text));
      }
    });

    return SherpaSttEngine._(
      isolate,
      fromWorker,
      await toWorker.future,
      responses,
    );
  }

  final Isolate _isolate;

  /// Held so [dispose] can close it — an open ReceivePort keeps the VM's event
  /// loop alive, so leaving it open stops the process from ever exiting.
  final ReceivePort _fromWorker;

  final SendPort _toWorker;
  final StreamController<(int, String)> _responses;
  int _nextId = 0;

  @override
  Future<String> transcribe(AudioChunk samples) async {
    final id = _nextId++;
    final result = _responses.stream.firstWhere((r) => r.$1 == id);
    _toWorker.send((id, samples));
    return (await result).$2;
  }

  @override
  Future<void> dispose() async {
    await _responses.close();
    _isolate.kill(priority: Isolate.immediate);
    _fromWorker.close();
  }

  static void _workerMain((SendPort, SttConfig) args) {
    final (toMain, config) = args;

    initSherpaBindings(config.nativeLibraryPath);
    final recognizer = sherpa.OfflineRecognizer(_buildConfig(config));

    final inbox = ReceivePort();
    toMain.send(inbox.sendPort);

    inbox.listen((msg) {
      final (id, samples) = msg as (int, AudioChunk);
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: kSampleRate);
        recognizer.decode(stream);
        toMain.send((id, recognizer.getResult(stream).text.trim()));
      } finally {
        stream.free();
      }
    });
  }

  static sherpa.OfflineRecognizerConfig _buildConfig(SttConfig c) {
    final model = switch (c.kind) {
      SttModelKind.senseVoice => sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: c.model,
          language: c.language,
          useInverseTextNormalization: true,
        ),
        tokens: c.tokens,
        numThreads: c.numThreads,
        debug: false,
      ),
      SttModelKind.whisper => sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: c.encoder,
          decoder: c.decoder,
          language: c.language,
        ),
        tokens: c.tokens,
        numThreads: c.numThreads,
        debug: false,
      ),
      SttModelKind.nemoCtc => sherpa.OfflineModelConfig(
        nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: c.model),
        tokens: c.tokens,
        numThreads: c.numThreads,
        debug: false,
      ),
      SttModelKind.transducer => sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: c.encoder,
          decoder: c.decoder,
          joiner: c.joiner,
        ),
        // NeMo transducers are exported with this name; sherpa uses it to pick
        // the right feature front-end, and gets it wrong when it is absent.
        modelType: 'nemo_transducer',
        tokens: c.tokens,
        numThreads: c.numThreads,
        debug: false,
      ),
    };
    return sherpa.OfflineRecognizerConfig(model: model);
  }
}

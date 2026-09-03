import 'dart:io';

import 'package:voice_models/voice_models.dart';

import 'engine.dart';
import 'sherpa_init.dart';
import 'sherpa_stt.dart';

/// Builds a recogniser from a model in the shared store.
///
/// There is no model directory to configure: [ModelStore] decides where models
/// live, so several apps share one copy. What is left to configure is the
/// native sherpa-onnx library, which is not a model and cannot be downloaded
/// from Hugging Face.
class Recogniser {
  const Recogniser({required this.store, this.nativeLibraryDir});

  final ModelStore store;

  /// Directory holding `sherpa-onnx-c-api.dll` and `onnxruntime.dll`.
  final String? nativeLibraryDir;

  /// Prepares [model], downloading it if this is the first run.
  Future<SttEngine> open(
    VoiceModel model, {
    void Function(DownloadProgress)? onProgress,
    Future<bool> Function(VoiceModel)? onLicence,
  }) async {
    final dir = await store.ensure(
      model,
      onProgress: onProgress,
      onLicence: onLicence,
    );
    initSherpaBindings(nativeLibraryDir);

    final path = '${dir.path}${Platform.pathSeparator}';
    final config = switch (model.id) {
      // A transducer decodes with three networks rather than one.
      'parakeet-tdt-0.6b-v3-int8' => SttConfig.transducer(
          encoder: '${path}encoder.int8.onnx',
          decoder: '${path}decoder.int8.onnx',
          joiner: '${path}joiner.int8.onnx',
          tokens: '${path}tokens.txt',
          nativeLibraryPath: nativeLibraryDir,
        ),
      'sense-voice-small' => SttConfig.senseVoice(
          model: '${path}model.int8.onnx',
          tokens: '${path}tokens.txt',
          nativeLibraryPath: nativeLibraryDir,
        ),
      // A Conformer-CTC, which decodes with a single network and no joiner.
      'indicconformer-ne-int8' => SttConfig.nemoCtc(
          model: '${path}model.int8.onnx',
          tokens: '${path}tokens.txt',
          nativeLibraryPath: nativeLibraryDir,
        ),
      _ => throw ArgumentError(
          '${model.id} is in the catalog but this app does not know how to '
          'load it. Add a case here when adding a recogniser.',
        ),
    };
    return SherpaSttEngine.spawn(config);
  }

  /// The recognisers this app can actually drive, in preference order.
  ///
  /// Parakeet first: it punctuates and capitalises as it decodes, which is
  /// most of what dictated text needs. SenseVoice is a third the size and
  /// writes numbers as digits, which Parakeet does not. IndicConformer is
  /// here because it is the only one of the three that speaks Nepali.
  static List<VoiceModel> get supported => [
        modelById('parakeet-tdt-0.6b-v3-int8')!,
        modelById('sense-voice-small')!,
        modelById('indicconformer-ne-int8')!,
      ];
}

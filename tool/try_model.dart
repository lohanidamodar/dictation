import 'dart:io';
import 'dart:typed_data';

import 'package:dictation/dictation.dart';

/// Transcribes a .wav with one catalogue model, to check a recogniser end to
/// end without a microphone.
///
///   `dart run tool/try_model.dart <model id> <file.wav>`
Future<void> main(List<String> argv) async {
  if (argv.length < 2) {
    stderr.writeln('usage: try_model.dart <model id> <file.wav>');
    exitCode = 1;
    return;
  }

  final model = modelById(argv[0]);
  if (model == null) {
    stderr.writeln('no model called "${argv[0]}"');
    exitCode = 1;
    return;
  }

  final store = ModelStore();
  final stt = await Recogniser(
    store: store,
    nativeLibraryDir: resolveNativeLibraryDir(),
  ).open(model, onLicence: (_) async => true);

  final samples = _readWav(File(argv[1]).readAsBytesSync());
  final started = DateTime.now();
  final text = await stt.transcribe(samples);
  final ms = DateTime.now().difference(started).inMilliseconds;

  stdout.writeln('${model.name}  ${ms}ms\n  $text');
  await stt.dispose();
  store.dispose();
}

/// Reads 16-bit mono PCM, resampling by dropping to [kSampleRate] if needed.
Float32List _readWav(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  var offset = 12;
  var rate = kSampleRate;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    if (id == 'fmt ') rate = view.getUint32(offset + 12, Endian.little);
    if (id == 'data') {
      final count = size ~/ 2;
      final out = Float32List(count);
      for (var i = 0; i < count; i++) {
        out[i] = view.getInt16(offset + 8 + i * 2, Endian.little) / 32768.0;
      }
      return rate == kSampleRate ? out : _resample(out, rate, kSampleRate);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk in the wav');
}

Float32List _resample(Float32List input, int from, int to) {
  final out = Float32List((input.length * to / from).floor());
  for (var i = 0; i < out.length; i++) {
    out[i] = input[(i * from / to).floor()];
  }
  return out;
}

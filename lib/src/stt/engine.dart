import 'dart:typed_data';

/// Sample rate every stage agrees on. The sherpa-onnx models here are trained
/// at 16 kHz, and the microphone is opened at it, so nothing resamples.
const int kSampleRate = 16000;

/// A chunk of mono PCM, normalised to [-1.0, 1.0].
typedef AudioChunk = Float32List;

/// A speech recogniser.
///
/// Implementations receive a complete utterance: deciding where speech starts
/// and stops belongs to whatever holds the microphone, not to the recogniser.
abstract interface class SttEngine {
  Future<String> transcribe(AudioChunk samples);
  Future<void> dispose();
}

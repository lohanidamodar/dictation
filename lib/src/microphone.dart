import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Present in mmsystem.h but not surfaced by the win32 package.
const _waveMapper = 0xFFFFFFFF; // "whatever the default input device is"
const _whdrDone = 0x00000001;

/// Records 16 kHz mono PCM from the default microphone.
///
/// `waveIn` rather than WASAPI: it is older, simpler, present on every
/// Windows, and produces exactly the rate the recognisers want without a
/// resample. Buffers are polled rather than delivered by callback — an FFI
/// callback arrives on a thread the Dart VM does not own, which is the part
/// that goes wrong.
class Microphone {
  Microphone({
    this.sampleRate = 16000,
    this.bufferCount = 4,
    this.bufferBytes = 4096,
  });

  final int sampleRate;

  /// Buffers in flight. More than one so capture never stalls waiting for the
  /// poll loop to hand one back.
  final int bufferCount;

  /// Roughly 128 ms each at 16 kHz. Small enough that stopping feels
  /// immediate, large enough not to spin.
  final int bufferBytes;

  /// Called at each native step, so a hang or a hard crash can be located.
  ///
  /// A native failure leaves no Dart stack — the process simply stops — so the
  /// last line written is the only evidence of where it happened.
  void Function(String step)? onTrace;

  HWAVEIN? _device;
  Pointer<Pointer>? _handle;
  Pointer<WAVEFORMATEX>? _format;
  final _headers = <Pointer<WAVEHDR>>[];
  final _captured = BytesBuilder();

  bool get isRecording => _device != null;

  /// Opens the microphone and starts capturing.
  ///
  /// Throws [MicrophoneException] when no device is available or Windows
  /// refuses access — which is what a denied microphone permission looks like.
  void start() {
    if (isRecording) return;
    onTrace?.call('mic.start');
    _captured.clear();

    final format = calloc<WAVEFORMATEX>()
      ..ref.wFormatTag = WAVE_FORMAT_PCM
      ..ref.nChannels = 1
      ..ref.nSamplesPerSec = sampleRate
      ..ref.wBitsPerSample = 16
      ..ref.nBlockAlign = 2
      ..ref.nAvgBytesPerSec = sampleRate * 2
      ..ref.cbSize = 0;

    final handle = calloc<Pointer>();
    final result = waveInOpen(
      handle,
      _waveMapper,
      format,
      0,
      0,
      MIDI_WAVE_OPEN_TYPE(CALLBACK_NULL),
    );
    if (result != MMSYSERR_NOERROR) {
      calloc
        ..free(format)
        ..free(handle);
      throw MicrophoneException(
        'Could not open the microphone (waveIn error $result). '
        'Check that one is connected and that Windows lets this app use it.',
      );
    }

    _format = format;
    _handle = handle;
    final device = HWAVEIN(handle.value);
    _device = device;

    for (var i = 0; i < bufferCount; i++) {
      final data = calloc<Uint8>(bufferBytes);
      final header = calloc<WAVEHDR>()
        ..ref.lpData = PSTR(data.cast())
        ..ref.dwBufferLength = bufferBytes
        ..ref.dwFlags = 0;
      waveInPrepareHeader(device, header, sizeOf<WAVEHDR>());
      waveInAddBuffer(device, header, sizeOf<WAVEHDR>());
      _headers.add(header);
    }

    waveInStart(device);
    onTrace?.call('mic.started');
  }

  /// Collects whatever has been captured since the last call.
  ///
  /// Call this regularly while recording; a buffer that is not handed back
  /// stops being filled.
  void poll() => _collect(requeue: true);

  /// Copies finished buffers out, optionally handing them back to the driver.
  ///
  /// [requeue] must be false once recording is ending. Re-adding a buffer
  /// gives its memory back to the audio driver, and freeing memory the driver
  /// still owns corrupts the heap — which surfaces as an access violation
  /// later, on some unrelated allocation, long after the mistake.
  void _collect({required bool requeue}) {
    final device = _device;
    if (device == null) return;

    for (final header in _headers) {
      if (header.ref.dwFlags & _whdrDone == 0) continue;

      final bytes = header.ref.dwBytesRecorded;
      if (bytes > 0) {
        // Copied out: the buffer may be handed back and refilled.
        _captured.add(
          Uint8List.fromList(
            (header.ref.lpData as Pointer).cast<Uint8>().asTypedList(bytes),
          ),
        );
      }
      if (!requeue) continue;

      waveInUnprepareHeader(device, header, sizeOf<WAVEHDR>());
      header.ref
        ..dwFlags = 0
        ..dwBytesRecorded = 0;
      waveInPrepareHeader(device, header, sizeOf<WAVEHDR>());
      waveInAddBuffer(device, header, sizeOf<WAVEHDR>());
    }
  }

  /// Stops recording and returns everything captured, as normalised samples.
  Float32List stop() {
    final device = _device;
    if (device == null) return Float32List(0);

    // Order matters, and getting it wrong corrupts the heap. Reset first: it
    // stops capture and returns every queued buffer, marking them done. Only
    // then is the memory ours again to read and release.
    onTrace?.call('mic.stop');
    waveInStop(device);
    waveInReset(device);
    onTrace?.call('mic.reset');
    _collect(requeue: false);
    onTrace?.call('mic.collected');

    for (final header in _headers) {
      // A buffer the driver has not released cannot be freed. If unprepare
      // fails the memory is deliberately leaked: a few kilobytes is a far
      // smaller problem than a use-after-free in an audio driver.
      final released =
          waveInUnprepareHeader(device, header, sizeOf<WAVEHDR>()) ==
              MMSYSERR_NOERROR;
      if (released) {
        calloc
          ..free(header.ref.lpData as Pointer)
          ..free(header);
      }
    }
    _headers.clear();
    onTrace?.call('mic.unprepared');
    waveInClose(device);
    onTrace?.call('mic.closed');

    calloc
      ..free(_format!)
      ..free(_handle!);
    _device = null;
    _format = null;
    _handle = null;

    final pcm = _captured.takeBytes();
    final view = ByteData.sublistView(pcm);
    final samples = Float32List(pcm.lengthInBytes ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }

  /// Loudest sample so far, 0..1 — for showing that something is being heard.
  double get peak {
    final bytes = _captured.toBytes();
    if (bytes.isEmpty) return 0;
    final view = ByteData.sublistView(bytes);
    var peak = 0;
    // The tail only: this is a level meter, not an analysis.
    final from = (bytes.lengthInBytes ~/ 2 - 4000).clamp(0, 1 << 30);
    for (var i = from; i < bytes.lengthInBytes ~/ 2; i++) {
      final v = view.getInt16(i * 2, Endian.little).abs();
      if (v > peak) peak = v;
    }
    return peak / 32768.0;
  }
}

class MicrophoneException implements Exception {
  const MicrophoneException(this.message);
  final String message;

  @override
  String toString() => message;
}

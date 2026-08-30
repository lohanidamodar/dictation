import 'dart:async';
import 'dart:typed_data';

import 'stt/engine.dart';
import 'stt/spoken_punctuation.dart';
import 'stt/vocabulary.dart';

import 'microphone.dart';
import 'text_input.dart';

/// What the dictation loop is doing, for a status line or a tray tooltip.
sealed class DictationEvent {
  const DictationEvent();
}

final class DictationListening extends DictationEvent {
  const DictationListening(this.target);

  /// Title of the window the text will go to.
  final String target;
}

/// Loudness while the key is held, 0..1 — drives the level meter.
final class DictationLevel extends DictationEvent {
  const DictationLevel(this.level);
  final double level;
}

final class DictationRecognising extends DictationEvent {
  const DictationRecognising(this.seconds);
  final double seconds;
}

final class DictationTyped extends DictationEvent {
  const DictationTyped(this.text, this.elapsed);
  final String text;

  /// From releasing the key to the last character landing.
  final Duration elapsed;
}

/// The key was held but nothing was said.
final class DictationNothingHeard extends DictationEvent {
  const DictationNothingHeard();
}

final class DictationFailed extends DictationEvent {
  const DictationFailed(this.message);
  final String message;
}

/// Hold a key, speak, and the words are typed into whatever has focus.
///
/// Recognition only — no language model. The value here is that the words
/// appear while the thought is still in the air, and a cleanup pass costs
/// seconds. Corrections and spoken punctuation are cheap string work and do
/// run.
class Dictation {
  Dictation({
    required SttEngine stt,
    Vocabulary? vocabulary,
    this.punctuation,
    Microphone? microphone,
    TextInput input = const TextInput(),
    this.minimumSeconds = 0.3,
    this.ownsStt = true,
  })  // A named parameter cannot be private, so `this._stt` is not
      // expressible and the lint's suggestion does not apply here.
      // ignore: prefer_initializing_formals
      : _stt = stt,
        // ignore: prefer_initializing_formals
        _input = input,
        _vocabulary = vocabulary ?? Vocabulary.empty(),
        _microphone = microphone ?? Microphone();

  final SttEngine _stt;
  final Vocabulary _vocabulary;

  /// Off unless asked for. In dictation "comma" usually means the mark, but
  /// the moment someone dictates prose about a comma it does not.
  final SpokenPunctuation? punctuation;

  final Microphone _microphone;
  final TextInput _input;

  /// Below this, a press is treated as a slip rather than speech. Stops a
  /// mistimed keystroke from injecting whatever noise was in the room.
  final double minimumSeconds;

  /// Whether disposing this should also dispose the recogniser. False when the
  /// caller keeps it across a settings reload.
  final bool ownsStt;

  /// Ignore the hotkey without tearing anything down — what Pause does.
  bool enabled = true;

  /// Traces each step. A native crash leaves no Dart stack, so the last line
  /// written is the only clue to where it stopped.
  void Function(String step)? onTrace;

  final _events = StreamController<DictationEvent>.broadcast();
  Stream<DictationEvent> get events => _events.stream;

  Timer? _pump;
  bool _busy = false;

  /// The hotkey went down: open the microphone.
  ///
  /// Driven from outside, because the hotkey now belongs to the UI thread —
  /// see `ui_host.dart` for why it cannot live here.
  void onHotkeyPressed() => _beginCapture();

  /// The hotkey came up: recognise what was said and type it.
  Future<void> onHotkeyReleased() => _finishCapture();

  void _beginCapture() {
    if (_busy || !enabled) return;
    _trace('press');
    try {
      _microphone.onTrace = _trace;
      _microphone.start();
    } on MicrophoneException catch (e) {
      _events.add(DictationFailed(e.message));
      return;
    }
    // Buffers that are not handed back stop being filled, so they are drained
    // on a timer for as long as the key is held.
    _pump = Timer.periodic(const Duration(milliseconds: 40), (_) {
      _microphone.poll();
      _events.add(DictationLevel(_microphone.peak));
    });
    _events.add(DictationListening(focusedWindowTitle()));
  }

  Future<void> _finishCapture() async {
    _pump?.cancel();
    _pump = null;
    if (!_microphone.isRecording || _busy) return;

    _busy = true;
    try {
      final samples = _microphone.stop();
      final seconds = samples.length / _microphone.sampleRate;
      if (seconds < minimumSeconds) {
        _events.add(const DictationNothingHeard());
        return;
      }

      _events.add(DictationRecognising(seconds));
      final started = DateTime.now();
      _trace('transcribe.begin ${samples.length} samples');

      var text = (await _stt.transcribe(Float32List.fromList(samples))).trim();
      _trace('transcribe.done ${text.length} chars');
      if (text.isEmpty) {
        _events.add(const DictationNothingHeard());
        return;
      }

      // Corrections first: a name the recogniser mangled should be right
      // before any punctuation pass looks at the words around it.
      text = _vocabulary.apply(text);
      if (punctuation case final p?) text = p.apply(text);

      _trace('type.begin');
      await _input.type(text);
      _trace('type.done');
      _events.add(DictationTyped(text, DateTime.now().difference(started)));
    } catch (e) {
      _events.add(DictationFailed('$e'));
    } finally {
      _busy = false;
      _trace('idle');
    }
  }

  void _trace(String step) => onTrace?.call(step);

  Future<void> dispose() async {
    _pump?.cancel();
    if (_microphone.isRecording) _microphone.stop();
    if (ownsStt) await _stt.dispose();
    await _events.close();
  }
}

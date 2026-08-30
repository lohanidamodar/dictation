# dictation

Hold a hotkey, speak, let go — the words are typed into whatever window has
focus. A text box, a terminal, a chat message, someone else's app. Recognition
runs on your machine; no audio leaves it, and it works with the network off.

Windows only, and no Flutter in the finished program: it records through
`waveIn`, types through `SendInput`, and puts its tray icon and status pill up
through ordinary Win32 windows over FFI. The compiled `dictate.exe` is a plain
Win32 binary — no engine, no widgets, no plugins, no Python.

Building it does need the Flutter SDK, for one reason: sherpa-onnx publishes its
Dart FFI bindings as a Flutter plugin, so `flutter pub get` is what resolves
them. The bindings themselves are plain `dart:ffi` and nothing Flutter ends up
in the executable.

```
Ctrl+Alt+D  →  🎤  →  the words appear where your cursor is
```

## Why raw recognition

There is no language-model cleanup pass. One would punctuate better, and it
would cost a second or two per utterance — the wrong trade for dictation, where
the point is that the words appear while the thought is still in the air. What
you get instead is a recogniser that punctuates as it decodes, plus a
corrections list for the words it gets wrong about you specifically.

## Install

Take the **[latest release][releases]** — either the installer, which installs
for the current user and so never asks for an administrator, or the zip, which
runs from wherever you unpack it. Both carry the sherpa-onnx libraries; there is
nothing else to fetch by hand.

On the first run it shows you the model's licence, asks, and downloads about
640 MB. The tray tooltip counts it down. After that it starts in a few seconds.

Hold **Ctrl+Alt+D**, speak, let go.

### Building it yourself

```
flutter pub get                   # see above: sherpa-onnx ships as a plugin
dart run tool/make_icon.dart      # draws installer/dictation.ico
dart run tool/package.dart        # build/dictation-<version>-windows-x64{,.zip}
iscc installer\dictation.iss /DVersion=<version>
```

`tool/package.dart` downloads the matching sherpa-onnx libraries itself, so the
zip and the installer are built from the same staged folder and cannot drift
apart. `.github/workflows/release.yml` runs exactly this on a `v*` tag.

To run it straight from source you need the two native libraries somewhere it
looks — beside the executable, or in `%LOCALAPPDATA%\PopupBits\runtime`, which
other PopupBits apps share. They come from [sherpa-onnx releases][sherpa], asset
`sherpa-onnx-v<version>-win-x64-shared-MT-Release-no-tts-lib.tar.bz2`. Both must
be together — see [Notes](#notes-from-the-build) for why.

## The models, and their licences

This program is MIT. **The models are not**, and an MIT program says nothing
about the terms of a model it downloads at runtime. Nothing is bundled here —
the weights are fetched from their publishers, and the licence is shown before
anything is downloaded. `dictate.exe --list-models` prints them at any time.

| model | licence | what it asks of you |
|---|---|---|
| [Parakeet TDT 0.6b v3][parakeet] (default) | [CC-BY-4.0][ccby] | **credit NVIDIA** if you build on it |
| [SenseVoice Small][sensevoice] | [FunASR Model Open Source License Agreement v1.1][funasr] | **Alibaba's own terms — not an OSI-approved licence.** Read them before shipping anything |
| [Silero VAD][silero] | [MIT][mit] | nothing beyond the notice |

A caveat worth knowing: the sherpa-onnx *conversions* on Hugging Face, which is
where the ONNX files actually come from, declare no licence of their own. The
upstream model's terms are therefore the ones that apply, and those are what
the table above and the catalog record.

The [sherpa-onnx][sherpa] libraries themselves are Apache-2.0.

If you redistribute a build with weights included, those obligations are yours,
not this project's. `THIRD-PARTY-NOTICES.md`, which ships in every download,
lists everything a release redistributes and under what terms.

### Which recogniser

Parakeet by default. It punctuates and capitalises as it decodes, which is most
of what dictated text needs, and it is noticeably better on unfamiliar proper
nouns. It does not turn spoken numbers into digits.

SenseVoice is a third the size, writes numbers as digits, and handles Chinese,
Japanese, Korean and Cantonese as well as English — but punctuates less well,
and its licence is the publisher's own. Switch with `"model":
"sense-voice-small"` in the settings file.

## Where things are kept

| what | where |
|---|---|
| models | `%LOCALAPPDATA%\PopupBits\models` |
| native libraries | `%LOCALAPPDATA%\PopupBits\runtime`, or beside the exe |
| settings | `%APPDATA%\Dictation\config.json` |
| corrections | `%LOCALAPPDATA%\PopupBits\models\vocabulary.json` |
| the program, if installed | `%LOCALAPPDATA%\Programs\Dictation` |

The models directory is shared on purpose. These are hundreds of megabytes and
identical between apps, so a dictation tool and a speech-to-speech assistant
should fetch a model once and both find it. Set `POPUPBITS_MODELS` to move it —
to a different drive, say.

## Settings

The tray's **Edit settings** opens the file. **Reload settings** applies it
without restarting, except the hotkey, which needs a restart and says so.

```jsonc
{
  "hotkey": { "key": "Ctrl+Alt+D" },   // Ctrl, Alt, Shift, Win + a key
  "model": "parakeet-tdt-0.6b-v3-int8",
  "spokenPunctuation": false,          // "comma" → ","
  "showOverlay": true,
  "minimumSeconds": 0.3                // shorter than this is a slipped finger
}
```

A hotkey it cannot parse falls back to the default rather than refusing to
start, and so does a malformed file: being unable to launch because of a typo
is a worse failure than launching on defaults.

`"spokenPunctuation"` is off by default, and should stay off unless you are
dictating notes. It is wrong the moment someone dictates prose *about*
punctuation — "a difficult period in his life" becomes "a difficult. in his
life".

### Corrections

`vocabulary.json` beside the models fixes the words a recogniser gets wrong
about you specifically — names, jargon, your company:

```json
[
  { "heard": ["app right", "up write"], "replacement": "Appwrite" },
  { "heard": ["cloud code"], "replacement": "Claude Code" }
]
```

`heard` is a list because a recogniser is wrong in several different ways about
the same word. Matching ignores case unless you add `"caseSensitive": true`,
respects word boundaries in Devanagari and other Brahmic scripts rather than
only ASCII, and the longest phrase wins.

## Notes from the build

Four things here are not obvious, cost a day each, and are worth writing down
if you are doing something similar.

**A Dart isolate does not own an OS thread.** The VM reschedules isolates
between threads at event-loop turns. `RegisterHotKey(null, …)` and the window
messages that follow are thread-affine: the thread that registers is the only
one that receives. So the app would work for a few presses and then vanish with
no error, no exception, and nothing in the log. The fix is a dedicated isolate
running a blocking `GetMessage` loop that never yields to the Dart scheduler,
with commands posted in as two integers via `PostMessage` — see
`lib/src/ui_host.dart`. Tracing thread ids is what found it; three plausible
theories before that were all wrong.

**`SendInput` lies about batches.** Sending a string as one array of `INPUT`
records returns "all 40 events delivered" and then types only the first word.
One character per call, with a 2 ms gap, arrives intact. This was found by
reading the typed text back through the clipboard rather than trusting the
return value.

**`SetTimer` with a null window ignores the id you give it** and returns its
own. Comparing `WM_TIMER`'s `wParam` against the id you passed therefore never
matches, and the timer's work never runs. Keep what `SetTimer` returned.

**ONNX Runtime must sit beside the sherpa library.** Windows resolves
`onnxruntime.dll` by search order, and a copy in `System32` — an old one, put
there by something else entirely — wins over the one you shipped. The result is
an access violation deep inside native code. Opening your own copy explicitly
before initialising the bindings pins it; `lib/src/stt/sherpa_init.dart` does
that, and it is why both DLLs have to be in the same directory.

## Testing it

```
dart test              # 63 tests, no hardware needed
dart run tool/soak.dart --rounds 8
```

The soak presses the real hotkey against the real app, over and over with
varying idle gaps, and reads the app's own trace to decide whether each round
completed. The bugs that mattered here were not ones a unit test could reach —
the app died after a few cycles, or after sitting idle — so this is the test
that actually guards them.

## Licence

MIT — see [LICENSE](LICENSE). The models are not MIT; see the table above.

[releases]: https://github.com/lohanidamodar/dictation/releases/latest
[sherpa]: https://github.com/k2-fsa/sherpa-onnx/releases
[parakeet]: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
[sensevoice]: https://huggingface.co/FunAudioLLM/SenseVoiceSmall
[silero]: https://github.com/snakers4/silero-vad
[ccby]: https://creativecommons.org/licenses/by/4.0/
[funasr]: https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE
[mit]: https://opensource.org/license/mit

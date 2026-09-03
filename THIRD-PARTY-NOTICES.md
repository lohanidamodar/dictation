# Third-party notices

This program is MIT (see `LICENSE`). A release build redistributes the
libraries below, whose licences require their notices to travel with them.

## Shipped in the download

| component | licence | copyright |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (`sherpa-onnx-c-api.dll`) | [Apache-2.0](https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE) | Xiaomi Corporation and the k2-fsa authors |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) (`onnxruntime.dll`) | [MIT](https://github.com/microsoft/onnxruntime/blob/main/LICENSE) | Microsoft Corporation |

The full text of each is in `licenses/` in the download, because Apache-2.0
asks that recipients be given a copy of the licence and not merely its name.

## Compiled into `dictate.exe`

Dart resolves **69 packages** for this program. All are permissive — 56
BSD-3-Clause, 10 Apache-2.0, 3 MIT — with no copyleft and nothing
non-commercial. The ones with their own names on them:

| package | licence | copyright |
|---|---|---|
| [Dart SDK runtime](https://github.com/dart-lang/sdk) | [BSD-3-Clause](https://github.com/dart-lang/sdk/blob/main/LICENSE) | the Dart project authors |
| [`args`](https://pub.dev/packages/args) | BSD-3-Clause | the Dart project authors |
| [`ffi`](https://pub.dev/packages/ffi) | BSD-3-Clause | the Dart project authors |
| [`http`](https://pub.dev/packages/http) | BSD-3-Clause | the Dart project authors |
| [`win32`](https://pub.dev/packages/win32) | BSD-3-Clause | Halil Durmus |
| [`sherpa_onnx`](https://pub.dev/packages/sherpa_onnx) | Apache-2.0 | Xiaomi Corporation |
| [`voice_models`](https://github.com/lohanidamodar/voice-models) | MIT | Damodar Lohani |

## Not shipped: the speech models

**No model weights are included in any download here.** The app fetches them
from their publishers on first run, and shows the licence before it does.

Their terms are the publishers', not this project's, and they are not all open
source. If you redistribute a build with weights included, these obligations
become yours:

| model | licence | what it asks |
|---|---|---|
| [Parakeet TDT 0.6b v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) | credit NVIDIA |
| [SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | [FunASR Model Open Source License Agreement v1.1](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE) | Alibaba's own terms — **not an OSI-approved licence** |
| [Silero VAD](https://github.com/snakers4/silero-vad) | [MIT](https://opensource.org/license/mit) | the notice |

The ONNX conversions these are downloaded from declare no licence of their own,
so the upstream model's terms above are the ones that apply.

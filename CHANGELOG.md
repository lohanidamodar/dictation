# Changelog

## 0.1.0

First release.

- Hold a hotkey, speak, let go: the words are typed into whatever window has
  focus. Recognition runs on the machine; nothing is sent anywhere.
- Tray icon that turns red while listening, and a small status pill with a
  level meter that follows the cursor's screen.
- Models come from a shared store (`voice_models`), so a second PopupBits app
  finds the same copy instead of downloading its own. Each model's licence is
  shown before anything is downloaded.
- Parakeet TDT 0.6b v3 and SenseVoice Small; a per-user corrections list, and
  optional spoken punctuation.
- Settings in a JSON file the tray can open.

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
- Windows installer and a portable zip, both built from one staged folder by
  `tool/package.dart` so they cannot contain different builds. Installs
  per-user, so no administrator is needed.
- Started from a shortcut there is no console, so the licence question, the
  download progress and any startup failure appear on screen rather than being
  written to a stream nobody can see.

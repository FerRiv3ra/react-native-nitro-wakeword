# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- iOS: connecting or disconnecting Bluetooth audio could crash the app or
  silently stop detection. The audio engine restarted on every route change,
  including the `categoryChange` its own restart produced, which looped
  forever and could hand AVAudioEngine a stale hardware format. The session
  category is now set once, route changes are debounced with a cooldown,
  the input tap uses the node's live format and the converter follows the
  incoming buffer format. Verified on an iPhone XR (iOS 18) with Bluetooth
  earbuds connected and disconnected while listening.

## [0.2.0] - 2026-09-10

### Changed

- Tooling: ESLint + Prettier (shared React Native config), Jest unit tests for
  the JS engine facade and `useWakeWord`, husky pre-commit with lint-staged,
  and CI/release workflows that run lint and tests.

## [0.1.0] - 2026-09-10

### Added

- On-device wake word detection for iOS and Android built on Nitro Modules,
  running the openWakeWord pipeline (mel spectrogram, speech embedding,
  keyword classifier) with ONNX Runtime.
- Several keywords at once over one shared audio front-end. Classifier window
  size is read from the model, so both 16-frame and other window sizes work.
- Optional Silero VAD gate, `patience` and `refractoryMs` to control false
  positives.
- `WakeWordEngine` facade with multi-listener detection, score and error
  events, and a `useWakeWord` React hook.
- Android microphone foreground service for background detection; iOS
  background audio support through `AVAudioSession`.
- Expo config plugin: microphone permission, optional background modes and
  permissions, and `modelsDir` to copy custom `.onnx` classifiers into both
  native projects on prebuild.
- Bundled openWakeWord base models plus the `hey_jarvis` classifier, a
  download script and a Python reference pipeline to validate models offline.
- Training guide for custom wake words in any language.

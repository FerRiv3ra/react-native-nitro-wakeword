# react-native-nitro-wakeword

Open-source, on-device **wake word detection** for React Native. No license keys, no
cloud, no vendor lock-in.

- Runs the [openWakeWord](https://github.com/dscripka/openWakeWord) pipeline
  (mel spectrogram → speech embedding → keyword classifier) with **ONNX Runtime**.
- Native audio capture on both platforms, JS only receives events.
- Powered by [Nitro Modules](https://nitro.margelo.com) (Swift + Kotlin, no bridge).
- Several keywords at once over one shared audio front-end.
- Optional Silero VAD gate to cut false positives.
- Train your own keyword in any language with a free Colab notebook (see
  [docs/TRAINING.md](docs/TRAINING.md)). Classifiers are tiny `.onnx` files.
- MIT licensed. Bundled models are Apache 2.0 / MIT (see [NOTICE](NOTICE)).

## Install

```sh
yarn add react-native-nitro-wakeword react-native-nitro-modules
```

Then `pod install` (bare) or `npx expo prebuild` (Expo).

Works with **Expo** (config plugin, prebuild) and with the **bare React Native
CLI** (autolinking). The native code is the same; only the setup differs.

### Expo

```json
{
  "plugins": [
    [
      "react-native-nitro-wakeword",
      {
        "microphonePermission": "Allow $(PRODUCT_NAME) to listen for the wake word.",
        "iosBackgroundAudio": false,
        "androidForegroundService": false,
        "modelsDir": "assets/wakeword"
      }
    ]
  ]
}
```

| Option | Default | Effect |
|---|---|---|
| `microphonePermission` | generic text | `NSMicrophoneUsageDescription` |
| `iosBackgroundAudio` | `false` | adds the `audio` `UIBackgroundModes` entry |
| `androidForegroundService` | `false` | adds `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `POST_NOTIFICATIONS` |
| `modelsDir` | `assets/wakeword` | every `*.onnx` in this folder is copied into both native projects on `expo prebuild` |

Drop your own classifiers in `assets/wakeword/` (or the folder you configured),
run `npx expo prebuild`, and reference them by file name. Nothing else to do.

### Bare React Native CLI

Autolinking picks up the module (`pod install` on iOS, nothing on Android).
Then:

- **iOS**: add `NSMicrophoneUsageDescription` to `Info.plist`. For background
  detection add `audio` to `UIBackgroundModes`. Add your own `.onnx` files to
  the app target (Xcode: *Build Phases → Copy Bundle Resources*).
- **Android**: `RECORD_AUDIO`, `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_MICROPHONE` are merged from the library manifest. For the
  foreground-service notification on Android 13+ add
  `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`.
  Put your own `.onnx` files in `android/app/src/main/assets/`.

Requires the New Architecture (React Native ≥ 0.76), like every Nitro module.

## Usage

```ts
import {
  BUILTIN_MODELS,
  WakeWordEngine,
  useWakeWord,
} from 'react-native-nitro-wakeword';

// Imperative API
await WakeWordEngine.load({
  models: [
    { model: BUILTIN_MODELS.heyJarvis, keyword: 'hey_jarvis', threshold: 0.6, patience: 2 },
    { model: 'hey_nova.onnx', keyword: 'hey_nova', threshold: 0.7 }, // your own model
  ],
  vadThreshold: 0.3,
  refractoryMs: 1500,
});
const unsubscribe = WakeWordEngine.addDetectionListener(({ keyword, score }) => {
  console.log('detected', keyword, score);
});
if (!WakeWordEngine.hasMicrophonePermission()) {
  await WakeWordEngine.requestMicrophonePermission();
}
await WakeWordEngine.start();
// ...
WakeWordEngine.stop();
unsubscribe();
```

```tsx
// Hook
const config = useMemo(
  () => ({ models: [{ model: BUILTIN_MODELS.heyJarvis, threshold: 0.6 }] }),
  [],
);
const { isListening, lastDetection, error } = useWakeWord({
  config,
  pauseAfterDetectionMs: 5000,
  onDetected: ({ keyword }) => openAssistant(keyword),
});
```

### Where do models come from?

`model` accepts:

| Value | Resolved from |
|---|---|
| `hey_jarvis_v0.1.onnx` | app bundle / Android assets first, then the models shipped in this package |
| `hey_nova.onnx` | Expo: put it in `modelsDir` and prebuild. Bare: Xcode *Copy Bundle Resources* + `android/app/src/main/assets/` |
| `/absolute/path.onnx` or `file://…` | anything downloaded at runtime, `expo-asset` `localUri`, etc. |

The classifier must be an openWakeWord-format model: input `[1, N, 96]` float32,
output `[1, 1]` probability. `N` (usually 16) is detected automatically.

### Tuning

- `threshold`: start at `0.5`, raise until false positives disappear. Use
  `WakeWordEngine.addScoreListener` to watch raw scores while you say the word.
- `patience`: `2`–`3` removes most one-frame spikes at the cost of ~80–160 ms latency.
- `vadThreshold`: `0.3` is a good default. `0` disables the VAD.
- `refractoryMs`: minimum gap between two detections of the same keyword.

### Background listening

- iOS: enable the `audio` background mode. The library keeps `AVAudioSession`
  active in `.playAndRecord` with `mixWithOthers`. Set `manageAudioSession: false`
  if your app owns the session.
- Android: `foregroundService: true` starts a `microphone` foreground service
  with a low-priority notification (`notificationTitle` / `notificationText`).

## API

See [src/WakeWord.nitro.ts](src/WakeWord.nitro.ts) for the full typed contract.

| Method | |
|---|---|
| `load(config)` | loads base models + classifiers, warms up the pipeline |
| `start()` / `stop()` | open / close the microphone |
| `unload()` | releases every ONNX session |
| `setThreshold(keyword, value)` | live threshold change |
| `addDetectionListener(cb)` | returns unsubscribe |
| `addScoreListener(cb)` | raw per-frame scores (tuning only) |
| `addErrorListener(cb)` | runtime errors |
| `hasMicrophonePermission()` / `requestMicrophonePermission()` | |

## How it works

Every 80 ms (1280 samples at 16 kHz):

1. `melspectrogram.onnx` over the last 1760 samples → 8 new 32-bin mel frames.
2. The last 76 mel frames → `embedding_model.onnx` → one 96-dim embedding.
3. The last `N` embeddings → each classifier → score in `[0, 1]`.
4. Silero VAD (512-sample frames) gates scores to `0` when no speech was heard in
   the last second.
5. `threshold` + `patience` + `refractoryMs` decide whether to emit a detection.

CPU cost is roughly 3 small inferences per 80 ms, well under 5 % of one core on
mid-range phones.

## Train your own keyword

See [docs/TRAINING.md](docs/TRAINING.md). Summary: openWakeWord's Colab notebook
generates synthetic samples with Piper TTS (many languages, including Spanish),
augments them with noise / reverb and trains a classifier in ~1 hour on a free GPU.
The result is a `.onnx` you drop into your app.

## Example app

`example/` is a minimal Expo app (`npx expo prebuild`, then `npx expo run:ios` /
`npx expo run:android`). It runs the bundled "hey jarvis" model plus an "alexa"
model copied from `example/assets/wakeword/` by the config plugin, so it doubles
as a test of the model-copy flow. Useful to sanity-check a device before
shipping your own model.

## Requirements

- React Native ≥ 0.76 (new architecture), `react-native-nitro-modules` ≥ 0.35
- iOS 15.1+, Android API 24+

## License

MIT © FerRivera. Third-party notices in [NOTICE](NOTICE).

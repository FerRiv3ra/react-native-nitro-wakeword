import type { HybridObject } from 'react-native-nitro-modules';

/**
 * One keyword classifier to run on top of the shared openWakeWord
 * feature pipeline. Several models can run at the same time; the audio
 * front-end (mel spectrogram + embedding) is computed once and shared.
 */
export interface WakeWordModel {
  /**
   * Classifier model. Either:
   * - an absolute file path (e.g. downloaded at runtime, `expo-asset` localUri), or
   * - a file name that is resolved in the app bundle / Android assets first and
   *   in the models bundled with this library second (e.g. `hey_jarvis_v0.1.onnx`).
   *
   * The classifier must accept a `[1, N, 96]` float tensor (openWakeWord format).
   * `N` is read from the model on Android and probed on iOS, so both the
   * standard 16-frame and other window sizes (e.g. 28) work out of the box.
   */
  model: string;
  /** Label emitted on detection. Defaults to the model file name without extension. */
  keyword?: string;
  /** Score in `[0, 1]` required to trigger. Default `0.5`. */
  threshold?: number;
  /**
   * Number of consecutive 80 ms frames that must score above `threshold`
   * before a detection is emitted. Higher = fewer false positives, slightly
   * more latency. Default `1`.
   */
  patience?: number;
}

export interface WakeWordConfig {
  /** Classifiers to run. At least one. */
  models: WakeWordModel[];
  /**
   * Silero VAD gate. Scores are forced to 0 unless speech was detected in the
   * last ~1 s with probability >= `vadThreshold`. `0` disables the VAD
   * (saves ~10% CPU). Default `0.3`.
   */
  vadThreshold?: number;
  /** Minimum time between two detections of the same keyword, in ms. Default `1000`. */
  refractoryMs?: number;
  /**
   * Android only. Run a foreground service (type `microphone`) while listening
   * so detection keeps working when the app is backgrounded. Requires the
   * permissions added by the Expo config plugin (or by hand). Default `false`.
   */
  foregroundService?: boolean;
  /** Android only. Foreground-service notification title. */
  notificationTitle?: string;
  /** Android only. Foreground-service notification text. */
  notificationText?: string;
  /**
   * iOS only. Configure `AVAudioSession` (`.playAndRecord`, mixes with others,
   * bluetooth allowed) before starting the engine. Set to `false` if your app
   * manages the audio session itself. Default `true`.
   */
  manageAudioSession?: boolean;
}

export interface WakeWordDetection {
  /** Label of the model that fired (`WakeWordModel.keyword`). */
  keyword: string;
  /** Classifier score in `[0, 1]` at the moment of detection. */
  score: number;
  /** Unix epoch time in ms. */
  timestamp: number;
}

export interface WakeWord
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /** `true` after `load()` succeeded and until `unload()`. */
  readonly isLoaded: boolean;
  /** `true` while the microphone is open and audio is being processed. */
  readonly isListening: boolean;

  /**
   * Loads the shared feature models and every classifier. Safe to call again
   * with a different config: the previous engine is stopped and released.
   */
  load(config: WakeWordConfig): Promise<void>;
  /** Stops listening (if needed) and releases every ONNX session. */
  unload(): void;

  /** Opens the microphone and starts detection. Requires `load()` and mic permission. */
  start(): Promise<void>;
  /** Closes the microphone. Models stay loaded, `start()` is cheap afterwards. */
  stop(): void;

  /** Changes the threshold of one keyword at runtime. */
  setThreshold(keyword: string, threshold: number): void;

  /** Registers the (single) native detection callback. Use the JS API for multiple listeners. */
  setDetectionListener(listener: (detection: WakeWordDetection) => void): void;
  clearDetectionListener(): void;

  /**
   * Debug/tuning hook. Called every 80 ms with the raw score of each keyword
   * (after VAD gating). Expensive to keep enabled in production.
   */
  setScoreListener(listener: (keyword: string, score: number) => void): void;
  clearScoreListener(): void;

  /** Runtime errors (audio route lost, inference failure...). Listening may have stopped. */
  setErrorListener(listener: (message: string) => void): void;
  clearErrorListener(): void;

  hasMicrophonePermission(): boolean;
  requestMicrophonePermission(): Promise<boolean>;
}

import { NitroModules } from 'react-native-nitro-modules';
import type {
  WakeWord,
  WakeWordConfig,
  WakeWordDetection,
  WakeWordModel,
} from './WakeWord.nitro';


/** Names of the classifiers shipped with this library (resolved without any path). */
export const BUILTIN_MODELS = {
  /** openWakeWord "hey jarvis" (Apache 2.0). Good for smoke-testing the pipeline. */
  heyJarvis: 'hey_jarvis_v0.1.onnx',
} as const;

type DetectionListener = (detection: WakeWordDetection) => void;
type ScoreListener = (keyword: string, score: number) => void;
type ErrorListener = (message: string) => void;

let nativeInstance: WakeWord | null = null;

/**
 * Lazily creates the native HybridObject. One engine per app is enough: it can
 * run several keywords at once over one shared audio front-end.
 */
export function getNativeWakeWord(): WakeWord {
  if (nativeInstance == null) {
    nativeInstance = NitroModules.createHybridObject<WakeWord>('WakeWord');
  }
  return nativeInstance;
}

const detectionListeners = new Set<DetectionListener>();
const scoreListeners = new Set<ScoreListener>();
const errorListeners = new Set<ErrorListener>();

function syncNativeListeners(): void {
  const native = getNativeWakeWord();
  if (detectionListeners.size > 0) {
    native.setDetectionListener((detection) => {
      detectionListeners.forEach((listener) => listener(detection));
    });
  } else {
    native.clearDetectionListener();
  }
  if (scoreListeners.size > 0) {
    native.setScoreListener((keyword, score) => {
      scoreListeners.forEach((listener) => listener(keyword, score));
    });
  } else {
    native.clearScoreListener();
  }
  if (errorListeners.size > 0) {
    native.setErrorListener((message) => {
      errorListeners.forEach((listener) => listener(message));
    });
  } else {
    native.clearErrorListener();
  }
}

function subscribe<T>(set: Set<T>, listener: T): () => void {
  set.add(listener);
  syncNativeListeners();
  return () => {
    set.delete(listener);
    syncNativeListeners();
  };
}

/**
 * High-level, multi-listener facade over the native engine.
 *
 * ```ts
 * await WakeWordEngine.load({ models: [{ model: BUILTIN_MODELS.heyJarvis, threshold: 0.6 }] })
 * const off = WakeWordEngine.addDetectionListener(({ keyword }) => console.log(keyword))
 * await WakeWordEngine.start()
 * ```
 */
export const WakeWordEngine = {
  get isLoaded(): boolean {
    return getNativeWakeWord().isLoaded;
  },
  get isListening(): boolean {
    return getNativeWakeWord().isListening;
  },
  load(config: WakeWordConfig): Promise<void> {
    return getNativeWakeWord().load(config);
  },
  unload(): void {
    getNativeWakeWord().unload();
  },
  start(): Promise<void> {
    return getNativeWakeWord().start();
  },
  stop(): void {
    getNativeWakeWord().stop();
  },
  setThreshold(keyword: string, threshold: number): void {
    getNativeWakeWord().setThreshold(keyword, threshold);
  },
  hasMicrophonePermission(): boolean {
    return getNativeWakeWord().hasMicrophonePermission();
  },
  requestMicrophonePermission(): Promise<boolean> {
    return getNativeWakeWord().requestMicrophonePermission();
  },
  /** Returns an unsubscribe function. */
  addDetectionListener(listener: DetectionListener): () => void {
    return subscribe(detectionListeners, listener);
  },
  /** Raw per-frame scores, for threshold tuning. Returns an unsubscribe function. */
  addScoreListener(listener: ScoreListener): () => void {
    return subscribe(scoreListeners, listener);
  },
  /** Returns an unsubscribe function. */
  addErrorListener(listener: ErrorListener): () => void {
    return subscribe(errorListeners, listener);
  },
};

/** Helper to build a model entry with sane defaults. */
export function defineModel(
  model: string,
  options: Omit<WakeWordModel, 'model'> = {},
): WakeWordModel {
  return { model, threshold: 0.5, patience: 1, ...options };
}

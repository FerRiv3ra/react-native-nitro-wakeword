import {NitroModules} from 'react-native-nitro-modules';
import type {WakeWord, WakeWordDetection} from '../../WakeWord.nitro';

type DetectionListener = (detection: WakeWordDetection) => void;
type ScoreListener = (keyword: string, score: number) => void;
type ErrorListener = (message: string) => void;

export type FakeNative = Omit<
  jest.Mocked<WakeWord>,
  'isLoaded' | 'isListening'
> & {
  isLoaded: boolean;
  isListening: boolean;
  emitDetection: (detection: WakeWordDetection) => void;
  emitScore: (keyword: string, score: number) => void;
  emitError: (message: string) => void;
  hasDetectionListener: () => boolean;
  hasScoreListener: () => boolean;
  hasErrorListener: () => boolean;
  /** Clears mock history, listeners and state between tests. */
  reset: () => void;
};

/**
 * In-memory stand-in for the native HybridObject. The engine caches the first
 * HybridObject it creates, so install one fake per test file with
 * `installFakeNative()` and call `native.reset()` in `beforeEach`.
 */
export function makeFakeNative(): FakeNative {
  let detection: DetectionListener | undefined;
  let score: ScoreListener | undefined;
  let error: ErrorListener | undefined;

  const native = {
    name: 'WakeWord',
    isLoaded: false,
    isListening: false,
    load: jest.fn(),
    unload: jest.fn(),
    start: jest.fn(),
    stop: jest.fn(),
    setThreshold: jest.fn(),
    setDetectionListener: jest.fn(),
    clearDetectionListener: jest.fn(),
    setScoreListener: jest.fn(),
    clearScoreListener: jest.fn(),
    setErrorListener: jest.fn(),
    clearErrorListener: jest.fn(),
    hasMicrophonePermission: jest.fn(),
    requestMicrophonePermission: jest.fn(),
    equals: jest.fn(() => false),
    dispose: jest.fn(),
    toString: () => '[FakeWakeWord]',
    emitDetection: (d: WakeWordDetection) => detection?.(d),
    emitScore: (k: string, s: number) => score?.(k, s),
    emitError: (m: string) => error?.(m),
    hasDetectionListener: () => detection !== undefined,
    hasScoreListener: () => score !== undefined,
    hasErrorListener: () => error !== undefined,
    reset: () => {
      detection = undefined;
      score = undefined;
      error = undefined;
      native.isLoaded = false;
      native.isListening = false;
      for (const fn of Object.values(native)) {
        if (jest.isMockFunction(fn)) {
          fn.mockReset();
        }
      }
      native.load.mockImplementation(async () => {
        native.isLoaded = true;
      });
      native.unload.mockImplementation(() => {
        native.isLoaded = false;
      });
      native.start.mockImplementation(async () => {
        native.isListening = true;
      });
      native.stop.mockImplementation(() => {
        native.isListening = false;
      });
      native.setDetectionListener.mockImplementation(
        (listener: DetectionListener) => {
          detection = listener;
        },
      );
      native.clearDetectionListener.mockImplementation(() => {
        detection = undefined;
      });
      native.setScoreListener.mockImplementation((listener: ScoreListener) => {
        score = listener;
      });
      native.clearScoreListener.mockImplementation(() => {
        score = undefined;
      });
      native.setErrorListener.mockImplementation((listener: ErrorListener) => {
        error = listener;
      });
      native.clearErrorListener.mockImplementation(() => {
        error = undefined;
      });
      native.hasMicrophonePermission.mockReturnValue(true);
      native.requestMicrophonePermission.mockResolvedValue(true);
    },
  };
  native.reset();
  return native as unknown as FakeNative;
}

/** Makes `NitroModules.createHybridObject('WakeWord')` return `native`. */
export function installFakeNative(native: FakeNative = makeFakeNative()) {
  (NitroModules.createHybridObject as jest.Mock).mockReturnValue(native);
  return native;
}

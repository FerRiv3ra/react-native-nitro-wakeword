import {useCallback, useEffect, useRef, useState} from 'react';
import {WakeWordEngine} from './engine';
import type {WakeWordConfig, WakeWordDetection} from './WakeWord.nitro';

export interface UseWakeWordOptions {
  /** Engine config. Re-loads the engine when its identity changes (memoize it!). */
  config: WakeWordConfig;
  /** Called on every detection. */
  onDetected?: (detection: WakeWordDetection) => void;
  /** Called on native runtime errors. */
  onError?: (message: string) => void;
  /** Ask for mic permission and start listening as soon as the engine is loaded. Default `true`. */
  autoStart?: boolean;
  /**
   * Pause detection for this many ms after a detection, then resume.
   * `0` keeps listening continuously. Default `0`.
   */
  pauseAfterDetectionMs?: number;
}

export interface UseWakeWordResult {
  isLoaded: boolean;
  isListening: boolean;
  isPermissionGranted: boolean;
  /** Last detection, or `null` when idle / after the pause ends. */
  lastDetection: WakeWordDetection | null;
  /** Load error, if any. */
  error: string | null;
  start: () => Promise<void>;
  stop: () => void;
}

/**
 * React hook wrapping {@link WakeWordEngine}: loads the models, manages
 * permission, listens for detections and unsubscribes on unmount.
 */
export function useWakeWord({
  config,
  onDetected,
  onError,
  autoStart = true,
  pauseAfterDetectionMs = 0,
}: UseWakeWordOptions): UseWakeWordResult {
  const [isLoaded, setIsLoaded] = useState(false);
  const [isListening, setIsListening] = useState(false);
  const [isPermissionGranted, setIsPermissionGranted] = useState(false);
  const [lastDetection, setLastDetection] = useState<WakeWordDetection | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);

  const onDetectedRef = useRef(onDetected);
  const onErrorRef = useRef(onError);
  const pauseTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mounted = useRef(true);
  onDetectedRef.current = onDetected;
  onErrorRef.current = onError;

  const start = useCallback(async () => {
    const granted =
      WakeWordEngine.hasMicrophonePermission() ||
      (await WakeWordEngine.requestMicrophonePermission());
    if (!mounted.current) return;
    setIsPermissionGranted(granted);
    if (!granted) {
      setError('Microphone permission denied');
      return;
    }
    await WakeWordEngine.start();
    if (mounted.current) setIsListening(true);
  }, []);

  const stop = useCallback(() => {
    if (pauseTimer.current) {
      clearTimeout(pauseTimer.current);
      pauseTimer.current = null;
    }
    WakeWordEngine.stop();
    setIsListening(false);
  }, []);

  useEffect(() => {
    mounted.current = true;
    let cancelled = false;

    const offDetection = WakeWordEngine.addDetectionListener(detection => {
      setLastDetection(detection);
      onDetectedRef.current?.(detection);
      if (pauseAfterDetectionMs > 0) {
        WakeWordEngine.stop();
        setIsListening(false);
        pauseTimer.current = setTimeout(() => {
          pauseTimer.current = null;
          if (!mounted.current) return;
          setLastDetection(null);
          WakeWordEngine.start()
            .then(() => mounted.current && setIsListening(true))
            .catch((e: unknown) => setError(String(e)));
        }, pauseAfterDetectionMs);
      }
    });
    const offError = WakeWordEngine.addErrorListener(message => {
      setError(message);
      setIsListening(WakeWordEngine.isListening);
      onErrorRef.current?.(message);
    });

    (async () => {
      try {
        await WakeWordEngine.load(config);
        if (cancelled) return;
        setIsLoaded(true);
        setError(null);
        if (autoStart) await start();
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();

    return () => {
      cancelled = true;
      mounted.current = false;
      if (pauseTimer.current) clearTimeout(pauseTimer.current);
      offDetection();
      offError();
      WakeWordEngine.stop();
      setIsListening(false);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [config, autoStart, pauseAfterDetectionMs]);

  return {
    isLoaded,
    isListening,
    isPermissionGranted,
    lastDetection,
    error,
    start,
    stop,
  };
}

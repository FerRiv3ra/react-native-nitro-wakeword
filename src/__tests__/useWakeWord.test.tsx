import {act, renderHook, waitFor} from '@testing-library/react-native';
import {useWakeWord} from '../useWakeWord';
import {installFakeNative} from './utils/fakeNative';

const native = installFakeNative();
const config = {
  models: [{model: 'hey_jarvis_v0.1.onnx', keyword: 'hey_jarvis'}],
};
const detection = {keyword: 'hey_jarvis', score: 0.95, timestamp: 123};

beforeEach(() => {
  native.reset();
});

afterEach(() => {
  jest.useRealTimers();
});

describe('useWakeWord', () => {
  it('loads, requests permission and starts listening by default', async () => {
    native.hasMicrophonePermission.mockReturnValue(false);

    const {result} = await renderHook(() => useWakeWord({config}));
    await waitFor(() => expect(result.current.isListening).toBe(true));

    expect(native.load).toHaveBeenCalledWith(config);
    expect(native.requestMicrophonePermission).toHaveBeenCalledTimes(1);
    expect(native.start).toHaveBeenCalledTimes(1);
    expect(result.current.isLoaded).toBe(true);
    expect(result.current.isPermissionGranted).toBe(true);
    expect(result.current.error).toBeNull();
  });

  it('does not start when autoStart is false, and start() works manually', async () => {
    const {result} = await renderHook(() =>
      useWakeWord({config, autoStart: false}),
    );
    await waitFor(() => expect(result.current.isLoaded).toBe(true));
    expect(native.start).not.toHaveBeenCalled();

    await act(async () => {
      await result.current.start();
    });
    expect(native.start).toHaveBeenCalledTimes(1);
    expect(result.current.isListening).toBe(true);

    await act(async () => {
      result.current.stop();
    });
    expect(native.stop).toHaveBeenCalled();
    expect(result.current.isListening).toBe(false);
  });

  it('reports a denied microphone permission as an error and does not start', async () => {
    native.hasMicrophonePermission.mockReturnValue(false);
    native.requestMicrophonePermission.mockResolvedValue(false);

    const {result} = await renderHook(() => useWakeWord({config}));
    await waitFor(() =>
      expect(result.current.error).toBe('Microphone permission denied'),
    );
    expect(native.start).not.toHaveBeenCalled();
    expect(result.current.isPermissionGranted).toBe(false);
  });

  it('surfaces load failures', async () => {
    native.load.mockRejectedValue(new Error('Model not found: nope.onnx'));

    const {result} = await renderHook(() => useWakeWord({config}));
    await waitFor(() =>
      expect(result.current.error).toBe('Model not found: nope.onnx'),
    );
    expect(result.current.isLoaded).toBe(false);
    expect(native.start).not.toHaveBeenCalled();
  });

  it('delivers detections to state and callback', async () => {
    const onDetected = jest.fn();
    const {result} = await renderHook(() => useWakeWord({config, onDetected}));
    await waitFor(() => expect(result.current.isListening).toBe(true));

    await act(async () => {
      native.emitDetection(detection);
    });
    expect(onDetected).toHaveBeenCalledWith(detection);
    expect(result.current.lastDetection).toEqual(detection);
    expect(native.stop).not.toHaveBeenCalled();
  });

  it('pauses after a detection and resumes when the pause ends', async () => {
    jest.useFakeTimers();
    const {result} = await renderHook(() =>
      useWakeWord({config, pauseAfterDetectionMs: 5000}),
    );
    await waitFor(() => expect(result.current.isListening).toBe(true));

    await act(async () => {
      native.emitDetection(detection);
    });
    expect(native.stop).toHaveBeenCalledTimes(1);
    expect(result.current.isListening).toBe(false);
    expect(result.current.lastDetection).toEqual(detection);

    await act(async () => {
      jest.advanceTimersByTime(5000);
    });
    await waitFor(() => expect(result.current.isListening).toBe(true));
    expect(native.start).toHaveBeenCalledTimes(2);
    expect(result.current.lastDetection).toBeNull();
  });

  it('forwards native errors', async () => {
    const onError = jest.fn();
    const {result} = await renderHook(() => useWakeWord({config, onError}));
    await waitFor(() => expect(result.current.isListening).toBe(true));

    await act(async () => {
      native.isListening = false;
      native.emitError('Audio engine restart failed');
    });
    expect(onError).toHaveBeenCalledWith('Audio engine restart failed');
    expect(result.current.error).toBe('Audio engine restart failed');
    expect(result.current.isListening).toBe(false);
  });

  it('stops and removes listeners on unmount', async () => {
    const {result, unmount} = await renderHook(() => useWakeWord({config}));
    await waitFor(() => expect(result.current.isListening).toBe(true));
    expect(native.hasDetectionListener()).toBe(true);

    await unmount();
    expect(native.stop).toHaveBeenCalled();
    expect(native.hasDetectionListener()).toBe(false);
    expect(native.hasErrorListener()).toBe(false);
  });
});

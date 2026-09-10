import {NitroModules} from 'react-native-nitro-modules';
import {
  BUILTIN_MODELS,
  WakeWordEngine,
  defineModel,
  getNativeWakeWord,
} from '../engine';
import {installFakeNative} from './utils/fakeNative';

const native = installFakeNative();

beforeEach(() => {
  native.reset();
});

describe('getNativeWakeWord', () => {
  it('creates the HybridObject lazily and only once', () => {
    expect(getNativeWakeWord()).toBe(native);
    expect(getNativeWakeWord()).toBe(native);
    expect(NitroModules.createHybridObject).toHaveBeenCalledTimes(1);
    expect(NitroModules.createHybridObject).toHaveBeenCalledWith('WakeWord');
  });
});

describe('WakeWordEngine', () => {
  it('forwards lifecycle calls and state to the native object', async () => {
    const config = {models: [{model: BUILTIN_MODELS.heyJarvis}]};

    await WakeWordEngine.load(config);
    expect(native.load).toHaveBeenCalledWith(config);
    expect(WakeWordEngine.isLoaded).toBe(true);

    await WakeWordEngine.start();
    expect(WakeWordEngine.isListening).toBe(true);
    WakeWordEngine.stop();
    expect(WakeWordEngine.isListening).toBe(false);

    WakeWordEngine.setThreshold('hey_jarvis', 0.8);
    expect(native.setThreshold).toHaveBeenCalledWith('hey_jarvis', 0.8);

    WakeWordEngine.unload();
    expect(WakeWordEngine.isLoaded).toBe(false);
  });

  it('fans out detections to every listener and unsubscribes cleanly', () => {
    const first = jest.fn();
    const second = jest.fn();
    const detection = {keyword: 'hey_jarvis', score: 0.9, timestamp: 1};

    const offFirst = WakeWordEngine.addDetectionListener(first);
    const offSecond = WakeWordEngine.addDetectionListener(second);
    expect(native.setDetectionListener).toHaveBeenCalled();

    native.emitDetection(detection);
    expect(first).toHaveBeenCalledWith(detection);
    expect(second).toHaveBeenCalledWith(detection);

    offFirst();
    native.emitDetection(detection);
    expect(first).toHaveBeenCalledTimes(1);
    expect(second).toHaveBeenCalledTimes(2);
    expect(native.hasDetectionListener()).toBe(true);

    offSecond();
    expect(native.clearDetectionListener).toHaveBeenCalled();
    expect(native.hasDetectionListener()).toBe(false);
  });

  it('keeps score and error listeners independent from detection listeners', () => {
    const onScore = jest.fn();
    const onError = jest.fn();

    const offScore = WakeWordEngine.addScoreListener(onScore);
    const offError = WakeWordEngine.addErrorListener(onError);
    expect(native.hasDetectionListener()).toBe(false);

    native.emitScore('hey_jarvis', 0.42);
    native.emitError('boom');
    expect(onScore).toHaveBeenCalledWith('hey_jarvis', 0.42);
    expect(onError).toHaveBeenCalledWith('boom');

    offScore();
    expect(native.hasScoreListener()).toBe(false);
    expect(native.hasErrorListener()).toBe(true);
    offError();
    expect(native.hasErrorListener()).toBe(false);
  });

  it('exposes permission helpers', async () => {
    native.hasMicrophonePermission.mockReturnValue(false);
    expect(WakeWordEngine.hasMicrophonePermission()).toBe(false);
    await expect(WakeWordEngine.requestMicrophonePermission()).resolves.toBe(
      true,
    );
    expect(native.requestMicrophonePermission).toHaveBeenCalled();
  });
});

describe('defineModel', () => {
  it('applies defaults and lets options override them', () => {
    expect(defineModel('hey_nova.onnx')).toEqual({
      model: 'hey_nova.onnx',
      threshold: 0.5,
      patience: 1,
    });
    expect(
      defineModel('hey_nova.onnx', {keyword: 'nova', threshold: 0.8}),
    ).toEqual({
      model: 'hey_nova.onnx',
      keyword: 'nova',
      threshold: 0.8,
      patience: 1,
    });
  });
});

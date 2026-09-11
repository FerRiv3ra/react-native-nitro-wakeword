import {useMemo, useState} from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';
import {
  BUILTIN_MODELS,
  WakeWordEngine,
  useWakeWord,
  type WakeWordConfig,
} from 'react-native-nitro-wakeword';

export default function App() {
  const [count, setCount] = useState(0);
  const [score, setScore] = useState(0);
  const config = useMemo<WakeWordConfig>(
    () => ({
      models: [
        {
          model: BUILTIN_MODELS.heyJarvis,
          keyword: 'hey_jarvis',
          threshold: 0.6,
          patience: 2,
        },
        // Copied from example/assets/wakeword/ by the config plugin.
        {
          model: 'alexa_v0.1.onnx',
          keyword: 'alexa',
          threshold: 0.6,
          patience: 2,
        },
      ],
      vadThreshold: 0.3,
      refractoryMs: 1500,
      foregroundService: true,
      notificationTitle: 'NitroWakeWord',
      notificationText: 'Listening for hey jarvis',
    }),
    [],
  );
  const {isLoaded, isListening, lastDetection, error, start, stop} =
    useWakeWord({
      config,
      onDetected: d => {
        console.log('[wakeword] detected', d.keyword, d.score.toFixed(2));
        setCount(c => c + 1);
      },
      onError: e => console.log('[wakeword] error', e),
    });

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Say "hey jarvis" or "alexa"</Text>
      <Text>loaded: {String(isLoaded)}</Text>
      <Text>listening: {String(isListening)}</Text>
      <Text>detections: {count}</Text>
      <Text>
        last:{' '}
        {lastDetection
          ? `${lastDetection.keyword} (${lastDetection.score.toFixed(2)})`
          : '-'}
      </Text>
      <Text>score: {score.toFixed(2)}</Text>
      {error ? <Text style={styles.error}>{error}</Text> : null}
      <View style={styles.row}>
        <Pressable style={styles.button} onPress={start}>
          <Text>Start</Text>
        </Pressable>
        <Pressable style={styles.button} onPress={stop}>
          <Text>Stop</Text>
        </Pressable>
        <Pressable
          style={styles.button}
          onPress={() =>
            WakeWordEngine.addScoreListener((_, s) => setScore(s))
          }>
          <Text>Scores</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8},
  title: {fontSize: 22, fontWeight: '600', marginBottom: 12},
  error: {color: 'red'},
  row: {flexDirection: 'row', gap: 12, marginTop: 16},
  button: {
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: '#ddd',
    borderRadius: 8,
  },
});

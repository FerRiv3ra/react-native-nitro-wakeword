# Training a custom wake word

The runtime in this package is openWakeWord's, so any classifier trained with
openWakeWord's tooling works unchanged. This guide walks through training a
Spanish wake word ("hey Nova") on a free Google Colab GPU. English or any
language with a [Piper](https://github.com/rhasspy/piper) voice works the same.

## 1. Open the notebook

<https://colab.research.google.com/drive/1q1oe2zOyZp7UsB3jJiQ1IFn8z5YfjwEb>
(`notebooks/automatic_model_training.ipynb` in the openWakeWord repo).
Select a GPU runtime (T4 is enough).

## 2. Pick the phrase(s)

TTS engines struggle with invented words. Give the generator several spellings
that produce the pronunciation you want and mix them:

```yaml
target_phrase:
  - 'hey nova'
  - 'ey nova'
  - 'oye nova'
model_name: 'hey_nova'
```

Listen to a few generated clips (`output_dir/positive_train/*.wav`) and drop
spellings that sound wrong.

## 3. Use Spanish voices

The default generator uses English LibriTTS voices. For Spanish, point
`piper-sample-generator` at Spanish Piper models, e.g.:

- `es_ES-davefx-medium`, `es_ES-sharvard-medium`, `es_MX-claude-high`, `es_MX-ale-medium`

Download the `.onnx` + `.onnx.json` for each voice from
<https://huggingface.co/rhasspy/piper-voices/tree/main/es> and pass them via
`--model` when generating samples. More voices = better generalisation.

Recommended counts for a production model:

| Set                                         | Samples |
| ------------------------------------------- | ------- |
| positive train                              | 30 000+ |
| positive test                               | 2 000   |
| negative (adversarial phrases, same voices) | 30 000+ |

Add adversarial negatives: phrases that sound similar ("hey novia", "innova",
"hey nuevo", "renovar"). The notebook has `custom_negative_phrases` for this.

## 4. Augmentation

Keep the defaults (room impulse responses + background noise from the
notebook's datasets) and add **real recordings** of your target environment as
extra negative audio if you can: 10–30 minutes of typical app usage without the
wake word cuts false positives dramatically.

Optional but recommended: record 20–50 real positives with different phones
and people and add them to `positive_train` (the notebook's `augment` step
accepts custom directories).

## 5. Train and export

Run the training cells. Output:

```
my_custom_model/hey_nova.onnx
```

Check the model shape (must be `[1, N, 96]` → `[1, 1]`):

```sh
python -c "import onnxruntime as o; s=o.InferenceSession('hey_nova.onnx'); print(s.get_inputs()[0].shape, s.get_outputs()[0].shape)"
```

## 6. Ship it

- Expo: drop it in `assets/wakeword/` (or the plugin's `modelsDir`) and run
  `npx expo prebuild`. The config plugin copies it into both native projects.
- Bare React Native: add it to the app target in Xcode (Copy Bundle Resources)
  and to `android/app/src/main/assets/`.
- Any setup: download it at runtime and pass the absolute path / `file://` URI.

```ts
await WakeWordEngine.load({
  models: [
    {model: 'hey_nova.onnx', keyword: 'hey_nova', threshold: 0.7, patience: 2},
  ],
});
```

## 7. Tune on device

Enable `addScoreListener` in a debug screen, say the wake word 20 times in
quiet and noisy conditions and note the score distribution. Set `threshold`
between the highest false-positive score seen during normal use and the lowest
true-positive score. Typical production values: `0.6`–`0.9`, `patience: 2`.

## Reusing models from other vendors

Any vendor whose runtime ships `melspectrogram.onnx` + `embedding_model.onnx`
is running openWakeWord. Their keyword models are usually openWakeWord
classifiers, sometimes with a different window (`[1, 28, 96]` instead of
`[1, 16, 96]`) and sometimes encrypted. Plain `.onnx` files work directly; this
package reads the window size from the model.

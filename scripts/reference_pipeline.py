#!/usr/bin/env python3
"""
Reference implementation of the exact pipeline used by the native code.
Use it to validate a classifier on a WAV file (16 kHz mono PCM16) before
shipping it, or to compare native scores against a known-good baseline.

  pip install onnxruntime numpy
  python scripts/reference_pipeline.py models/hey_jarvis_v0.1.onnx sample.wav [--no-vad] [--window 16]
"""
import argparse
import sys
import wave
from pathlib import Path

import numpy as np
import onnxruntime as ort

MODELS = Path(__file__).resolve().parent.parent / "models"


def load_wav(path: str) -> np.ndarray:
    with wave.open(path) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, \
            "expected 16 kHz mono PCM16"
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)


def append(values: np.ndarray, count: int, buf: np.ndarray) -> None:
    buf[:-count] = buf[count:]
    buf[-count:] = values[:count]


def run(classifier: str, wav: str, use_vad: bool = True, vad_threshold: float = 0.3, window: int | None = None):
    mel = ort.InferenceSession(MODELS / "melspectrogram.onnx")
    emb = ort.InferenceSession(MODELS / "embedding_model.onnx")
    clf = ort.InferenceSession(classifier)
    vad = ort.InferenceSession(MODELS / "silero_vad.onnx") if use_vad else None
    clf_input = clf.get_inputs()[0]
    n = window or (clf_input.shape[1] if isinstance(clf_input.shape[1], int) else 16)

    audio = np.concatenate([np.zeros(16000, np.float32), load_wav(wav), np.zeros(16000, np.float32)])
    raw = np.zeros(1760, np.float32)
    melbuf = np.ones(76 * 32, np.float32)
    feats = np.zeros(n * 96, np.float32)
    h = np.zeros((2, 1, 64), np.float32)
    c = np.zeros((2, 1, 64), np.float32)
    pending: list[float] = []
    vscores = np.zeros(12)
    vi = melseen = fseen = 0
    scores = []

    for i in range(0, len(audio) - 1279, 1280):
        chunk = audio[i:i + 1280]
        if vad is not None:
            pending.extend((chunk / 32768).tolist())
            latest = None
            while len(pending) >= 512:
                x = np.array(pending[:512], np.float32)[None]
                del pending[:512]
                out, h, c = vad.run(None, {"input": x, "sr": np.array(16000, np.int64), "h": h, "c": c})
                latest = float(out[0, 0])
            if latest is not None:
                vscores[vi] = latest
                vi = (vi + 1) % 12
        raw[:480] = raw[-480:]
        raw[480:] = chunk
        m = mel.run(None, {"input": raw[None]})[0].flatten() / 10 + 2
        append(m, len(m), melbuf)
        melseen += len(m) // 32
        if melseen < 76:
            continue
        e = emb.run(None, {"input_1": melbuf.reshape(1, 76, 32, 1)})[0].flatten()
        append(e, 96, feats)
        fseen += 1
        if fseen < n:
            continue
        s = float(clf.run(None, {clf_input.name: feats.reshape(1, n, 96)})[0].flatten()[0])
        if vad is not None and vscores.max() < vad_threshold:
            s = 0.0
        scores.append(s)
    return np.array(scores)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("classifier")
    p.add_argument("wav")
    p.add_argument("--no-vad", action="store_true")
    p.add_argument("--vad-threshold", type=float, default=0.3)
    p.add_argument("--window", type=int, default=None)
    a = p.parse_args()
    s = run(a.classifier, a.wav, not a.no_vad, a.vad_threshold, a.window)
    print(f"frames={len(s)} max={s.max():.3f} frames>0.5={(s > 0.5).sum()}")
    print(" ".join(f"{v:.2f}" for v in s))
    sys.exit(0)

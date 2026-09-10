#!/bin/sh
# Re-downloads the base openWakeWord models (Apache 2.0) from the upstream
# GitHub release. Run from the package root: sh scripts/download-models.sh
set -e
BASE="https://github.com/dscripka/openWakeWord/releases/download/v0.5.1"
DIR="$(cd "$(dirname "$0")/.." && pwd)/models"
mkdir -p "$DIR"
for f in melspectrogram.onnx embedding_model.onnx silero_vad.onnx hey_jarvis_v0.1.onnx; do
  echo "downloading $f"
  curl -sSL -o "$DIR/$f" "$BASE/$f"
done
echo "done -> $DIR"
ls -la "$DIR"

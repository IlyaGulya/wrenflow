#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/whisper-spike-guard.sh"

WRENFLOW_SPIKE_MIN_FREE_GB="${WRENFLOW_SPIKE_MIN_FREE_GB:-80}"
whisper_spike_preflight

RUNTIME_PYTHON="${HOME}/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
PYTHON_BIN="${PYTHON_BIN:-}"

if [[ -z "$PYTHON_BIN" ]]; then
  if [[ -x "$RUNTIME_PYTHON" ]]; then
    PYTHON_BIN="$RUNTIME_PYTHON"
  else
    PYTHON_BIN="$(command -v python3)"
  fi
fi

if [[ -z "$PYTHON_BIN" ]]; then
  echo "python3 not found" >&2
  exit 1
fi

MODEL_ID="${1:-openai/whisper-large-v3-turbo}"
OUTPUT_DIR="${2:-/tmp/wrenflow-whisper-export/$(basename "$MODEL_ID")-with-past}"
VENV_DIR="${WHISPER_EXPORT_VENV_DIR:-/tmp/wrenflow-whisper-export312}"

echo "Using Python: $PYTHON_BIN"
echo "Model ID: $MODEL_ID"
echo "Output: $OUTPUT_DIR"
echo "Venv: $VENV_DIR"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

python -m pip install -q \
  'torch>=2.3,<2.7' \
  'transformers>=4.48,<4.58' \
  'optimum[exporters]>=1.24,<1.28' \
  'onnx>=1.17,<1.19'

mkdir -p "$(dirname "$OUTPUT_DIR")"
rm -rf "$OUTPUT_DIR"

optimum-cli export onnx \
  -m "$MODEL_ID" \
  --task automatic-speech-recognition-with-past \
  --no-post-process \
  "$OUTPUT_DIR"

echo
echo "Export finished."
find "$OUTPUT_DIR" -maxdepth 1 -type f | sort

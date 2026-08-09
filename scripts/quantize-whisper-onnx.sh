#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/whisper-spike-guard.sh"

WRENFLOW_SPIKE_MIN_FREE_GB="${WRENFLOW_SPIKE_MIN_FREE_GB:-60}"
whisper_spike_preflight

INPUT_DIR="${1:-/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past}"
OUTPUT_DIR="${2:-/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-int8}"
VENV_DIR="${WHISPER_EXPORT_VENV_DIR:-/tmp/wrenflow-whisper-export312}"

if [ ! -d "$INPUT_DIR" ]; then
  echo "Input Whisper ONNX export not found: $INPUT_DIR" >&2
  exit 1
fi

PYTHON_BIN=""
if [ -x "$VENV_DIR/bin/python3" ]; then
  PYTHON_BIN="$VENV_DIR/bin/python3"
elif [ -x "$VENV_DIR/bin/python" ]; then
  PYTHON_BIN="$VENV_DIR/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
else
  echo "python3 not found" >&2
  exit 1
fi

if ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import importlib.util
mods = ["onnxruntime", "onnx", "ml_dtypes"]
missing = [m for m in mods if importlib.util.find_spec(m) is None]
raise SystemExit(1 if missing else 0)
PY
then
  PIP_BIN="${PYTHON_BIN%python3}pip3"
  if [ ! -x "$PIP_BIN" ]; then
    PIP_BIN="${PYTHON_BIN%python}pip"
  fi
  if [ ! -x "$PIP_BIN" ]; then
    echo "pip not found next to $PYTHON_BIN" >&2
    exit 1
  fi
  "$PIP_BIN" install "onnxruntime>=1.24,<1.25" "onnx>=1.17,<1.19" "ml_dtypes>=0.5,<0.6"
fi

"$PYTHON_BIN" - <<'PY' "$INPUT_DIR" "$OUTPUT_DIR"
from pathlib import Path
from shutil import copy2, rmtree
import sys

from onnxruntime.quantization import QuantType, quantize_dynamic

src = Path(sys.argv[1])
out = Path(sys.argv[2])

if out.exists():
    rmtree(out)
out.mkdir(parents=True, exist_ok=True)

metadata = [
    "config.json",
    "generation_config.json",
    "preprocessor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
    "added_tokens.json",
    "merges.txt",
    "normalizer.json",
    "vocab.json",
]

for name in metadata:
    copy2(src / name, out / name)

for name in [
    "encoder_model.onnx",
    "decoder_model.onnx",
    "decoder_with_past_model.onnx",
]:
    print(f"quantizing {name}", flush=True)
    quantize_dynamic(
        model_input=str(src / name),
        model_output=str(out / name),
        per_channel=False,
        reduce_range=False,
        weight_type=QuantType.QInt8,
        extra_options={"EnableSubgraph": True},
    )

print(f"wrote quantized export to {out}")
PY

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/whisper-spike-guard.sh"

WRENFLOW_SPIKE_MIN_FREE_GB="${WRENFLOW_SPIKE_MIN_FREE_GB:-90}"
whisper_spike_preflight

INPUT_DIR="${1:-/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past}"
OUTPUT_DIR="${2:-/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-encoder-static}"
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
mods = ["onnxruntime", "onnx", "ml_dtypes", "numpy"]
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
  "$PIP_BIN" install "onnxruntime>=1.24,<1.25" "onnx>=1.17,<1.19" "ml_dtypes>=0.5,<0.6" "numpy>=2.0,<2.4"
fi

"$PYTHON_BIN" - <<'PY' "$INPUT_DIR" "$OUTPUT_DIR"
from __future__ import annotations

import json
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import onnx
import numpy as np
from onnxruntime.quantization import (
    CalibrationDataReader,
    CalibrationMethod,
    QuantFormat,
    QuantType,
    StaticQuantConfig,
    quantize,
    quantize_dynamic,
)
from onnxruntime.quantization.shape_inference import quant_pre_process


INPUT_DIR = Path(sys.argv[1])
OUTPUT_DIR = Path(sys.argv[2])
RECORDINGS_DIR = Path(
    os.environ.get(
        "WRENFLOW_CALIBRATION_RECORDINGS_DIR",
        str(Path.home() / "Library/Application Support/Wrenflow/recordings"),
    )
)
MAX_RECORDINGS = int(os.environ.get("WRENFLOW_CALIBRATION_MAX_RECORDINGS", "8"))
MATMUL_CONST_B_ONLY = os.environ.get("WRENFLOW_STATIC_ENCODER_MATMUL_CONST_B_ONLY", "1").lower() not in {
    "0",
    "false",
    "no",
    "off",
}
QUANT_MODE = os.environ.get("WRENFLOW_STATIC_ENCODER_MODE", "constb").strip().lower()
HOT_ATTENTION_LAYERS = [
    int(v)
    for v in os.environ.get(
        "WRENFLOW_STATIC_ENCODER_HOT_ATTENTION_LAYERS",
        "5,7,10,12,14,17,18,22,23,27,28,29",
    ).split(",")
    if v.strip()
]


def load_json(path: Path):
    return json.loads(path.read_text())


def decode_ogg_to_f32(path: Path) -> np.ndarray:
    proc = subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-i",
            str(path),
            "-f",
            "f32le",
            "-ac",
            "1",
            "-ar",
            "16000",
            "pipe:1",
        ],
        check=True,
        capture_output=True,
    )
    return np.frombuffer(proc.stdout, dtype="<f4").astype(np.float32, copy=True)


def reflect_index(idx: int, length: int) -> int:
    while idx < 0 or idx >= length:
        if idx < 0:
            idx = -idx
        if idx >= length:
            idx = 2 * length - idx - 2
    return idx


def reflect_pad(values: np.ndarray, pad: int) -> np.ndarray:
    left = [values[reflect_index(-pad + i, len(values))] for i in range(pad)]
    right = [values[reflect_index(len(values) + i, len(values))] for i in range(pad)]
    return np.concatenate([np.asarray(left, dtype=np.float32), values, np.asarray(right, dtype=np.float32)])


def periodic_hann_window(window_length: int) -> np.ndarray:
    return np.array(
        [0.5 - 0.5 * math.cos((2.0 * math.pi * i) / window_length) for i in range(window_length)],
        dtype=np.float32,
    )


F_SP = 200.0 / 3.0
MIN_LOG_HZ = 1000.0
MIN_LOG_MEL = MIN_LOG_HZ / F_SP
LOG_STEP = 0.06875177742094912


def hz_to_mel_slaney(hz: float) -> float:
    if hz < MIN_LOG_HZ:
        return hz / F_SP
    return MIN_LOG_MEL + math.log(hz / MIN_LOG_HZ) / LOG_STEP


def mel_to_hz_slaney(mel: float) -> float:
    if mel < MIN_LOG_MEL:
        return mel * F_SP
    return MIN_LOG_HZ * math.exp((mel - MIN_LOG_MEL) * LOG_STEP)


def create_mel_filterbank(n_fft: int, n_mels: int, sample_rate: int) -> np.ndarray:
    freq_bins = n_fft // 2 + 1
    filterbank = np.zeros((n_mels, freq_bins), dtype=np.float32)
    fmax = sample_rate / 2.0
    mel_min = hz_to_mel_slaney(0.0)
    mel_max = hz_to_mel_slaney(fmax)
    mel_points = [
        mel_to_hz_slaney(mel_min + (mel_max - mel_min) * i / (n_mels + 1))
        for i in range(n_mels + 2)
    ]
    fft_freqs = [i * sample_rate / n_fft for i in range(freq_bins)]
    fdiff = [mel_points[i + 1] - mel_points[i] for i in range(len(mel_points) - 1)]

    for mel_idx in range(n_mels):
        for bin_idx, freq in enumerate(fft_freqs):
            lower = (freq - mel_points[mel_idx]) / fdiff[mel_idx]
            upper = (mel_points[mel_idx + 2] - freq) / fdiff[mel_idx + 1]
            filterbank[mel_idx, bin_idx] = max(0.0, min(lower, upper))

    for mel_idx in range(n_mels):
        enorm = 2.0 / (mel_points[mel_idx + 2] - mel_points[mel_idx])
        filterbank[mel_idx, :] *= np.float32(enorm)

    return filterbank


class WhisperFeatureExtractor:
    def __init__(self, config: dict):
        self.sampling_rate = int(config["sampling_rate"])
        self.feature_size = int(config["feature_size"])
        self.hop_length = int(config["hop_length"])
        self.n_fft = int(config["n_fft"])
        self.n_samples = int(config["n_samples"])
        self.nb_max_frames = int(config["nb_max_frames"])
        self.window = periodic_hann_window(self.n_fft)
        self.mel_filterbank = create_mel_filterbank(self.n_fft, self.feature_size, self.sampling_rate)

    def extract(self, samples: np.ndarray) -> np.ndarray:
        if samples.shape[0] > self.n_samples:
            samples = samples[: self.n_samples]
        padded = reflect_pad(samples, self.n_fft // 2)
        frames = max(0, (len(padded) - self.n_fft) // self.hop_length + 1)
        usable_frames = max(0, frames - 1)
        freq_bins = self.n_fft // 2 + 1
        spectrogram = np.zeros((freq_bins, usable_frames), dtype=np.float32)

        for frame_idx in range(usable_frames):
            start = frame_idx * self.hop_length
            frame = padded[start : start + self.n_fft] * self.window
            fft_bins = np.fft.rfft(frame, n=self.n_fft)
            spectrogram[:, frame_idx] = (fft_bins.real ** 2 + fft_bins.imag ** 2).astype(np.float32)

        mel_spectrogram = self.mel_filterbank @ spectrogram
        log_spec = np.log10(np.maximum(mel_spectrogram, 1e-10))
        max_value = np.max(log_spec)
        clamp_floor = max_value - 8.0
        log_spec = np.maximum(log_spec, clamp_floor)
        log_spec = (log_spec + 4.0) / 4.0
        normalized_floor = (clamp_floor + 4.0) / 4.0

        current_frames = log_spec.shape[1]
        if current_frames >= self.nb_max_frames:
            return log_spec[:, : self.nb_max_frames][None, :, :].astype(np.float32, copy=False)

        padded_features = np.full(
            (self.feature_size, self.nb_max_frames),
            normalized_floor,
            dtype=np.float32,
        )
        padded_features[:, :current_frames] = log_spec
        return padded_features[None, :, :]


class RecordingFeatureReader(CalibrationDataReader):
    def __init__(self, recordings_dir: Path, extractor: WhisperFeatureExtractor, max_recordings: int):
        files = sorted(recordings_dir.glob("*.ogg"))[-max_recordings:]
        self._items: list[dict[str, np.ndarray]] = []
        for path in files:
            samples = decode_ogg_to_f32(path)
            self._items.append({"input_features": extractor.extract(samples)})
        self._iter = iter(self._items)

    def get_next(self):
        return next(self._iter, None)


def select_nodes_to_quantize(model_path: Path) -> tuple[list[str] | None, bool]:
    if QUANT_MODE == "allmatmul":
        return None, False

    model = onnx.load(model_path, load_external_data=False)
    nodes_to_quantize: list[str] = []

    def add_matching(pattern: str, allowed_ops: set[str] | None = None) -> None:
        regex = re.compile(pattern)
        for node in model.graph.node:
            if allowed_ops is not None and node.op_type not in allowed_ops:
                continue
            if regex.search(node.name):
                nodes_to_quantize.append(node.name)

    add_matching(r"^/conv[12]/Conv$", {"Conv"})

    if QUANT_MODE in {"constb", "mlp_only", "hybrid_hot_attention"}:
        if QUANT_MODE == "mlp_only":
            add_matching(r"/layers\.\d+/fc[12]/MatMul$", {"MatMul"})
            return sorted(set(nodes_to_quantize)), True

        add_matching(
            r"/layers\.\d+/(self_attn/(q_proj|k_proj|v_proj|out_proj)|fc[12])/MatMul$",
            {"MatMul"},
        )

        if QUANT_MODE == "hybrid_hot_attention":
            layer_group = "|".join(str(layer) for layer in HOT_ATTENTION_LAYERS)
            add_matching(
                rf"/layers\.({layer_group})/self_attn/MatMul(_1)?$",
                {"MatMul"},
            )
            return sorted(set(nodes_to_quantize)), False

        return sorted(set(nodes_to_quantize)), True

    raise SystemExit(
        f"unsupported WRENFLOW_STATIC_ENCODER_MODE={QUANT_MODE!r}; "
        "expected one of: constb, mlp_only, hybrid_hot_attention, allmatmul"
    )


def main() -> None:
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for name in [
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
    ]:
        src = INPUT_DIR / name
        if src.exists():
            shutil.copy2(src, OUTPUT_DIR / name)

    preprocessor_config = load_json(INPUT_DIR / "preprocessor_config.json")
    extractor = WhisperFeatureExtractor(preprocessor_config)
    reader = RecordingFeatureReader(RECORDINGS_DIR, extractor, MAX_RECORDINGS)
    if not reader._items:
        raise SystemExit(f"no calibration recordings found in {RECORDINGS_DIR}")

    preprocessed_encoder = OUTPUT_DIR / "encoder_model.preprocessed.onnx"
    print("preprocessing encoder for quantization", flush=True)
    quant_pre_process(
        str(INPUT_DIR / "encoder_model.onnx"),
        str(preprocessed_encoder),
        skip_optimization=True,
        skip_onnx_shape=False,
        skip_symbolic_shape=False,
        auto_merge=False,
        int_max=2**31 - 1,
        guess_output_rank=False,
        verbose=1,
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        external_data_location="encoder_model.preprocessed.onnx.data",
        external_data_size_threshold=1024,
    )

    print(f"static-quantizing encoder with {len(reader._items)} recordings", flush=True)
    nodes_to_quantize, effective_const_b_only = select_nodes_to_quantize(preprocessed_encoder)
    if nodes_to_quantize is None:
        print("quantizing all MatMul/Conv encoder nodes", flush=True)
    else:
        print(
            f"quantizing {len(nodes_to_quantize)} selected encoder nodes "
            f"(mode={QUANT_MODE}, MatMulConstBOnly={effective_const_b_only})",
            flush=True,
        )
    quant_config = StaticQuantConfig(
        calibration_data_reader=reader,
        calibrate_method=CalibrationMethod.MinMax,
        quant_format=QuantFormat.QOperator,
        activation_type=QuantType.QUInt8,
        weight_type=QuantType.QInt8,
        op_types_to_quantize=["MatMul", "Conv"],
        nodes_to_quantize=nodes_to_quantize,
        nodes_to_exclude=None,
        per_channel=False,
        reduce_range=False,
        use_external_data_format=True,
        calibration_providers=None,
        extra_options={
            "EnableSubgraph": True,
            "MatMulConstBOnly": effective_const_b_only if nodes_to_quantize is not None else MATMUL_CONST_B_ONLY,
            "ForceQuantizeNoInputCheck": False,
        },
    )
    quantize(
        model_input=str(preprocessed_encoder),
        model_output=str(OUTPUT_DIR / "encoder_model.static_qop.onnx"),
        quant_config=quant_config,
    )

    for src_name, dst_name in [
        ("decoder_model.onnx", "decoder_model.dynamic_int8.onnx"),
        ("decoder_with_past_model.onnx", "decoder_with_past_model.dynamic_int8.onnx"),
    ]:
        print(f"dynamic-quantizing {src_name}", flush=True)
        quantize_dynamic(
            model_input=str(INPUT_DIR / src_name),
            model_output=str(OUTPUT_DIR / dst_name),
            per_channel=False,
            reduce_range=False,
            weight_type=QuantType.QInt8,
            extra_options={"EnableSubgraph": True},
        )

    print(f"wrote static-encoder bundle to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
PY

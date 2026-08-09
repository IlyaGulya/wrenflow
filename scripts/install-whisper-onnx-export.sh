#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/whisper-spike-guard.sh"

WRENFLOW_SPIKE_MIN_FREE_GB="${WRENFLOW_SPIKE_MIN_FREE_GB:-20}"
whisper_spike_preflight

SOURCE_DIR="${1:-/tmp/wrenflow-whisper-export/openai-whisper-large-v3-turbo-with-past-int8}"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/Wrenflow"
TARGET_DIR="${APP_SUPPORT_DIR}/models/whisper-large-v3-turbo"
BACKUP_ROOT="${APP_SUPPORT_DIR}/model-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

required_metadata_files=(
  "config.json"
  "generation_config.json"
  "preprocessor_config.json"
  "tokenizer.json"
  "tokenizer_config.json"
  "special_tokens_map.json"
  "added_tokens.json"
  "merges.txt"
  "normalizer.json"
  "vocab.json"
)

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source Whisper export not found: $SOURCE_DIR" >&2
  exit 1
fi

for file in "${required_metadata_files[@]}"; do
  if [ ! -f "$SOURCE_DIR/$file" ]; then
    echo "Missing required export file: $SOURCE_DIR/$file" >&2
    exit 1
  fi
done

resolve_model_path() {
  local source_dir="$1"
  local preferred_name="$2"
  shift 2
  local fallback_names=("$@")

  if [ -f "$source_dir/$preferred_name" ]; then
    printf '%s\n' "$source_dir/$preferred_name"
    return 0
  fi

  for name in "${fallback_names[@]}"; do
    if [ -f "$source_dir/$name" ]; then
      printf '%s\n' "$source_dir/$name"
      return 0
    fi
  done

  return 1
}

ENCODER_SOURCE="$(resolve_model_path "$SOURCE_DIR" "encoder_model.onnx" "encoder_model.static_qop.onnx" "onnx/encoder_model_int8.onnx")" || {
  echo "Missing encoder model in $SOURCE_DIR" >&2
  exit 1
}
DECODER_SOURCE="$(resolve_model_path "$SOURCE_DIR" "decoder_model.onnx" "decoder_model.dynamic_int8.onnx" "onnx/decoder_model_int8.onnx")" || {
  echo "Missing decoder model in $SOURCE_DIR" >&2
  exit 1
}
DECODER_WITH_PAST_SOURCE="$(resolve_model_path "$SOURCE_DIR" "decoder_with_past_model.onnx" "decoder_with_past_model.dynamic_int8.onnx" "onnx/decoder_with_past_model_int8.onnx")" || {
  echo "Missing decoder-with-past model in $SOURCE_DIR" >&2
  exit 1
}

copy_model_with_external_data() {
  local source_path="$1"
  local target_path="$2"

  cp "$source_path" "$target_path"

  for suffix in ".data" "_data"; do
    if [ -f "${source_path}${suffix}" ]; then
      cp "${source_path}${suffix}" "${target_path}${suffix}"
      local source_sidecar_name
      source_sidecar_name="$(basename "${source_path}${suffix}")"
      if [ "$source_sidecar_name" != "$(basename "${target_path}${suffix}")" ]; then
        cp "${source_path}${suffix}" "$(dirname "$target_path")/${source_sidecar_name}"
      fi
    fi
  done
}

mkdir -p "$BACKUP_ROOT"
if [ -d "$TARGET_DIR" ]; then
  BACKUP_DIR="$BACKUP_ROOT/whisper-large-v3-turbo-$TIMESTAMP"
  echo "Backing up existing model: $TARGET_DIR -> $BACKUP_DIR"
  mv "$TARGET_DIR" "$BACKUP_DIR"
fi

mkdir -p "$TARGET_DIR/onnx"

for file in \
  config.json generation_config.json preprocessor_config.json tokenizer.json tokenizer_config.json \
  special_tokens_map.json added_tokens.json merges.txt normalizer.json vocab.json; do
  cp "$SOURCE_DIR/$file" "$TARGET_DIR/$file"
done

copy_model_with_external_data "$ENCODER_SOURCE" "$TARGET_DIR/onnx/encoder_model_int8.onnx"
copy_model_with_external_data "$DECODER_SOURCE" "$TARGET_DIR/onnx/decoder_model_int8.onnx"
copy_model_with_external_data "$DECODER_WITH_PAST_SOURCE" "$TARGET_DIR/onnx/decoder_with_past_model_int8.onnx"
touch "$TARGET_DIR/.wrenflow-model-ready"

echo "Installed quantized Whisper export to: $TARGET_DIR"
echo "Backup root: $BACKUP_ROOT"

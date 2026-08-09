#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/whisper-spike-guard.sh"

WRENFLOW_SPIKE_MIN_FREE_GB="${WRENFLOW_SPIKE_MIN_FREE_GB:-20}"
whisper_spike_preflight

MODE="${1:-release}"

case "$MODE" in
  release)
    cargo_mode=(--release)
    ;;
  debug)
    cargo_mode=()
    ;;
  *)
    echo "Usage: $0 [release|debug]" >&2
    exit 1
    ;;
esac

echo "Running Whisper ONNX benchmark in $MODE mode"
echo "WRENFLOW_WHISPER_ORT_THREADS=${WRENFLOW_WHISPER_ORT_THREADS:-default}"
echo "WRENFLOW_WHISPER_ENABLE_COREML_EP=${WRENFLOW_WHISPER_ENABLE_COREML_EP:-0}"

mise exec -- cargo test -p wrenflow-core "${cargo_mode[@]}" \
  benchmark_alternative_whisper_onnx_exports \
  -- --ignored --nocapture --test-threads=1

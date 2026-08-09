#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/whisper-spike-guard.sh"

echo "Before cleanup:"
du -sh /tmp/wrenflow-whisper-export* /tmp/wrenflow-whispercpp-models 2>/dev/null | sort -h || true

whisper_spike_cleanup_old_artifacts

echo
echo "After cleanup:"
du -sh /tmp/wrenflow-whisper-export* /tmp/wrenflow-whispercpp-models 2>/dev/null | sort -h || true
df -h "${WRENFLOW_SPIKE_ROOT%/*}"

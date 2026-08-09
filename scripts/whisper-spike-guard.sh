#!/usr/bin/env bash
set -euo pipefail

WRENFLOW_SPIKE_ROOT="${WRENFLOW_SPIKE_ROOT:-/tmp/wrenflow-whisper-export}"
WRENFLOW_SPIKE_LOCKDIR="${WRENFLOW_SPIKE_LOCKDIR:-/tmp/wrenflow-whisper-spike.lock}"
WRENFLOW_SPIKE_MIN_FREE_GB="${WRENFLOW_SPIKE_MIN_FREE_GB:-40}"
WRENFLOW_SPIKE_CLEANUP_KEEP="${WRENFLOW_SPIKE_CLEANUP_KEEP:-4}"

whisper_spike_available_gb() {
  df -Pk "${WRENFLOW_SPIKE_ROOT%/*}" 2>/dev/null | awk 'NR==2 { printf "%.0f", $4 / 1024 / 1024 }'
}

whisper_spike_require_disk() {
  local available_gb
  available_gb="$(whisper_spike_available_gb)"
  if [[ -z "${available_gb:-}" ]]; then
    echo "Failed to determine free disk space for ${WRENFLOW_SPIKE_ROOT%/*}" >&2
    exit 1
  fi

  if (( available_gb < WRENFLOW_SPIKE_MIN_FREE_GB )); then
    cat >&2 <<EOF
Refusing to start Whisper spike job: only ${available_gb} GiB free on ${WRENFLOW_SPIKE_ROOT%/*}.
Required minimum: ${WRENFLOW_SPIKE_MIN_FREE_GB} GiB.

This guard exists because earlier ONNX export/quantization spikes filled swap and contributed to a system watchdog panic.
Clean old /tmp/wrenflow-whisper-export* artifacts or lower WRENFLOW_SPIKE_MIN_FREE_GB explicitly if you know what you are doing.
EOF
    exit 1
  fi
}

whisper_spike_acquire_lock() {
  if mkdir "${WRENFLOW_SPIKE_LOCKDIR}" 2>/dev/null; then
    printf '%s\n' "$$" > "${WRENFLOW_SPIKE_LOCKDIR}/pid"
    trap 'rm -rf "${WRENFLOW_SPIKE_LOCKDIR}"' EXIT
    return 0
  fi

  local owner="unknown"
  if [[ -f "${WRENFLOW_SPIKE_LOCKDIR}/pid" ]]; then
    owner="$(cat "${WRENFLOW_SPIKE_LOCKDIR}/pid" 2>/dev/null || printf 'unknown')"
  fi

  cat >&2 <<EOF
Another Whisper spike job is already running (lock: ${WRENFLOW_SPIKE_LOCKDIR}, owner pid: ${owner}).
Heavy export/quantization jobs are serialized on purpose to avoid disk/swap pressure.
EOF
  exit 1
}

whisper_spike_cleanup_old_artifacts() {
  mkdir -p "${WRENFLOW_SPIKE_ROOT}"

  local keep="${WRENFLOW_SPIKE_CLEANUP_KEEP}"
  mapfile -t dirs < <(find "${WRENFLOW_SPIKE_ROOT}" -mindepth 1 -maxdepth 1 -type d -print | xargs -I{} stat -f '%m %N' "{}" 2>/dev/null | sort -nr | awk '{ $1=""; sub(/^ /,""); print }')

  local idx=0
  for dir in "${dirs[@]}"; do
    idx=$((idx + 1))
    if (( idx > keep )); then
      rm -rf "${dir}"
    fi
  done
}

whisper_spike_preflight() {
  whisper_spike_require_disk
  whisper_spike_acquire_lock
  whisper_spike_cleanup_old_artifacts
  whisper_spike_require_disk
}

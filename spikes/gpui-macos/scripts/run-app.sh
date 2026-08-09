#!/usr/bin/env bash
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$SPIKE_DIR/../.." && pwd)"
APP_DIR="$REPO_DIR/build/gpui-spike/Wrenflow GPUI Spike.app"

if [[ ! -d "$APP_DIR" ]]; then
    echo "Spike bundle not found: run mise run gpui-spike-build first" >&2
    exit 1
fi

open "$APP_DIR"

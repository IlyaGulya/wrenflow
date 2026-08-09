#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
APP_DIR="$REPO_DIR/build/gpui/Wrenflow.app"

if [[ ! -d "$APP_DIR" ]]; then
    echo "Production GPUI bundle not found at $APP_DIR" >&2
    exit 1
fi

open "$APP_DIR" --args "$@"

#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
APP_PATH="$REPO_DIR/build/gpui/Wrenflow.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Production GPUI bundle not found at $APP_PATH" >&2
    exit 65
fi

EVIDENCE_DIR="$(mktemp -d /tmp/wrenflow-accessibility-self-test.XXXXXX)"
trap 'trash "$EVIDENCE_DIR"' EXIT
STDOUT_PATH="$EVIDENCE_DIR/stdout.log"
STDERR_PATH="$EVIDENCE_DIR/stderr.log"

open -n -W -o "$STDOUT_PATH" --stderr "$STDERR_PATH" \
    "$APP_PATH" --args --accessibility-self-test

if ! grep -Eq '^WRENFLOW_ACCESSIBILITY_SELF_TEST_OK nodes=[1-9][0-9]* generation=[1-9][0-9]*$' \
    "$STDOUT_PATH"; then
    echo "Signed accessibility self-test did not publish a native AX tree" >&2
    cat "$STDOUT_PATH" >&2
    cat "$STDERR_PATH" >&2
    exit 66
fi

cat "$STDOUT_PATH"

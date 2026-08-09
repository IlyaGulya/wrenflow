#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
APP_PATH="${WRENFLOW_TEST_APP:-$REPO_DIR/build/gpui/Wrenflow.app}"

if [[ "$APP_PATH" != /* || "$(basename "$APP_PATH")" != "Wrenflow.app" ]]; then
    echo "WRENFLOW_TEST_APP must be an absolute Wrenflow.app path" >&2
    exit 65
fi
if [[ ! -d "$APP_PATH" || -L "$APP_PATH" ]]; then
    echo "Production GPUI bundle not found or is a symlink: $APP_PATH" >&2
    exit 66
fi
codesign --verify --deep --strict "$APP_PATH"
PLIST="$APP_PATH/Contents/Info.plist"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
SIGNATURE="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
IDENTIFIER="$(sed -n 's/^Identifier=//p' <<<"$SIGNATURE")"
TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE")"
if [[ "$BUNDLE_ID" != "me.gulya.wrenflow" || "$IDENTIFIER" != "me.gulya.wrenflow" || \
      "$TEAM_ID" != "T4LV8K9BGV" ]]; then
    echo "Accessibility smoke requires the exact Wrenflow Developer ID bundle" >&2
    exit 67
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

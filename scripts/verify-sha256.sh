#!/usr/bin/env bash
set -euo pipefail

FILE_PATH="${1:-}"
EXPECTED_SHA256="${2:-}"
LABEL="${3:-artifact}"

if [[ ! -f "$FILE_PATH" ]]; then
    echo "$LABEL is missing: $FILE_PATH" >&2
    exit 65
fi
if [[ ! "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "$LABEL has an invalid pinned SHA-256" >&2
    exit 64
fi

ACTUAL_SHA256="$(shasum -a 256 "$FILE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "$LABEL SHA-256 mismatch: expected $EXPECTED_SHA256, got $ACTUAL_SHA256" >&2
    exit 66
fi

echo "$ACTUAL_SHA256  $FILE_PATH"

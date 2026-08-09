#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$REPO_DIR/support/performance/transcription-fixture-v1.json"
DESTINATION="${1:-}"

if [[ -z "$DESTINATION" || "$DESTINATION" != /* ]]; then
    echo "Usage: $0 <absolute-output.wav>" >&2
    exit 64
fi
if [[ -L "$DESTINATION" ]]; then
    echo "Fixture destination must not be a symlink: $DESTINATION" >&2
    exit 65
fi

EXPECTED_SHA="$(jq -r '.sha256' "$MANIFEST")"
EXPECTED_BYTES="$(jq -r '.bytes' "$MANIFEST")"
SOURCE_COMMIT="$(jq -r '.source.commit' "$MANIFEST")"
SOURCE_PATH="$(jq -r '.source.path' "$MANIFEST")"
SOURCE_URL="https://raw.githubusercontent.com/ggml-org/whisper.cpp/$SOURCE_COMMIT/$SOURCE_PATH"

if [[ -f "$DESTINATION" ]]; then
    ACTUAL_SHA="$(shasum -a 256 "$DESTINATION" | awk '{print $1}')"
    ACTUAL_BYTES="$(stat -f '%z' "$DESTINATION")"
    if [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" && "$ACTUAL_BYTES" == "$EXPECTED_BYTES" ]]; then
        printf 'fixture=%s sha256=%s bytes=%s\n' "$DESTINATION" "$ACTUAL_SHA" "$ACTUAL_BYTES"
        exit 0
    fi
    echo "Existing fixture does not match the immutable manifest: $DESTINATION" >&2
    exit 65
fi

PARENT="$(dirname "$DESTINATION")"
mkdir -p "$PARENT"
if [[ -L "$PARENT" ]]; then
    echo "Fixture parent must not be a symlink: $PARENT" >&2
    exit 65
fi

TEMPORARY="$(mktemp "$PARENT/.wrenflow-performance-fixture.XXXXXX")"
trap 'rm -f "$TEMPORARY"' EXIT
curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    "$SOURCE_URL" --output "$TEMPORARY"
ACTUAL_SHA="$(shasum -a 256 "$TEMPORARY" | awk '{print $1}')"
ACTUAL_BYTES="$(stat -f '%z' "$TEMPORARY")"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" || "$ACTUAL_BYTES" != "$EXPECTED_BYTES" ]]; then
    echo "Downloaded fixture failed immutable SHA-256/size verification" >&2
    exit 65
fi
chmod 0444 "$TEMPORARY"
mv "$TEMPORARY" "$DESTINATION"
trap - EXIT
printf 'fixture=%s sha256=%s bytes=%s\n' "$DESTINATION" "$ACTUAL_SHA" "$ACTUAL_BYTES"

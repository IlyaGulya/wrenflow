#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$REPO_DIR/scripts/verify-macos-support.sh"
FIXTURE_SOURCE="$REPO_DIR/scripts/fixtures/support-probe.c"
# shellcheck disable=SC1091
source "$REPO_DIR/support/macos.env"
INCOMPATIBLE_MINOS="$(( ${WRENFLOW_MACOS_MIN%%.*} + 1 )).0"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

"$VERIFY" source

mise exec -- xcrun clang \
    -arch arm64 \
    -mmacosx-version-min="$WRENFLOW_MACOS_MIN" \
    "$FIXTURE_SOURCE" \
    -o "$TMP_DIR/valid-arm64"
"$VERIFY" macho "$TMP_DIR/valid-arm64"

mise exec -- xcrun clang \
    -arch x86_64 \
    -mmacosx-version-min="$WRENFLOW_MACOS_MIN" \
    "$FIXTURE_SOURCE" \
    -o "$TMP_DIR/unsupported-intel"
if "$VERIFY" macho "$TMP_DIR/unsupported-intel" >/dev/null 2>&1; then
    echo "Support verifier accepted an Intel artifact" >&2
    exit 1
fi

mise exec -- xcrun clang \
    -arch arm64 \
    -mmacosx-version-min="$INCOMPATIBLE_MINOS" \
    "$FIXTURE_SOURCE" \
    -o "$TMP_DIR/incompatible-minos"
if "$VERIFY" macho "$TMP_DIR/incompatible-minos" >/dev/null 2>&1; then
    echo "Support verifier accepted an artifact newer than the bundle floor" >&2
    exit 1
fi

echo "macOS support contract rejects Intel and incompatible deployment targets"

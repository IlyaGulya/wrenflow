#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$REPO_DIR/scripts/verify-macos-support.sh"
VERIFY_SHADERS="$REPO_DIR/scripts/verify-gpui-shader-contract.sh"
FIXTURE_SOURCE="$REPO_DIR/scripts/fixtures/support-probe.c"
# shellcheck disable=SC1091
source "$REPO_DIR/support/macos.env"
INCOMPATIBLE_MINOS="$(( ${WRENFLOW_MACOS_MIN%%.*} + 1 )).0"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

"$VERIFY" source
mise exec -- "$VERIFY" metal
EMPTY_APP_CARGO_HOME="$TMP_DIR/empty-app-cargo-home"
if WRENFLOW_APP_CARGO_HOME="$EMPTY_APP_CARGO_HOME" \
    mise run verify-gpui-shader-contract >/dev/null 2>&1; then
    echo "Offline shader verification accepted an unfetched production graph" >&2
    exit 1
fi
WRENFLOW_APP_CARGO_HOME="$EMPTY_APP_CARGO_HOME" mise run setup-app-dependencies
WRENFLOW_APP_CARGO_HOME="$EMPTY_APP_CARGO_HOME" mise run verify-gpui-shader-contract
mise run verify-gpui-shader-contract
mise exec -- "$VERIFY_SHADERS" --tree-file \
    "$REPO_DIR/scripts/fixtures/gpui-feature-tree-embedded.txt"
if mise exec -- "$VERIFY_SHADERS" --tree-file \
    "$REPO_DIR/scripts/fixtures/gpui-feature-tree-runtime.txt" >/dev/null 2>&1; then
    echo "Shader verifier accepted a graph with runtime source compilation" >&2
    exit 1
fi

mkdir "$TMP_DIR/missing-metal"
printf '%s\n' '#!/bin/sh' 'exit 127' >"$TMP_DIR/missing-metal/xcrun"
chmod +x "$TMP_DIR/missing-metal/xcrun"
if PATH="$TMP_DIR/missing-metal:$PATH" mise exec -- "$VERIFY" metal >/dev/null 2>&1; then
    echo "Support verifier accepted a missing Metal toolchain" >&2
    exit 1
fi

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

echo "macOS support contract rejects missing Metal, Intel, and incompatible deployment targets"

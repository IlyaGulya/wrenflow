#!/usr/bin/env bash
set -euo pipefail

SPIKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$SPIKE_DIR/../.." && pwd)"
APP_DIR="$REPO_DIR/build/gpui-spike/Wrenflow GPUI Spike.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
BINARY_NAME="wrenflow-gpui-spike"
CARGO_BINARY_NAME="wrenflow-gpui-macos-spike"
SIGN_IDENTITY="${WRENFLOW_SPIKE_SIGN_IDENTITY:--}"
export CARGO_HOME="${CARGO_HOME:-$REPO_DIR/build/gpui-spike-cargo-home}"

cargo build \
    --manifest-path "$SPIKE_DIR/Cargo.toml" \
    --release \
    --locked \
    --config 'source.crates-io.registry="sparse+https://index.crates.io/"'

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR"
cp "$SPIKE_DIR/target/release/$CARGO_BINARY_NAME" "$MACOS_DIR/$BINARY_NAME"
cp "$SPIKE_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

ORT_SOURCE="$REPO_DIR/vendor/onnxruntime/lib/libonnxruntime.dylib"
SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi
if [[ -f "$ORT_SOURCE" ]]; then
    cp "$ORT_SOURCE" "$MACOS_DIR/libonnxruntime.dylib"
    codesign "${SIGN_ARGS[@]}" "$MACOS_DIR/libonnxruntime.dylib"
fi

codesign "${SIGN_ARGS[@]}" --entitlements "$SPIKE_DIR/WrenflowGPUI.entitlements" "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
plutil -lint "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"

#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_DIR/build/gpui-production-target}"
CARGO_HOME="${CARGO_HOME:-$REPO_DIR/build/gpui-production-cargo-home}"
FINAL_APP_DIR="$REPO_DIR/build/gpui/Wrenflow.app"
SIGN_IDENTITY="${WRENFLOW_GPUI_SIGN_IDENTITY:-Developer ID Application: Ilya Gulya (T4LV8K9BGV)}"
MANIFEST_VERSION="$(sed -n 's/^version = "\([^"]*\)".*$/\1/p' "$CRATE_DIR/Cargo.toml" | head -1)"
VERSION="${WRENFLOW_VERSION:-$MANIFEST_VERSION}"
BUILD_NUMBER="${WRENFLOW_BUILD_NUMBER:-$VERSION}"

if [[ -z "$VERSION" ]]; then
    echo "Could not determine Wrenflow version from $CRATE_DIR/Cargo.toml" >&2
    exit 1
fi

export CARGO_HOME CARGO_TARGET_DIR
cargo build \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    --release \
    --locked \
    --config 'source.crates-io.registry="sparse+https://index.crates.io/"'

if [[ "$FINAL_APP_DIR" != "$REPO_DIR/build/gpui/Wrenflow.app" ]]; then
    echo "Refusing to replace unexpected bundle path: $FINAL_APP_DIR" >&2
    exit 1
fi
mkdir -p "$REPO_DIR/build/gpui"
STAGING_ROOT="$(mktemp -d "$REPO_DIR/build/gpui/.Wrenflow.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_DIR="$STAGING_ROOT/Wrenflow.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LICENSES_DIR="$RESOURCES_DIR/ThirdPartyLicenses"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR" "$LICENSES_DIR"

cp "$TARGET_DIR/release/wrenflow-gpui" "$MACOS_DIR/wrenflow"
cp "$CRATE_DIR/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
cp "$REPO_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$REPO_DIR/Resources/ThirdPartyNotices.txt" "$RESOURCES_DIR/ThirdPartyNotices.txt"

GPUI_LICENSE="$(find "$CARGO_HOME/registry/src" -path '*/gpui-0.2.2/LICENSE-APACHE' -type f -print -quit)"
if [[ -z "$GPUI_LICENSE" ]]; then
    echo "GPUI Apache-2.0 license was not found in the locked Cargo source cache" >&2
    exit 1
fi
cp "$GPUI_LICENSE" "$LICENSES_DIR/GPUI-Apache-2.0.txt"

shopt -s nullglob
swift_libraries=("$TARGET_DIR"/release/build/wrenflow-gpui-*/out/libWrenflowShell.dylib)
if (( ${#swift_libraries[@]} == 0 )); then
    echo "Swift shell dylib was not produced by build.rs" >&2
    exit 1
fi
SWIFT_LIBRARY="$(ls -t "${swift_libraries[@]}" | head -1)"
cp "$SWIFT_LIBRARY" "$FRAMEWORKS_DIR/libWrenflowShell.dylib"

ORT_SOURCE="$REPO_DIR/vendor/onnxruntime/lib/libonnxruntime.dylib"
ORT_LICENSE="$REPO_DIR/vendor/onnxruntime/LICENSE"
ORT_NOTICES="$REPO_DIR/vendor/onnxruntime/ThirdPartyNotices.txt"
if [[ ! -f "$ORT_SOURCE" || ! -f "$ORT_LICENSE" || ! -f "$ORT_NOTICES" ]]; then
    echo "ONNX Runtime or its notices are missing; run 'mise run download-ort' first" >&2
    exit 1
fi
cp "$ORT_SOURCE" "$MACOS_DIR/libonnxruntime.dylib"
cp "$ORT_LICENSE" "$LICENSES_DIR/ONNX-Runtime-LICENSE.txt"
cp "$ORT_NOTICES" "$LICENSES_DIR/ONNX-Runtime-ThirdPartyNotices.txt"

sign_args=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    sign_args+=(--timestamp)
fi
codesign "${sign_args[@]}" "$MACOS_DIR/libonnxruntime.dylib"
codesign "${sign_args[@]}" "$FRAMEWORKS_DIR/libWrenflowShell.dylib"
codesign \
    "${sign_args[@]}" \
    --entitlements "$CRATE_DIR/macos/Wrenflow.entitlements" \
    "$APP_DIR"

plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign --display --verbose=4 "$APP_DIR" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Runtime Version)='

SWAP_LOCK="$REPO_DIR/build/gpui/.bundle-swap.lock"
if ! shlock -f "$SWAP_LOCK" -p "$$"; then
    echo "Another GPUI build is publishing the app bundle; retry this build" >&2
    exit 1
fi
trap 'rm -rf "$STAGING_ROOT"; rm -f "$SWAP_LOCK"' EXIT
rm -rf "$FINAL_APP_DIR"
mv "$APP_DIR" "$FINAL_APP_DIR"
rm -rf "$STAGING_ROOT"
rm -f "$SWAP_LOCK"
trap - EXIT

echo "$FINAL_APP_DIR"

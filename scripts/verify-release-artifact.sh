#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
DMG_PATH="${2:-}"
NOTARIZATION_MODE="${3:-}"
EXPECTED_BUNDLE_ID="${WRENFLOW_BUNDLE_ID:-me.gulya.wrenflow}"
EXPECTED_TEAM_ID="${WRENFLOW_TEAM_ID:-T4LV8K9BGV}"

if [[ ! -d "$APP_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "Usage: $0 <Wrenflow.app> <Wrenflow.dmg> [--require-notarized]" >&2
    exit 64
fi
if [[ -n "$NOTARIZATION_MODE" && "$NOTARIZATION_MODE" != "--require-notarized" ]]; then
    echo "Unknown verification mode: $NOTARIZATION_MODE" >&2
    exit 64
fi

PLIST="$APP_PATH/Contents/Info.plist"
BINARY="$APP_PATH/Contents/MacOS/wrenflow"
SHELL_DYLIB="$APP_PATH/Contents/Frameworks/libWrenflowShell.dylib"
ORT_DYLIB="$APP_PATH/Contents/MacOS/libonnxruntime.dylib"
NOTICES="$APP_PATH/Contents/Resources/ThirdPartyNotices.txt"
GPUI_LICENSE="$APP_PATH/Contents/Resources/ThirdPartyLicenses/GPUI-Apache-2.0.txt"
ORT_LICENSE="$APP_PATH/Contents/Resources/ThirdPartyLicenses/ONNX-Runtime-LICENSE.txt"
ORT_NOTICES="$APP_PATH/Contents/Resources/ThirdPartyLicenses/ONNX-Runtime-ThirdPartyNotices.txt"
for required_path in "$PLIST" "$BINARY" "$SHELL_DYLIB" "$ORT_DYLIB" \
    "$NOTICES" "$GPUI_LICENSE" "$ORT_LICENSE" "$ORT_NOTICES"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Release artifact is incomplete: $required_path is missing" >&2
        exit 65
    fi
done
grep -Fq "GPUI 0.2.2" "$NOTICES"
grep -Fq "gpui-component 0.5.1" "$NOTICES"
grep -Fq "ONNX Runtime 1.24.2" "$NOTICES"
grep -Fq "Apache License" "$GPUI_LICENSE"
grep -Fq "MIT License" "$ORT_LICENSE"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Unexpected bundle identifier: $BUNDLE_ID" >&2
    exit 66
fi

SIGNATURE="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
IDENTIFIER="$(sed -n 's/^Identifier=//p' <<<"$SIGNATURE")"
TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE")"
if [[ "$IDENTIFIER" != "$EXPECTED_BUNDLE_ID" || "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
    echo "Unexpected signing identity: Identifier=$IDENTIFIER TeamIdentifier=$TEAM_ID" >&2
    exit 67
fi
if ! grep -Eq 'CodeDirectory .*flags=.*runtime' <<<"$SIGNATURE"; then
    echo "The app signature does not enable the hardened runtime" >&2
    exit 68
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$SHELL_DYLIB"
codesign --verify --strict --verbose=2 "$ORT_DYLIB"
codesign --verify --strict --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [[ "$NOTARIZATION_MODE" == "--require-notarized" ]]; then
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH"
echo "Verified release artifact for $IDENTIFIER ($TEAM_ID)"

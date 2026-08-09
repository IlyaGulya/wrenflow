#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-}"
DMG_PATH="${2:-}"
NOTARIZATION_MODE="${3:-}"
EXPECTED_BUNDLE_ID="${WRENFLOW_BUNDLE_ID:-me.gulya.wrenflow}"
EXPECTED_TEAM_ID="${WRENFLOW_TEAM_ID:-T4LV8K9BGV}"

verify_signer() {
    local artifact="$1"
    local expected_identifier="$2"
    local signature identifier team_id

    signature="$(codesign --display --verbose=4 "$artifact" 2>&1)"
    identifier="$(sed -n 's/^Identifier=//p' <<<"$signature")"
    team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature")"
    if [[ "$identifier" != "$expected_identifier" || "$team_id" != "$EXPECTED_TEAM_ID" ]]; then
        echo "Unexpected signing identity for $artifact: Identifier=$identifier TeamIdentifier=$team_id" >&2
        exit 67
    fi
}

verify_macho_loads() {
    local artifact="$1"
    local allowed_rpath_load="$2"
    local load

    while IFS= read -r load; do
        case "$load" in
            /System/Library/*|/usr/lib/*|"$allowed_rpath_load") ;;
            *)
                echo "Unexpected Mach-O dependency in $artifact: $load" >&2
                exit 69
                ;;
        esac
    done < <(otool -L "$artifact" | tail -n +2 | awk '{print $1}')
}

verify_rpaths() {
    local artifact="$1"
    local expected="$2"
    local actual

    actual="$(otool -l "$artifact" |
        awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Unexpected LC_RPATH entries in $artifact: ${actual:-none}" >&2
        exit 69
    fi
}

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
RUST_LICENSES="$APP_PATH/Contents/Resources/RustThirdPartyLicenses.txt"
ORT_LICENSE="$APP_PATH/Contents/Resources/ThirdPartyLicenses/ONNX-Runtime-LICENSE.txt"
ORT_NOTICES="$APP_PATH/Contents/Resources/ThirdPartyLicenses/ONNX-Runtime-ThirdPartyNotices.txt"
SUPPLY_CHAIN="$APP_PATH/Contents/Resources/SupplyChain"
SBOM="$SUPPLY_CHAIN/Wrenflow.cdx.json"
PINS="$SUPPLY_CHAIN/pins.json"
EXCEPTIONS="$SUPPLY_CHAIN/exceptions.json"
PROVENANCE="$SUPPLY_CHAIN/provenance.json"
CHECKSUMS="$SUPPLY_CHAIN/SHA256SUMS"
for required_path in "$PLIST" "$BINARY" "$SHELL_DYLIB" "$ORT_DYLIB" \
    "$NOTICES" "$RUST_LICENSES" "$ORT_LICENSE" "$ORT_NOTICES" "$SBOM" \
    "$PINS" "$EXCEPTIONS" "$PROVENANCE" "$CHECKSUMS" \
    "$SUPPLY_CHAIN/RustThirdPartyLicenses.txt"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Release artifact is incomplete: $required_path is missing" >&2
        exit 65
    fi
done
"$REPO_DIR/scripts/verify-macos-support.sh" bundle "$APP_PATH"
grep -Fq "gpui 0.2.2" "$RUST_LICENSES"
grep -Fq "gpui-component 0.5.1" "$RUST_LICENSES"
grep -Fq "ONNX Runtime 1.24.2" "$NOTICES"
grep -Fq "Parakeet TDT 0.6B V3 ONNX model" "$NOTICES"
grep -Fq "Whisper Large V3 Turbo ONNX model" "$NOTICES"
grep -Fq "MIT License" "$ORT_LICENSE"
(
    cd "$SUPPLY_CHAIN"
    shasum -a 256 -c SHA256SUMS
)
jq -e '
    .specVersion == "1.5" and
    .serialNumber == null and
    any(.components[]; .name == "WrenflowShell") and
    any(.components[]; .name == "onnxruntime" and .version == "1.24.2") and
    any(.components[]; .name == "gpui" and .version == "0.2.2") and
    any(.components[]; .name == "gpui-component" and .version == "0.5.1")
' "$SBOM" >/dev/null
jq -e '.onnx_runtime.version == "1.24.2" and (.models | length == 2)' "$PINS" >/dev/null
jq -e '.predicateType == "https://slsa.dev/provenance/v1"' "$PROVENANCE" >/dev/null
if grep -Fq "$(cd "$(dirname "$APP_PATH")" && pwd)" "$SBOM"; then
    echo "SBOM leaks a local build path" >&2
    exit 65
fi

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

ENTITLEMENTS_PLIST="$(mktemp /tmp/wrenflow-entitlements.XXXXXX.plist)"
trap 'rm -f "$ENTITLEMENTS_PLIST"' EXIT
codesign --display --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_PLIST" 2>/dev/null
if ! plutil -convert json -o - "$ENTITLEMENTS_PLIST" | jq -e '
    type == "object" and
    length == 2 and
    .["com.apple.security.device.audio-input"] == true and
    .["com.apple.security.network.client"] == true
' >/dev/null; then
    echo "The release app has unexpected or missing entitlements" >&2
    exit 69
fi

verify_signer "$SHELL_DYLIB" "libWrenflowShell"
verify_signer "$ORT_DYLIB" "libonnxruntime"
verify_macho_loads "$BINARY" "@rpath/libWrenflowShell.dylib"
verify_macho_loads "$SHELL_DYLIB" "@rpath/libWrenflowShell.dylib"
verify_macho_loads "$ORT_DYLIB" "@rpath/libonnxruntime.1.24.2.dylib"
verify_rpaths "$BINARY" "@executable_path/../Frameworks"
verify_rpaths "$SHELL_DYLIB" "/usr/lib/swift"
verify_rpaths "$ORT_DYLIB" "@loader_path"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$SHELL_DYLIB"
codesign --verify --strict --verbose=2 "$ORT_DYLIB"
codesign --verify --strict --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [[ "$NOTARIZATION_MODE" == "--require-notarized" ]]; then
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

shasum -a 256 "$DMG_PATH"
echo "Verified release artifact for $IDENTIFIER ($TEAM_ID)"

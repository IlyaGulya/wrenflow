#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${WRENFLOW_TEST_APP:-$REPO_DIR/build/gpui/Wrenflow.app}"
BUNDLE_ID="me.gulya.wrenflow"

usage() {
    echo "Usage: $0 check-bundle|check-notarized|launch-lifecycle|tcc-status|reset-tcc" >&2
}

require_app() {
    if [[ ! -d "$APP_PATH" ]]; then
        echo "Wrenflow app not found at $APP_PATH; run 'mise run build' first" >&2
        exit 65
    fi
}

case "${1:-}" in
    check-bundle)
        require_app
        NOTICES="$APP_PATH/Contents/Resources/ThirdPartyNotices.txt"
        RUST_LICENSES="$APP_PATH/Contents/Resources/RustThirdPartyLicenses.txt"
        ORT_LICENSE="$APP_PATH/Contents/Resources/ThirdPartyLicenses/ONNX-Runtime-LICENSE.txt"
        ORT_NOTICES="$APP_PATH/Contents/Resources/ThirdPartyLicenses/ONNX-Runtime-ThirdPartyNotices.txt"
        SUPPLY_CHAIN="$APP_PATH/Contents/Resources/SupplyChain"
        for notice_path in "$NOTICES" "$RUST_LICENSES" "$ORT_LICENSE" "$ORT_NOTICES" \
            "$SUPPLY_CHAIN/Wrenflow.cdx.json" "$SUPPLY_CHAIN/pins.json" \
            "$SUPPLY_CHAIN/exceptions.json" "$SUPPLY_CHAIN/provenance.json" \
            "$SUPPLY_CHAIN/SHA256SUMS"; do
            if [[ ! -s "$notice_path" ]]; then
                echo "Bundled third-party notice is missing or empty: $notice_path" >&2
                exit 68
            fi
        done
        grep -Fq "gpui 0.2.2" "$RUST_LICENSES"
        grep -Fq "gpui-component 0.5.1" "$RUST_LICENSES"
        grep -Fq "ONNX Runtime 1.24.2" "$NOTICES"
        grep -Fq "Parakeet TDT 0.6B V3 ONNX model" "$NOTICES"
        grep -Fq "Whisper Large V3 Turbo ONNX model" "$NOTICES"
        (
            cd "$SUPPLY_CHAIN"
            shasum -a 256 -c SHA256SUMS
        )
        jq -e '.specVersion == "1.5" and .serialNumber == null' \
            "$SUPPLY_CHAIN/Wrenflow.cdx.json" >/dev/null
        codesign --verify --deep --strict --verbose=2 "$APP_PATH"
        plutil -p "$APP_PATH/Contents/Info.plist"
        codesign --display --verbose=4 "$APP_PATH" 2>&1 |
            grep -E '^(Identifier|TeamIdentifier|Runtime Version)=|CodeDirectory .*flags=.*runtime'
        ;;
    check-notarized)
        require_app
        DMG_PATH="${WRENFLOW_TEST_DMG:-$REPO_DIR/build/Wrenflow.dmg}"
        "$REPO_DIR/scripts/verify-release-artifact.sh" \
            "$APP_PATH" "$DMG_PATH" --require-notarized
        ;;
    launch-lifecycle)
        require_app
        APP_BINARY="$APP_PATH/Contents/MacOS/wrenflow"
        EXISTING_PIDS="$(pgrep -f "$APP_BINARY" || true)"
        open -n "$APP_PATH" --args --shell-self-test
        APP_PID=""
        for _ in $(seq 1 100); do
            for candidate in $(pgrep -f "$APP_BINARY" || true); do
                if ! grep -qx "$candidate" <<<"$EXISTING_PIDS"; then
                    APP_PID="$candidate"
                    break
                fi
            done
            [[ -n "$APP_PID" ]] && break
            sleep 0.1
        done
        if [[ -z "$APP_PID" ]]; then
            echo "LaunchServices did not start the exact app binary: $APP_BINARY" >&2
            exit 66
        fi
        ps -p "$APP_PID" -o pid=,command=
        APP_INFO=""
        for _ in $(seq 1 50); do
            APP_INFO="$(lsappinfo info -only bundlepath,pid,ApplicationType -app "$APP_PID")"
            [[ "$APP_INFO" == *'"ApplicationType"="Foreground"'* ]] && break
            sleep 0.1
        done
        echo "$APP_INFO"
        if [[ "$APP_INFO" != *'"ApplicationType"="Foreground"'* ]]; then
            echo "The self-test app did not switch to foreground window policy" >&2
            exit 67
        fi
        xcrun swift "$REPO_DIR/scripts/window-evidence.swift" "$APP_PID"
        echo "Re-run 'open $APP_PATH' to verify single-process reopen; inspect the visible window manually."
        ;;
    tcc-status)
        USER_TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
        sqlite3 "$USER_TCC_DB" \
            "select service,client,auth_value,last_modified from access where client='$BUNDLE_ID';"
        echo "Accessibility consent is stored in the system TCC database; inspect it only on the disposable test account documented in docs/macos-hardening-matrix.md."
        ;;
    reset-tcc)
        if [[ "${WRENFLOW_CONFIRM_TCC_RESET:-}" != "$BUNDLE_ID" ]]; then
            echo "Refusing to erase consent. On a disposable account, set WRENFLOW_CONFIRM_TCC_RESET=$BUNDLE_ID." >&2
            exit 67
        fi
        tccutil reset Microphone "$BUNDLE_ID"
        tccutil reset Accessibility "$BUNDLE_ID"
        echo "Reset microphone and Accessibility consent for $BUNDLE_ID"
        ;;
    *)
        usage
        exit 64
        ;;
esac

#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="me.gulya.wrenflow"
TEAM_ID="T4LV8K9BGV"
CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$CRATE_DIR/scripts/verified-app-process.sh"
TARGET_APP=""
PURGE_CURRENT_DATA=0
REMOVE_LEGACY_DATA=0
DRY_RUN=0

usage() {
    echo "Usage: $0 [--target /Applications/Wrenflow.app|\$HOME/Applications/Wrenflow.app] [--purge-current-data] [--remove-legacy-data] [--dry-run]" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            TARGET_APP="$2"
            shift 2
            ;;
        --purge-current-data)
            PURGE_CURRENT_DATA=1
            shift
            ;;
        --remove-legacy-data)
            REMOVE_LEGACY_DATA=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

if [[ -z "$TARGET_APP" ]]; then
    for candidate in "/Applications/Wrenflow.app" "$HOME/Applications/Wrenflow.app"; do
        if [[ -d "$candidate" ]]; then
            TARGET_APP="$candidate"
            break
        fi
    done
fi
TARGET_APP="${TARGET_APP:-/Applications/Wrenflow.app}"
case "$TARGET_APP" in
    "/Applications/Wrenflow.app" | "$HOME/Applications/Wrenflow.app") ;;
    *)
        echo "Refusing unexpected application target: $TARGET_APP" >&2
        exit 65
        ;;
esac
if [[ -L "$TARGET_APP" ]]; then
    echo "Refusing symlink application target: $TARGET_APP" >&2
    exit 65
fi
if (( DRY_RUN )); then
    printf 'validated_uninstall_target=%s\npurge_current_data=%s\nremove_legacy_data=%s\n' \
        "$TARGET_APP" "$PURGE_CURRENT_DATA" "$REMOVE_LEGACY_DATA"
    exit 0
fi
if [[ ! -d "$TARGET_APP" ]]; then
    echo "Wrenflow is not installed at $TARGET_APP" >&2
    exit 66
fi
if [[ "$(plutil -extract CFBundleIdentifier raw "$TARGET_APP/Contents/Info.plist")" != "$BUNDLE_ID" ]]; then
    echo "Refusing to remove a bundle that is not $BUNDLE_ID" >&2
    exit 67
fi
codesign --verify --deep --strict "$TARGET_APP"
wrenflow_validate_bundle_identity "$TARGET_APP" || exit 67
wrenflow_request_typed_quit "$TARGET_APP" 100 || exit 68

EVIDENCE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-uninstall.XXXXXX")"
trap 'rm -rf "$EVIDENCE_ROOT"' EXIT
EVIDENCE_PATH="$EVIDENCE_ROOT/wrenflow-uninstall-evidence.json"
open -n -W "$TARGET_APP" --args --prepare-uninstall-evidence "$EVIDENCE_PATH"
if [[ ! -s "$EVIDENCE_PATH" ]]; then
    echo "The signed app did not produce login-item unregister evidence" >&2
    exit 69
fi
if [[ "$(plutil -extract success raw "$EVIDENCE_PATH")" != "true" ]]; then
    cat "$EVIDENCE_PATH" >&2
    echo "SMAppService unregister did not leave a clean state" >&2
    exit 69
fi
if [[ "$(plutil -extract bundleIdentifier raw "$EVIDENCE_PATH")" != "$BUNDLE_ID" ]] ||
   [[ "$(plutil -extract bundlePath raw "$EVIDENCE_PATH")" != "$TARGET_APP" ]]; then
    cat "$EVIDENCE_PATH" >&2
    echo "Uninstall evidence came from an unexpected application identity" >&2
    exit 69
fi
cat "$EVIDENCE_PATH"

/usr/bin/trash "$TARGET_APP"

trash_allowed_path() {
    local path="$1"
    case "$path" in
        "$HOME/Library/Application Support/me.gulya.wrenflow/gpui-v1"|"$HOME/Library/Caches/me.gulya.wrenflow/gpui-v1"|"$HOME/Library/Logs/me.gulya.wrenflow/gpui-v1"|"$HOME/Library/Application Support/Wrenflow"|"$HOME/Library/Application Support/wrenflow"|"$HOME/Library/Preferences/me.gulya.wrenflow.plist"|"$HOME/Library/Saved Application State/me.gulya.wrenflow.savedState"|"$HOME/Library/Caches/me.gulya.wrenflow") ;;
        *)
            echo "Refusing unexpected data path: $path" >&2
            exit 70
            ;;
    esac
    [[ ! -e "$path" && ! -L "$path" ]] || /usr/bin/trash "$path"
}

if (( PURGE_CURRENT_DATA )); then
    trash_allowed_path "$HOME/Library/Application Support/me.gulya.wrenflow/gpui-v1"
    trash_allowed_path "$HOME/Library/Caches/me.gulya.wrenflow/gpui-v1"
    trash_allowed_path "$HOME/Library/Logs/me.gulya.wrenflow/gpui-v1"
fi
if (( REMOVE_LEGACY_DATA )); then
    trash_allowed_path "$HOME/Library/Application Support/Wrenflow"
    trash_allowed_path "$HOME/Library/Application Support/wrenflow"
    trash_allowed_path "$HOME/Library/Preferences/me.gulya.wrenflow.plist"
    trash_allowed_path "$HOME/Library/Saved Application State/me.gulya.wrenflow.savedState"
    trash_allowed_path "$HOME/Library/Caches/me.gulya.wrenflow"
fi

rm -rf "$EVIDENCE_ROOT"
trap - EXIT
printf 'uninstalled_bundle=%s\ncurrent_data_purged=%s\nlegacy_data_removed=%s\n' \
    "$TARGET_APP" "$PURGE_CURRENT_DATA" "$REMOVE_LEGACY_DATA"

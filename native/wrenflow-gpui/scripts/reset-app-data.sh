#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$CRATE_DIR/scripts/verified-app-process.sh"
PURGE_CURRENT_DATA=0
REMOVE_LEGACY_DATA=0
RELAUNCH=0
TARGET_APP=""

usage() {
    echo "Usage: $0 --current-data|--legacy-data|--all [--target /Applications/Wrenflow.app|\$HOME/Applications/Wrenflow.app] [--relaunch]" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --current-data) PURGE_CURRENT_DATA=1 ;;
        --legacy-data) REMOVE_LEGACY_DATA=1 ;;
        --all) PURGE_CURRENT_DATA=1; REMOVE_LEGACY_DATA=1 ;;
        --target)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            TARGET_APP="$2"
            shift
            ;;
        --relaunch) RELAUNCH=1 ;;
        *) usage; exit 64 ;;
    esac
    shift
done
if (( ! PURGE_CURRENT_DATA && ! REMOVE_LEGACY_DATA )); then
    usage
    exit 64
fi

if [[ -z "$TARGET_APP" ]]; then
    for candidate in "/Applications/Wrenflow.app" "$HOME/Applications/Wrenflow.app"; do
        if [[ -d "$candidate" ]]; then
            [[ -z "$TARGET_APP" ]] || {
                echo "Multiple installed copies exist; pass --target explicitly" >&2
                exit 65
            }
            TARGET_APP="$candidate"
        fi
    done
fi
if [[ -n "$TARGET_APP" ]]; then
    case "$TARGET_APP" in
        "/Applications/Wrenflow.app" | "$HOME/Applications/Wrenflow.app") ;;
        *) echo "Refusing unexpected reset application target: $TARGET_APP" >&2; exit 65 ;;
    esac
    wrenflow_request_typed_quit "$TARGET_APP" 100 || exit 65
elif [[ -n "$(wrenflow_candidate_pids)" ]]; then
    echo "A Wrenflow-named process exists but no exact installed bundle can be verified" >&2
    exit 65
fi

trash_allowed_path() {
    local path="$1"
    case "$path" in
        "$HOME/Library/Application Support/me.gulya.wrenflow/gpui-v1"|"$HOME/Library/Caches/me.gulya.wrenflow/gpui-v1"|"$HOME/Library/Logs/me.gulya.wrenflow/gpui-v1"|"$HOME/Library/Application Support/Wrenflow"|"$HOME/Library/Application Support/wrenflow"|"$HOME/Library/Preferences/me.gulya.wrenflow.plist"|"$HOME/Library/Saved Application State/me.gulya.wrenflow.savedState"|"$HOME/Library/Caches/me.gulya.wrenflow") ;;
        *) echo "Refusing unexpected reset path: $path" >&2; exit 66 ;;
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

if (( RELAUNCH )); then
    [[ -n "$TARGET_APP" ]] || { echo "No exact installed app is available to relaunch" >&2; exit 67; }
    open "$TARGET_APP"
fi
printf 'current_data_purged=%s\nlegacy_data_removed=%s\n' "$PURGE_CURRENT_DATA" "$REMOVE_LEGACY_DATA"

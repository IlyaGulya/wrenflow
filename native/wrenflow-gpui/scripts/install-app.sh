#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
SOURCE_APP="$REPO_DIR/build/gpui/Wrenflow.app"
BUNDLE_ID="me.gulya.wrenflow"
TEAM_ID="T4LV8K9BGV"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
source "$CRATE_DIR/scripts/verified-app-process.sh"
TARGET_APP=""
LAUNCH_AFTER_INSTALL=1
DRY_RUN=0

usage() {
    echo "Usage: $0 [--target /Applications/Wrenflow.app|\$HOME/Applications/Wrenflow.app] [--no-launch] [--dry-run]" >&2
}

while (( $# > 0 )); do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            TARGET_APP="$2"
            shift 2
            ;;
        --no-launch)
            LAUNCH_AFTER_INSTALL=0
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
    printf 'validated_install_target=%s\n' "$TARGET_APP"
    exit 0
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Production app not found at $SOURCE_APP; run 'mise run release' first" >&2
    exit 66
fi
if [[ -L "$SOURCE_APP" ]]; then
    echo "Refusing symlink source bundle: $SOURCE_APP" >&2
    exit 66
fi

SOURCE_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$SOURCE_APP/Contents/Info.plist")"
if [[ "$SOURCE_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing source bundle identifier '$SOURCE_BUNDLE_ID'" >&2
    exit 67
fi
SIGNING_INFO="$(codesign --display --verbose=4 "$SOURCE_APP" 2>&1)"
if ! grep -Fq "Identifier=$BUNDLE_ID" <<<"$SIGNING_INFO" ||
   ! grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$SIGNING_INFO"; then
    echo "Refusing bundle without production identifier and Team ID" >&2
    exit 67
fi
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"

if [[ -d "$TARGET_APP" ]]; then
    wrenflow_validate_bundle_identity "$TARGET_APP" || exit 68
    wrenflow_request_typed_quit "$TARGET_APP" 100 || exit 68
else
    # A same-ID process from any other copy makes the intended replacement
    # ambiguous. Never signal it and never install over that live identity.
    wrenflow_require_no_same_id_process || exit 68
fi

INSTALL_ROOT="$(dirname "$TARGET_APP")"
mkdir -p "$INSTALL_ROOT"
STAGING_ROOT="$(mktemp -d "$INSTALL_ROOT/.Wrenflow-install.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/Wrenflow.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$TARGET_APP" ]]; then
    "$LSREGISTER" -u "$TARGET_APP" || true
    mise exec -- xcrun swift "$CRATE_DIR/scripts/install-bundle-swap.swift" "$STAGED_APP" "$TARGET_APP"
    # renameatx_np exchanged the valid new app with the previous bundle. The
    # previous bundle is now recoverable from Trash if the host supports it.
    "$LSREGISTER" -u "$STAGED_APP" || true
    /usr/bin/trash "$STAGED_APP"
else
    mv "$STAGED_APP" "$TARGET_APP"
fi
rm -rf "$STAGING_ROOT"
trap - EXIT

codesign --verify --deep --strict "$TARGET_APP"
INSTALLED_SIGNING_INFO="$(codesign --display --verbose=4 "$TARGET_APP" 2>&1)"
if ! grep -Fq "Identifier=$BUNDLE_ID" <<<"$INSTALLED_SIGNING_INFO" ||
   ! grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$INSTALLED_SIGNING_INFO"; then
    echo "Installed bundle identity changed during replacement" >&2
    exit 69
fi
"$LSREGISTER" -f "$TARGET_APP"

APP_PID=""
if (( LAUNCH_AFTER_INSTALL )); then
    open "$TARGET_APP"
    for _ in $(seq 1 100); do
        APP_PID="$(wrenflow_verified_pids "$TARGET_APP" | head -1 || true)"
        [[ -n "$APP_PID" ]] && break
        sleep 0.1
    done
    if [[ -z "$APP_PID" ]]; then
        echo "LaunchServices did not start the installed app" >&2
        exit 70
    fi
fi

printf 'installed_bundle=%s\nbundle_id=%s\nteam_id=%s\npid=%s\n' \
    "$TARGET_APP" "$BUNDLE_ID" "$TEAM_ID" "${APP_PID:-not-launched}"

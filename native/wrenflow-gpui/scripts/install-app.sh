#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
SOURCE_APP="$REPO_DIR/build/gpui/Wrenflow.app"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Production app not found at $SOURCE_APP; run 'mise run release' first" >&2
    exit 1
fi

TARGET_APP=""
for candidate in "/Applications/Wrenflow.app" "$HOME/Applications/Wrenflow.app"; do
    if [[ -d "$candidate" ]]; then
        TARGET_APP="$candidate"
        break
    fi
done
if [[ -z "$TARGET_APP" ]]; then
    TARGET_APP="/Applications/Wrenflow.app"
fi

case "$TARGET_APP" in
    "/Applications/Wrenflow.app" | "$HOME/Applications/Wrenflow.app") ;;
    *)
        echo "Refusing to replace unexpected application path: $TARGET_APP" >&2
        exit 1
        ;;
esac
TARGET_PROCESS_PATTERN="^$(dirname "$TARGET_APP")/[Ww]renflow\\.app/Contents/MacOS/wrenflow( |$)"

osascript -e 'tell application id "me.gulya.wrenflow" to quit' >/dev/null 2>&1 || true

for _ in $(seq 1 50); do
    if ! pgrep -f "$TARGET_PROCESS_PATTERN" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if pgrep -f "$TARGET_PROCESS_PATTERN" >/dev/null 2>&1; then
    echo "Installed Wrenflow did not quit; refusing to replace a running bundle" >&2
    exit 1
fi

INSTALL_ROOT="$(dirname "$TARGET_APP")"
STAGING_ROOT="$(mktemp -d "$INSTALL_ROOT/.Wrenflow-install.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/Wrenflow.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

trash "$TARGET_APP" 2>/dev/null || true
mv "$STAGED_APP" "$TARGET_APP"
rm -rf "$STAGING_ROOT"
trap - EXIT

open "$TARGET_APP"
echo "$TARGET_APP"

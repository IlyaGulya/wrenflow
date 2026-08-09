#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.3.0"
ARCHIVE_URL="https://github.com/create-dmg/create-dmg/archive/refs/tags/v${VERSION}.tar.gz"
ARCHIVE_SHA256="c50d2bc97c3d6292642bac55f530d247eaf4bf65ee605f26b4caf339383e381c"
SCRIPT_SHA256="bb9ea3194e55f2f76a821e87541513748d0fedc69f45cf4f0951cad15ae0cae5"
TOOLS_DIR="$REPO_DIR/build/tools"
TOOL_DIR="$TOOLS_DIR/create-dmg-${VERSION}"

if "$REPO_DIR/scripts/verify-sha256.sh" "$TOOL_DIR/create-dmg" "$SCRIPT_SHA256" "create-dmg" >/dev/null 2>&1; then
    echo "$TOOL_DIR/create-dmg"
    exit 0
fi
if [[ -e "$TOOL_DIR" ]]; then
    echo "Refusing to replace an unverified release tool directory: $TOOL_DIR" >&2
    echo "Run 'mise run clean' and retry." >&2
    exit 66
fi

mkdir -p "$TOOLS_DIR"
STAGING="$(mktemp -d "$TOOLS_DIR/.create-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    "$ARCHIVE_URL" -o "$STAGING/create-dmg.tar.gz"
"$REPO_DIR/scripts/verify-sha256.sh" "$STAGING/create-dmg.tar.gz" "$ARCHIVE_SHA256" "create-dmg archive"
tar xzf "$STAGING/create-dmg.tar.gz" -C "$STAGING"
"$REPO_DIR/scripts/verify-sha256.sh" "$STAGING/create-dmg-${VERSION}/create-dmg" "$SCRIPT_SHA256" "create-dmg script"
mv "$STAGING/create-dmg-${VERSION}" "$TOOL_DIR"
echo "$TOOL_DIR/create-dmg"

#!/usr/bin/env bash
# Generate Flutter macOS app icon set from Resources/AppIcon-Source.png
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SOURCE="$ROOT/Resources/AppIcon-Source.png"
DEST="$ROOT/flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SOURCE" ]; then
  echo "error: AppIcon-Source.png not found at $SOURCE"
  exit 1
fi

SIZES=(16 32 64 128 256 512 1024)

for size in "${SIZES[@]}"; do
  out="$DEST/app_icon_${size}.png"
  sips -z "$size" "$size" "$SOURCE" --out "$out" >/dev/null 2>&1
  echo "  ${size}x${size} → $(basename "$out")"
done

echo "Generated ${#SIZES[@]} icon sizes in $DEST"

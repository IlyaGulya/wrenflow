#!/usr/bin/env bash
# Generate Flutter macOS app icons + tray icons from source assets.
# Sources: Resources/AppIcon-Source.png, Resources/logo-bird.svg
# Requires: sips (macOS built-in), resvg (managed by mise)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

# ── App icon (from PNG source) ──────────────────────────────────

SOURCE="$ROOT/Resources/AppIcon-Source.png"
DEST="$ROOT/flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SOURCE" ]; then
  echo "error: AppIcon-Source.png not found at $SOURCE"
  exit 1
fi

for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$SOURCE" --out "$DEST/app_icon_${size}.png" >/dev/null 2>&1
done
echo "App icons generated"

# ── Tray icons (from SVG source) ────────────────────────────────
# macOS menu bar: 22pt square. Template image (black on transparent).
# logo-bird.svg has square viewBox — bird centered with padding.

LOGO_SVG="$ROOT/Resources/logo-bird.svg"
TRAY_DEST="$ROOT/flutter/assets/tray_icons"
mkdir -p "$TRAY_DEST"

resvg -w 22 -h 22 "$LOGO_SVG" "$TRAY_DEST/tray_idle.png"
resvg -w 44 -h 44 "$LOGO_SVG" "$TRAY_DEST/tray_idle@2x.png"

for state in recording transcribing; do
  cp "$TRAY_DEST/tray_idle.png" "$TRAY_DEST/tray_${state}.png"
  cp "$TRAY_DEST/tray_idle@2x.png" "$TRAY_DEST/tray_${state}@2x.png"
done
echo "Tray icons generated"

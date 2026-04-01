#!/usr/bin/env bash
# Generate Flutter macOS app icons + tray icons from source SVGs.
# Sources: Resources/AppIcon-Dock.svg, Resources/AppIcon-Source.svg,
#          Resources/logo-bird.svg, Resources/logo-bird-singing.svg
# Requires: resvg (managed by mise)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

# ── App icon (dock) ───────────────────────────────────────────
# Bird + equalizer only, compact, for dock/Finder.

DOCK_SVG="$ROOT/Resources/AppIcon-Dock.svg"
DEST="$ROOT/flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset"

for size in 16 32 64 128 256 512 1024; do
  resvg -w "$size" -h "$size" "$DOCK_SVG" "$DEST/app_icon_${size}.png"
done
echo "App icons generated"

# ── Settings icon (full logo with waves) ──────────────────────

FULL_SVG="$ROOT/Resources/AppIcon-Source.svg"
resvg -w 128 -h 128 "$FULL_SVG" "$ROOT/flutter/assets/icon.png"
echo "Settings icon generated"

# ── Tray icons (from SVG source) ──────────────────────────────
# macOS menu bar: 22pt square. Template image (black on transparent).

LOGO_SVG="$ROOT/Resources/logo-bird.svg"
SINGING_SVG="$ROOT/Resources/logo-bird-singing.svg"
TRAY_DEST="$ROOT/flutter/assets/tray_icons"
mkdir -p "$TRAY_DEST"

resvg -w 22 -h 22 "$LOGO_SVG" "$TRAY_DEST/tray_idle.png"
resvg -w 44 -h 44 "$LOGO_SVG" "$TRAY_DEST/tray_idle@2x.png"

# Recording: singing bird (identical to idle until designer provides variant)
resvg -w 22 -h 22 "$SINGING_SVG" "$TRAY_DEST/tray_recording.png"
resvg -w 44 -h 44 "$SINGING_SVG" "$TRAY_DEST/tray_recording@2x.png"

# Transcribing: same as idle for now
cp "$TRAY_DEST/tray_idle.png" "$TRAY_DEST/tray_transcribing.png"
cp "$TRAY_DEST/tray_idle@2x.png" "$TRAY_DEST/tray_transcribing@2x.png"

echo "Tray icons generated"

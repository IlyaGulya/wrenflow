#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SVG="$REPO_DIR/Resources/AppIcon-Dock.svg"
OUTPUT_ICNS="$REPO_DIR/Resources/AppIcon.icns"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-icon.XXXXXX")"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$ICONSET_DIR"
resvg -w 16 -h 16 "$SOURCE_SVG" "$ICONSET_DIR/icon_16x16.png"
resvg -w 32 -h 32 "$SOURCE_SVG" "$ICONSET_DIR/icon_16x16@2x.png"
resvg -w 32 -h 32 "$SOURCE_SVG" "$ICONSET_DIR/icon_32x32.png"
resvg -w 64 -h 64 "$SOURCE_SVG" "$ICONSET_DIR/icon_32x32@2x.png"
resvg -w 128 -h 128 "$SOURCE_SVG" "$ICONSET_DIR/icon_128x128.png"
resvg -w 256 -h 256 "$SOURCE_SVG" "$ICONSET_DIR/icon_128x128@2x.png"
resvg -w 256 -h 256 "$SOURCE_SVG" "$ICONSET_DIR/icon_256x256.png"
resvg -w 512 -h 512 "$SOURCE_SVG" "$ICONSET_DIR/icon_256x256@2x.png"
resvg -w 512 -h 512 "$SOURCE_SVG" "$ICONSET_DIR/icon_512x512.png"
resvg -w 1024 -h 1024 "$SOURCE_SVG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil --convert icns "$ICONSET_DIR" --output "$OUTPUT_ICNS"
echo "$OUTPUT_ICNS"

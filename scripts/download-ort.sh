#!/usr/bin/env bash
# Downloads ONNX Runtime dylib for macOS ARM64 if not already present.
set -euo pipefail

ORT_VERSION="1.24.2"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-osx-arm64-${ORT_VERSION}.tgz"
ORT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/vendor/onnxruntime}"
ORT_DYLIB="${ORT_DIR}/lib/libonnxruntime.dylib"
ORT_LICENSE="${ORT_DIR}/LICENSE"
ORT_NOTICES="${ORT_DIR}/ThirdPartyNotices.txt"

if [ -f "$ORT_DYLIB" ] && [ -f "$ORT_LICENSE" ] && [ -f "$ORT_NOTICES" ]; then
    echo "ort: dylib and notices exist in ${ORT_DIR}"
    exit 0
fi

SOURCE_FALLBACK="$(cd "$(dirname "$0")/.." && pwd)/vendor/onnxruntime-src"
if [ -f "$ORT_DYLIB" ] && [ -f "$SOURCE_FALLBACK/LICENSE" ] && [ -f "$SOURCE_FALLBACK/ThirdPartyNotices.txt" ]; then
    cp "$SOURCE_FALLBACK/LICENSE" "$ORT_LICENSE"
    cp "$SOURCE_FALLBACK/ThirdPartyNotices.txt" "$ORT_NOTICES"
    echo "ort: installed license notices from the local source mirror"
    exit 0
fi

echo "ort: downloading v${ORT_VERSION} for macOS ARM64..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fSL "$ORT_URL" -o "${TMP_DIR}/ort.tgz"
tar xzf "${TMP_DIR}/ort.tgz" -C "$TMP_DIR"

mkdir -p "$ORT_DIR/lib"
ARCHIVE_DIR="${TMP_DIR}/onnxruntime-osx-arm64-${ORT_VERSION}"
cp -a "${ARCHIVE_DIR}/lib/"libonnxruntime* "$ORT_DIR/lib/"
cp "${ARCHIVE_DIR}/LICENSE" "$ORT_LICENSE"
cp "${ARCHIVE_DIR}/ThirdPartyNotices.txt" "$ORT_NOTICES"

echo "ort: installed dylib and notices to ${ORT_DIR}"
ls -la "$ORT_DIR/lib/" "$ORT_LICENSE" "$ORT_NOTICES"

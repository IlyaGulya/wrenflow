#!/usr/bin/env bash
# Downloads ONNX Runtime dylib for macOS ARM64 if not already present.
set -euo pipefail

ORT_VERSION="1.24.2"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-osx-arm64-${ORT_VERSION}.tgz"
ORT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/vendor/onnxruntime}"
ORT_DYLIB="${ORT_DIR}/lib/libonnxruntime.dylib"

if [ -f "$ORT_DYLIB" ]; then
    echo "ort: ${ORT_DYLIB} exists"
    exit 0
fi

echo "ort: downloading v${ORT_VERSION} for macOS ARM64..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fSL "$ORT_URL" -o "${TMP_DIR}/ort.tgz"
tar xzf "${TMP_DIR}/ort.tgz" -C "$TMP_DIR"

mkdir -p "$ORT_DIR/lib"
cp -a "${TMP_DIR}/onnxruntime-osx-arm64-${ORT_VERSION}/lib/"libonnxruntime* "$ORT_DIR/lib/"

echo "ort: installed to ${ORT_DIR}/lib/"
ls -la "$ORT_DIR/lib/"

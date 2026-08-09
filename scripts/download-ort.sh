#!/usr/bin/env bash
# Downloads ONNX Runtime dylib for macOS ARM64 if not already present.
set -euo pipefail

ORT_VERSION="1.24.2"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-osx-arm64-${ORT_VERSION}.tgz"
ORT_ARCHIVE_SHA256="0af4fa503e8ea285245b47ee42d0a7461b8156a81270857da0c1d4ecf858abde"
ORT_DYLIB_SHA256="87df6f94dd559ea958748adc80fd4c46d91c52bc025771f513291d155539590a"
ORT_LICENSE_SHA256="2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c"
ORT_NOTICES_SHA256="0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_SHA256="$REPO_DIR/scripts/verify-sha256.sh"
ORT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/vendor/onnxruntime}"
ORT_DYLIB="${ORT_DIR}/lib/libonnxruntime.dylib"
ORT_LICENSE="${ORT_DIR}/LICENSE"
ORT_NOTICES="${ORT_DIR}/ThirdPartyNotices.txt"

if "$VERIFY_SHA256" "$ORT_DYLIB" "$ORT_DYLIB_SHA256" "ONNX Runtime dylib" >/dev/null 2>&1 \
    && "$VERIFY_SHA256" "$ORT_LICENSE" "$ORT_LICENSE_SHA256" "ONNX Runtime license" >/dev/null 2>&1 \
    && "$VERIFY_SHA256" "$ORT_NOTICES" "$ORT_NOTICES_SHA256" "ONNX Runtime notices" >/dev/null 2>&1; then
    echo "ort: verified pinned v${ORT_VERSION} dylib and notices in ${ORT_DIR}"
    exit 0
fi

echo "ort: downloading v${ORT_VERSION} for macOS ARM64..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    "$ORT_URL" -o "${TMP_DIR}/ort.tgz"
"$VERIFY_SHA256" "${TMP_DIR}/ort.tgz" "$ORT_ARCHIVE_SHA256" "ONNX Runtime archive"
tar xzf "${TMP_DIR}/ort.tgz" -C "$TMP_DIR"

mkdir -p "$ORT_DIR/lib"
ARCHIVE_DIR="${TMP_DIR}/onnxruntime-osx-arm64-${ORT_VERSION}"
ARCHIVE_DYLIB="${ARCHIVE_DIR}/lib/libonnxruntime.${ORT_VERSION}.dylib"
"$VERIFY_SHA256" "$ARCHIVE_DYLIB" "$ORT_DYLIB_SHA256" "extracted ONNX Runtime dylib"
"$VERIFY_SHA256" "${ARCHIVE_DIR}/LICENSE" "$ORT_LICENSE_SHA256" "extracted ONNX Runtime license"
"$VERIFY_SHA256" "${ARCHIVE_DIR}/ThirdPartyNotices.txt" "$ORT_NOTICES_SHA256" "extracted ONNX Runtime notices"
cp "$ARCHIVE_DYLIB" "$ORT_DYLIB"
cp "${ARCHIVE_DIR}/LICENSE" "$ORT_LICENSE"
cp "${ARCHIVE_DIR}/ThirdPartyNotices.txt" "$ORT_NOTICES"

"$VERIFY_SHA256" "$ORT_DYLIB" "$ORT_DYLIB_SHA256" "installed ONNX Runtime dylib"
"$VERIFY_SHA256" "$ORT_LICENSE" "$ORT_LICENSE_SHA256" "installed ONNX Runtime license"
"$VERIFY_SHA256" "$ORT_NOTICES" "$ORT_NOTICES_SHA256" "installed ONNX Runtime notices"

echo "ort: installed dylib and notices to ${ORT_DIR}"
ls -la "$ORT_DIR/lib/" "$ORT_LICENSE" "$ORT_NOTICES"

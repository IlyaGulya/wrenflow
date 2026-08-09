#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_DIR/build/supply-chain}"
APP_MANIFEST="$REPO_DIR/native/wrenflow-gpui/Cargo.toml"
SBOM_STAGING="$REPO_DIR/native/wrenflow-gpui/wrenflow-release.json"
LOCK_DIR="$REPO_DIR/build/.supply-chain-generation.lock"

mkdir -p "$REPO_DIR/build"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another supply-chain metadata generation is active; retry after it completes." >&2
    exit 73
fi
trap 'rmdir "$LOCK_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_DIR" show -s --format=%ct HEAD)}"
export SOURCE_DATE_EPOCH
APP_VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$APP_MANIFEST" | head -1)"
if [[ -z "$APP_VERSION" ]]; then
    APP_VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$REPO_DIR/Cargo.toml" | head -1)"
fi
SWIFT_SOURCE_SHA="$(shasum -a 256 "$REPO_DIR/native/wrenflow-gpui/macos/WrenflowShell.swift" | awk '{print $1}')"
ORT_VERSION="$(jq -r '.onnx_runtime.version' "$REPO_DIR/supply-chain/pins.json")"
ORT_URL="$(jq -r '.onnx_runtime.url' "$REPO_DIR/supply-chain/pins.json")"
ORT_DYLIB_SHA="$(jq -r '.onnx_runtime.dylib_sha256' "$REPO_DIR/supply-chain/pins.json")"

cargo-cyclonedx cyclonedx \
    --manifest-path "$APP_MANIFEST" \
    --format json \
    --spec-version 1.5 \
    --target aarch64-apple-darwin \
    --override-filename wrenflow-release
if [[ ! -f "$SBOM_STAGING" ]]; then
    echo "cargo-cyclonedx did not produce $SBOM_STAGING" >&2
    exit 65
fi
mv "$SBOM_STAGING" "$OUTPUT_DIR/Wrenflow.cdx.json"
jq -S \
    --arg repo "$REPO_DIR" \
    --arg app_version "$APP_VERSION" \
    --arg swift_source_sha "$SWIFT_SOURCE_SHA" \
    --arg ort_version "$ORT_VERSION" \
    --arg ort_url "$ORT_URL" \
    --arg ort_dylib_sha "$ORT_DYLIB_SHA" \
    '
      walk(if type == "string" then (split($repo) | join(".")) else . end) |
      .metadata.component["bom-ref"] as $root |
      .components += [
        {
          "bom-ref": ("wrenflow:swift-shell@" + $app_version),
          type: "library",
          name: "WrenflowShell",
          version: $app_version,
          scope: "required",
          licenses: [{expression: "MIT"}],
          properties: [
            {name: "wrenflow:source-file", value: "native/wrenflow-gpui/macos/WrenflowShell.swift"},
            {name: "wrenflow:source-sha256", value: $swift_source_sha},
            {name: "wrenflow:release-artifact-digest", value: "artifact-provenance.json"}
          ]
        },
        {
          "bom-ref": ("pkg:generic/onnxruntime@" + $ort_version),
          type: "library",
          name: "onnxruntime",
          version: $ort_version,
          scope: "required",
          purl: ("pkg:generic/onnxruntime@" + $ort_version),
          hashes: [{alg: "SHA-256", content: $ort_dylib_sha}],
          licenses: [{expression: "MIT"}],
          externalReferences: [{type: "distribution", url: $ort_url}],
          properties: [{name: "wrenflow:bundled-path", value: "Wrenflow.app/Contents/MacOS/libonnxruntime.dylib"}]
        }
      ] |
      (.dependencies[] | select(.ref == $root) | .dependsOn) += [
        ("wrenflow:swift-shell@" + $app_version),
        ("pkg:generic/onnxruntime@" + $ort_version)
      ] |
      .dependencies += [
        {ref: ("wrenflow:swift-shell@" + $app_version), dependsOn: []},
        {ref: ("pkg:generic/onnxruntime@" + $ort_version), dependsOn: []}
      ] |
      .components |= sort_by(."bom-ref") |
      .dependencies |= sort_by(.ref)
    ' \
    "$OUTPUT_DIR/Wrenflow.cdx.json" >"$OUTPUT_DIR/Wrenflow.cdx.json.sanitized"
mv "$OUTPUT_DIR/Wrenflow.cdx.json.sanitized" "$OUTPUT_DIR/Wrenflow.cdx.json"

cargo-about generate \
    --config "$REPO_DIR/about.toml" \
    --manifest-path "$APP_MANIFEST" \
    --workspace \
    --locked \
    --offline \
    --fail \
    --output-file "$OUTPUT_DIR/RustThirdPartyLicenses.txt" \
    "$REPO_DIR/supply-chain/licenses.hbs"

cp "$REPO_DIR/supply-chain/pins.json" "$OUTPUT_DIR/pins.json"
cp "$REPO_DIR/supply-chain/exceptions.json" "$OUTPUT_DIR/exceptions.json"

COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
LOCK_SHA="$(shasum -a 256 "$REPO_DIR/Cargo.lock" | awk '{print $1}')"
APP_LOCK_SHA="$(shasum -a 256 "$REPO_DIR/native/wrenflow-gpui/Cargo.lock" | awk '{print $1}')"
PINS_SHA="$(shasum -a 256 "$REPO_DIR/supply-chain/pins.json" | awk '{print $1}')"
jq -S -n \
    --arg commit "$COMMIT" \
    --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
    --arg lock_sha256 "$LOCK_SHA" \
    --arg app_lock_sha256 "$APP_LOCK_SHA" \
    --arg pins_sha256 "$PINS_SHA" \
    '{
      predicateType: "https://slsa.dev/provenance/v1",
      buildDefinition: {
        buildType: "https://github.com/ilyagulya/wrenflow/build-types/macos-gpui-v1",
        externalParameters: {target: "aarch64-apple-darwin", locked: true},
        internalParameters: {sourceDateEpoch: $source_date_epoch},
        resolvedDependencies: [
          {uri: "git+https://github.com/ilyagulya/wrenflow", digest: {gitCommit: $commit}},
          {uri: "file:Cargo.lock", digest: {sha256: $lock_sha256}},
          {uri: "file:native/wrenflow-gpui/Cargo.lock", digest: {sha256: $app_lock_sha256}},
          {uri: "file:supply-chain/pins.json", digest: {sha256: $pins_sha256}}
        ]
      },
      runDetails: {
        builder: {id: "mise://wrenflow/release"},
        metadata: {invocationId: $commit}
      }
    }' >"$OUTPUT_DIR/provenance.json"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 Wrenflow.cdx.json RustThirdPartyLicenses.txt pins.json exceptions.json provenance.json >SHA256SUMS
)

echo "$OUTPUT_DIR"

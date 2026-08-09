#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
METADATA_DIR="$REPO_DIR/build/supply-chain"

GLOBAL_TOOLS="$(sed -n '/^\[tools\]$/,/^\[/p' "$REPO_DIR/mise.toml")"
for pinned_tool in \
    '"cargo:cargo-about" = "0.9.1"' \
    '"cargo:cargo-cyclonedx" = "0.5.9"' \
    '"cargo:cargo-deny" = "0.20.2"'; do
    grep -Fq "$pinned_tool" <<<"$GLOBAL_TOOLS" || {
        echo "Supply-chain CLI must be globally pinned before the parallel test DAG: $pinned_tool" >&2
        exit 1
    }
done

for required in \
    "$REPO_DIR/supply-chain/pins.json" \
    "$REPO_DIR/supply-chain/exceptions.json" \
    "$METADATA_DIR/Wrenflow.cdx.json" \
    "$METADATA_DIR/RustThirdPartyLicenses.txt" \
    "$METADATA_DIR/SHA256SUMS"; do
    [[ -s "$required" ]] || { echo "Missing supply-chain evidence: $required" >&2; exit 1; }
done

FIXTURES="$(mktemp -d /tmp/wrenflow-supply-chain.XXXXXX)"
trap 'rm -rf "$FIXTURES"' EXIT
printf 'trusted bytes' >"$FIXTURES/trusted"
TRUSTED_SHA="$(shasum -a 256 "$FIXTURES/trusted" | awk '{print $1}')"
"$REPO_DIR/scripts/verify-sha256.sh" "$FIXTURES/trusted" "$TRUSTED_SHA" "test fixture" >/dev/null
if "$REPO_DIR/scripts/verify-sha256.sh" "$FIXTURES/trusted" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    "tampered fixture" >/dev/null 2>&1; then
    echo "Checksum verifier accepted tampered content" >&2
    exit 1
fi

"$REPO_DIR/scripts/download-ort.sh" "$REPO_DIR/vendor/onnxruntime" >/dev/null
cp "$REPO_DIR/vendor/onnxruntime/lib/libonnxruntime.dylib" "$FIXTURES/libonnxruntime.dylib"
ORT_SHA="$(jq -r '.onnx_runtime.dylib_sha256' "$REPO_DIR/supply-chain/pins.json")"
"$REPO_DIR/scripts/verify-sha256.sh" "$FIXTURES/libonnxruntime.dylib" \
    "$ORT_SHA" "pinned ORT fixture" >/dev/null
printf 'tamper' >>"$FIXTURES/libonnxruntime.dylib"
if "$REPO_DIR/scripts/verify-sha256.sh" "$FIXTURES/libonnxruntime.dylib" \
    "$ORT_SHA" "tampered ORT fixture" >/dev/null 2>&1; then
    echo "Checksum verifier accepted a tampered ONNX Runtime dylib" >&2
    exit 1
fi
(
    cd "$METADATA_DIR"
    shasum -a 256 -c SHA256SUMS >/dev/null
)

jq -e '
  .onnx_runtime.version == "1.24.2" and
  .onnx_runtime.archive_sha256 == "0af4fa503e8ea285245b47ee42d0a7461b8156a81270857da0c1d4ecf858abde" and
  (.critical_rust_dependencies == [
    {"name":"gpui","version":"0.2.2","checksum":"979b45cfa6ec723b6f42330915a1b3769b930d02b2d505f9697f8ca602bee707"},
    {"name":"gpui-component","version":"0.5.1","checksum":"d021d46b4088d3d93a57ccdf443da85695a77272108caca2f6fe5369f584966a"},
    {"name":"gpui-component-assets","version":"0.5.1","checksum":"afc6e4c6551a1a12d4e8b69c3e8eba3cef43331c8c87898a0d4d040c78c6865e"},
    {"name":"parakeet-rs","version":"0.3.4","checksum":"ac2c29bb70e3b63ddfa9af7cbb66f87a200550a5f6a5ac82fabf527b270c6615"}
  ]) and
  (.models | length == 2) and
  all(.models[]; (.revision | test("^[0-9a-f]{40}$")) and all(.files[]; .size > 0 and (.sha256 | test("^[0-9a-f]{64}$"))))
' "$REPO_DIR/supply-chain/pins.json" >/dev/null
while IFS= read -r pin; do
    grep -Fq "$pin" "$REPO_DIR/core/wrenflow-domain/src/model_management.rs"
done < <(jq -r '.models[] | .revision, (.files[].sha256)' "$REPO_DIR/supply-chain/pins.json")
while IFS= read -r pin; do
    grep -Fq "$pin" "$REPO_DIR/scripts/download-ort.sh"
done < <(jq -r '.onnx_runtime | .version, .archive_sha256, .dylib_sha256' \
    "$REPO_DIR/supply-chain/pins.json")
grep -Fq 'https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-osx-arm64-${ORT_VERSION}.tgz' \
    "$REPO_DIR/scripts/download-ort.sh"
jq -e --arg today "$(date -u +%F)" '
  all(.exceptions[]; (.owner | length > 0) and .expires > $today and (.release_impact | length > 0))
' "$REPO_DIR/supply-chain/exceptions.json" >/dev/null
jq -e '.specVersion == "1.5" and .serialNumber == null and (.components | length > 600)' \
    "$METADATA_DIR/Wrenflow.cdx.json" >/dev/null
jq -e --arg ort_sha "$ORT_SHA" '
  any(.components[];
    .name == "WrenflowShell" and
    any(.properties[]; .name == "wrenflow:release-artifact-digest" and .value == "artifact-provenance.json")) and
  any(.components[];
    .name == "onnxruntime" and .version == "1.24.2" and
    any(.hashes[]; .alg == "SHA-256" and .content == $ort_sha))
' "$METADATA_DIR/Wrenflow.cdx.json" >/dev/null
if grep -Fq "$REPO_DIR" "$METADATA_DIR/Wrenflow.cdx.json"; then
    echo "CycloneDX output contains a machine-specific workspace path" >&2
    exit 1
fi
for component in 'gpui 0.2.2' 'gpui-component 0.5.1' 'gpui-component-assets 0.5.1'; do
    grep -Fq "$component" "$METADATA_DIR/RustThirdPartyLicenses.txt"
done

SECOND="$FIXTURES/metadata"
SOURCE_DATE_EPOCH="$(git -C "$REPO_DIR" show -s --format=%ct HEAD)" \
    "$REPO_DIR/scripts/generate-supply-chain.sh" "$SECOND" >/dev/null
for deterministic in Wrenflow.cdx.json RustThirdPartyLicenses.txt pins.json exceptions.json provenance.json SHA256SUMS; do
    cmp "$METADATA_DIR/$deterministic" "$SECOND/$deterministic"
done

FAKE_APP="$FIXTURES/Wrenflow.app"
mkdir -p "$FAKE_APP/Contents/MacOS" "$FAKE_APP/Contents/Frameworks"
printf 'app binary' >"$FAKE_APP/Contents/MacOS/wrenflow"
printf 'swift shell' >"$FAKE_APP/Contents/Frameworks/libWrenflowShell.dylib"
printf 'ort dylib' >"$FAKE_APP/Contents/MacOS/libonnxruntime.dylib"
printf 'signed dmg fixture' >"$FIXTURES/Wrenflow.dmg"
printf '{"id":"12345678-1234-1234-1234-123456789abc","status":"Invalid"}\n' \
    >"$FIXTURES/notary-invalid.json"
BAD_FINAL="$FIXTURES/bad-final"
cp -R "$SECOND" "$BAD_FINAL"
if GITHUB_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)" \
    GITHUB_REPOSITORY="IlyaGulya/wrenflow" GITHUB_RUN_ID="31306126055" \
    GITHUB_RUN_ATTEMPT="1" GITHUB_SERVER_URL="https://github.com" \
    WRENFLOW_RELEASE_TAG="v0.4.0-beta.1" WRENFLOW_RELEASE_VERSION="0.4.0-beta.1" \
    WRENFLOW_RELEASE_BUILD_NUMBER="42" \
    "$REPO_DIR/scripts/finalize-release-metadata.sh" \
        "$FAKE_APP" "$FIXTURES/Wrenflow.dmg" "$BAD_FINAL" \
        "$FIXTURES/notary-invalid.json" >/dev/null 2>&1; then
    echo "Release evidence accepted a rejected notarization" >&2
    exit 1
fi

printf '{"id":"12345678-1234-1234-1234-123456789abc","status":"Accepted"}\n' \
    >"$FIXTURES/notary-accepted.json"
FINAL="$FIXTURES/final"
cp -R "$SECOND" "$FINAL"
GITHUB_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)" \
GITHUB_REPOSITORY="IlyaGulya/wrenflow" GITHUB_RUN_ID="31306126055" \
GITHUB_RUN_ATTEMPT="1" GITHUB_SERVER_URL="https://github.com" \
WRENFLOW_RELEASE_TAG="v0.4.0-beta.1" WRENFLOW_RELEASE_VERSION="0.4.0-beta.1" \
WRENFLOW_RELEASE_BUILD_NUMBER="42" \
    "$REPO_DIR/scripts/finalize-release-metadata.sh" \
        "$FAKE_APP" "$FIXTURES/Wrenflow.dmg" "$FINAL" \
        "$FIXTURES/notary-accepted.json"
cp "$FIXTURES/Wrenflow.dmg" "$FINAL/Wrenflow.dmg"
jq -e '
  .schema_version == 1 and
  .workflow.run_id == "31306126055" and
  .workflow.attempt == "1" and
  .notarization.status == "Accepted" and
  .notarization.submission_id == "12345678-1234-1234-1234-123456789abc" and
  .release.tag == "v0.4.0-beta.1" and
  .identity.bundle_id == "me.gulya.wrenflow" and
  .identity.team_id == "T4LV8K9BGV"
' "$FINAL/release-evidence.json" >/dev/null
jq -e '
  .predicate.runDetails.metadata.workflowRun == "https://github.com/IlyaGulya/wrenflow/actions/runs/31306126055/attempts/1" and
  .predicate.runDetails.metadata.notarySubmissionId == "12345678-1234-1234-1234-123456789abc"
' "$FINAL/artifact-provenance.json" >/dev/null
(
    cd "$FINAL"
    shasum -a 256 -c SHA256SUMS >/dev/null
)

while IFS= read -r action; do
    [[ "$action" == ./* ]] && continue
    if [[ ! "$action" =~ @[0-9a-f]{40}$ ]]; then
        echo "GitHub Action is not pinned to an immutable commit: $action" >&2
        exit 1
    fi
done < <(rg -o 'uses:[[:space:]]*[^#[:space:]]+' "$REPO_DIR/.github/workflows" |
    sed -E 's/^.*uses:[[:space:]]*//')
if rg -n 'curl .*raw\.githubusercontent\.com/.*/(main|master)/' "$REPO_DIR/.github/workflows"; then
    echo "Workflow downloads an unpinned script" >&2
    exit 1
fi

NETWORK_SOURCES=(
    "$REPO_DIR/core/wrenflow-core/src/model_downloader.rs"
    "$REPO_DIR/core/wrenflow-runtime/src/update.rs"
)
if rg -n '"http://' "${NETWORK_SOURCES[@]}"; then
    echo "Production network code contains cleartext HTTP" >&2
    exit 1
fi
MODEL_ENDPOINTS="$(rg -o '"https://' "$REPO_DIR/core/wrenflow-core/src/model_downloader.rs" | wc -l | tr -d ' ')"
UPDATER_ENDPOINTS="$(sed '/^#\[cfg(test)\]/,$d' "$REPO_DIR/core/wrenflow-runtime/src/update.rs" | rg -o '"https://' | wc -l | tr -d ' ')"
if [[ "$MODEL_ENDPOINTS" != 1 || "$UPDATER_ENDPOINTS" != 1 ]]; then
    echo "Production network endpoint inventory changed; update the reviewed allowlist" >&2
    exit 1
fi
grep -Fq '"https://huggingface.co/{}/resolve/{}/{}"' \
    "$REPO_DIR/core/wrenflow-core/src/model_downloader.rs"
grep -Fq '"https://api.github.com/repos/IlyaGulya/wrenflow/releases?per_page=20"' \
    "$REPO_DIR/core/wrenflow-runtime/src/update.rs"
for update_host in github.com release-assets.githubusercontent.com objects.githubusercontent.com; do
    grep -Fq "$update_host" "$REPO_DIR/core/wrenflow-runtime/src/update.rs"
done
if rg -n '"https://' "$REPO_DIR/native/wrenflow-gpui/src/main.rs"; then
    echo "The GPUI shell must not contain a generic update URL" >&2
    exit 1
fi

echo "Supply-chain failure, reproducibility, license and workflow invariants pass"

#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
DMG_PATH="${2:-}"
OUTPUT_DIR="${3:-}"
NOTARY_RESULT="${4:-}"
if [[ ! -d "$APP_PATH" || ! -f "$DMG_PATH" || ! -d "$OUTPUT_DIR" || ! -f "$NOTARY_RESULT" ]]; then
    echo "Usage: $0 <Wrenflow.app> <Wrenflow.dmg> <metadata-output-dir> <notary-result.json>" >&2
    exit 64
fi
APP_PATH="$(cd "$APP_PATH" && pwd)"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
NOTARY_RESULT="$(cd "$(dirname "$NOTARY_RESULT")" && pwd)/$(basename "$NOTARY_RESULT")"

for variable in GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT \
    GITHUB_SERVER_URL WRENFLOW_RELEASE_TAG WRENFLOW_RELEASE_VERSION \
    WRENFLOW_RELEASE_BUILD_NUMBER WRENFLOW_RELEASE_SOURCE_COMMIT; do
    if [[ -z "${!variable:-}" ]]; then
        echo "Release evidence requires $variable" >&2
        exit 65
    fi
done
if [[ "$GITHUB_REPOSITORY" != "IlyaGulya/wrenflow" || "$GITHUB_SERVER_URL" != "https://github.com" || \
      ! "$WRENFLOW_RELEASE_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ || ! "$GITHUB_RUN_ID" =~ ^[0-9]+$ || \
      ! "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ || ! "$WRENFLOW_RELEASE_BUILD_NUMBER" =~ ^[0-9]+$ || \
      "$WRENFLOW_RELEASE_TAG" != "v$WRENFLOW_RELEASE_VERSION" || \
      ! "$WRENFLOW_RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "Release evidence environment failed its closed schema" >&2
    exit 65
fi

NOTARY_STATUS="$(jq -er '.status | select(. == "Accepted")' "$NOTARY_RESULT")" || {
    echo "Release evidence requires an Accepted notarization" >&2
    exit 65
}
NOTARY_SUBMISSION_ID="$(jq -er '.id | select(test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"))' "$NOTARY_RESULT")" || {
    echo "Release evidence requires a valid Apple submission ID" >&2
    exit 65
}

BINARY="$APP_PATH/Contents/MacOS/wrenflow"
SWIFT="$APP_PATH/Contents/Frameworks/libWrenflowShell.dylib"
ORT="$APP_PATH/Contents/MacOS/libonnxruntime.dylib"
for artifact in "$BINARY" "$SWIFT" "$ORT"; do
    [[ -f "$artifact" ]] || { echo "Missing release subject: $artifact" >&2; exit 65; }
done

subject() {
    local name="$1"
    local path="$2"
    local digest
    digest="$(shasum -a 256 "$path" | awk '{print $1}')"
    jq -n --arg name "$name" --arg digest "$digest" '{name:$name,digest:{sha256:$digest}}'
}

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
WORKFLOW_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT"
jq -S -n \
    --arg source_commit "$WRENFLOW_RELEASE_SOURCE_COMMIT" \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg workflow_run_id "$GITHUB_RUN_ID" \
    --arg workflow_run_attempt "$GITHUB_RUN_ATTEMPT" \
    --arg workflow_url "$WORKFLOW_URL" \
    --arg release_tag "$WRENFLOW_RELEASE_TAG" \
    --arg version "$WRENFLOW_RELEASE_VERSION" \
    --arg build_number "$WRENFLOW_RELEASE_BUILD_NUMBER" \
    --arg notary_submission_id "$NOTARY_SUBMISSION_ID" \
    --arg notary_status "$NOTARY_STATUS" \
    --arg dmg_sha256 "$DMG_SHA256" \
    '{
      schema_version: 1,
      source: {repository: $repository, commit: $source_commit},
      workflow: {run_id: $workflow_run_id, attempt: $workflow_run_attempt, url: $workflow_url},
      release: {tag: $release_tag, version: $version, build_number: $build_number},
      notarization: {submission_id: $notary_submission_id, status: $notary_status},
      identity: {bundle_id: "me.gulya.wrenflow", team_id: "T4LV8K9BGV"},
      artifact: {name: "Wrenflow.dmg", sha256: $dmg_sha256}
    }' >"$OUTPUT_DIR/release-evidence.json"

jq -S -n \
    --argjson app_binary "$(subject 'Wrenflow.app/Contents/MacOS/wrenflow' "$BINARY")" \
    --argjson swift_shell "$(subject 'Wrenflow.app/Contents/Frameworks/libWrenflowShell.dylib' "$SWIFT")" \
    --argjson ort "$(subject 'Wrenflow.app/Contents/MacOS/libonnxruntime.dylib' "$ORT")" \
    --argjson dmg "$(subject 'Wrenflow.dmg' "$DMG_PATH")" \
    --slurpfile predicate "$OUTPUT_DIR/provenance.json" \
    --slurpfile evidence "$OUTPUT_DIR/release-evidence.json" \
    '{
      _type:"https://in-toto.io/Statement/v1",
      subject:[$app_binary,$swift_shell,$ort,$dmg],
      predicateType:$predicate[0].predicateType,
      predicate:($predicate[0] | .runDetails.metadata += {
        workflowRun:$evidence[0].workflow.url,
        notarySubmissionId:$evidence[0].notarization.submission_id
      })
    }' \
    >"$OUTPUT_DIR/artifact-provenance.json"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 Wrenflow.cdx.json RustThirdPartyLicenses.txt pins.json exceptions.json provenance.json artifact-provenance.json release-evidence.json >SHA256SUMS
    printf '%s  Wrenflow.dmg\n' "$DMG_SHA256" >>SHA256SUMS
)

#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_WORKFLOW="$REPO_DIR/.github/workflows/build.yml"
RELEASE_WORKFLOW="$REPO_DIR/.github/workflows/release-please.yml"

require_pattern() {
    local pattern="$1"
    local file="$2"
    if ! grep -Fq -- "$pattern" "$file"; then
        echo "Release workflow invariant missing from $file: $pattern" >&2
        exit 1
    fi
}

reject_pattern() {
    local pattern="$1"
    local file="$2"
    if grep -Fq -- "$pattern" "$file"; then
        echo "Release workflow contains forbidden fail-open path in $file: $pattern" >&2
        exit 1
    fi
}

require_pattern "workflow_call:" "$BUILD_WORKFLOW"
require_pattern "release_tag:" "$BUILD_WORKFLOW"
require_pattern "IS_RELEASE: \${{ inputs.release_tag != '' }}" "$BUILD_WORKFLOW"
require_pattern "mise run test" "$BUILD_WORKFLOW"
require_pattern "mise run lint" "$BUILD_WORKFLOW"
require_pattern "scripts/notarize-release.sh build/Wrenflow.dmg" "$BUILD_WORKFLOW"
require_pattern "scripts/verify-release-artifact.sh build/gpui/Wrenflow.app build/Wrenflow.dmg --require-notarized" "$BUILD_WORKFLOW"
reject_pattern "github.event.release.tag_name" "$BUILD_WORKFLOW"

require_pattern "build-stable-release:" "$RELEASE_WORKFLOW"
require_pattern "if: needs.release-please.outputs.release_created == 'true'" "$RELEASE_WORKFLOW"
require_pattern "uses: ./.github/workflows/build.yml" "$RELEASE_WORKFLOW"
require_pattern "release_tag: \${{ needs.release-please.outputs.tag_name }}" "$RELEASE_WORKFLOW"

echo "Release workflow trigger and fail-closed artifact invariants are wired"

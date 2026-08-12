#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_WORKFLOW="$REPO_DIR/.github/workflows/build.yml"
RELEASE_WORKFLOW="$REPO_DIR/.github/workflows/release-please.yml"
PROMOTION_WORKFLOW="$REPO_DIR/.github/workflows/promote-stable.yml"
LINT_WORKFLOW="$REPO_DIR/.github/workflows/lint-workflows.yml"
RELEASE_CONFIG="$REPO_DIR/release-please-config.json"

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
require_pattern "verify-pr:" "$BUILD_WORKFLOW"
require_pattern "Check and build untrusted pull request without secrets" "$BUILD_WORKFLOW"
require_pattern "compatibility-minimum:" "$BUILD_WORKFLOW"
require_pattern "runs-on: macos-14" "$BUILD_WORKFLOW"
require_pattern "Select Xcode 16.2" "$BUILD_WORKFLOW"
require_pattern "runs-on: macos-26" "$BUILD_WORKFLOW"
require_pattern "Select Xcode 26.3" "$BUILD_WORKFLOW"
require_pattern "scripts/verify-macos-support.sh ci minimum" "$BUILD_WORKFLOW"
require_pattern "scripts/verify-macos-support.sh ci current" "$BUILD_WORKFLOW"
require_pattern "scripts/verify-macos-support.sh bundle build/gpui/Wrenflow.app" "$BUILD_WORKFLOW"
require_pattern "build_release:" "$BUILD_WORKFLOW"
require_pattern "performance_cold:" "$BUILD_WORKFLOW"
require_pattern "shard: [1, 2, 3, 4, 5]" "$BUILD_WORKFLOW"
require_pattern "Record one genuine cold start on the fresh constrained runner" "$BUILD_WORKFLOW"
require_pattern "--mode cold" "$BUILD_WORKFLOW"
require_pattern "--iterations 1" "$BUILD_WORKFLOW"
require_pattern "--cold-confirmed" "$BUILD_WORKFLOW"
require_pattern '--fresh-runner-id "gh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-cold-${{ matrix.shard }}"' "$BUILD_WORKFLOW"
require_pattern 'name: constrained-cold-${{ needs.build_release.outputs.source_commit }}-${{ matrix.shard }}' "$BUILD_WORKFLOW"
require_pattern 'pattern: constrained-cold-${{ needs.build_release.outputs.source_commit }}-*' "$BUILD_WORKFLOW"
require_pattern "performance_constrained:" "$BUILD_WORKFLOW"
require_pattern "needs: [build_release, performance_cold]" "$BUILD_WORKFLOW"
require_pattern "scripts/perf/gpui-performance.py merge-cold" "$BUILD_WORKFLOW"
require_pattern "mise run performance-self-test" "$BUILD_WORKFLOW"
require_pattern 'echo "PERFORMANCE_FAILURE_SUMMARY=$PERFORMANCE_ROOT/constrained-failure-summary.json"' "$BUILD_WORKFLOW"
require_pattern '--failure-summary "$PERFORMANCE_FAILURE_SUMMARY"' "$BUILD_WORKFLOW"
require_pattern "--idle-duration 1800" "$BUILD_WORKFLOW"
reject_pattern "mise run performance-sample" "$BUILD_WORKFLOW"
reject_pattern "leaks.txt" "$BUILD_WORKFLOW"
require_pattern "scripts/perf/gpui-performance.py sanitize" "$BUILD_WORKFLOW"
require_pattern "scripts/perf/gpui-performance.py seal" "$BUILD_WORKFLOW"
require_pattern "--profile constrained" "$BUILD_WORKFLOW"
require_pattern 'path: ${{ env.PERFORMANCE_RESULT }}' "$BUILD_WORKFLOW"
require_pattern '${{ env.PERFORMANCE_REPORT }}' "$BUILD_WORKFLOW"
require_pattern "Upload sanitized constrained evidence" "$BUILD_WORKFLOW"
require_pattern "needs: [build_release, performance_constrained]" "$BUILD_WORKFLOW"
require_pattern "if: needs.build_release.outputs.skip != 'true' && needs.performance_constrained.result == 'success'" "$BUILD_WORKFLOW"
require_pattern "publish:" "$BUILD_WORKFLOW"
require_pattern "verify_staged_or_published:" "$BUILD_WORKFLOW"
require_pattern "contents: read" "$BUILD_WORKFLOW"
require_pattern "contents: write" "$BUILD_WORKFLOW"
require_pattern "mise run setup-release-tools" "$BUILD_WORKFLOW"
require_pattern "Install pinned Rust lint components" "$BUILD_WORKFLOW"
require_pattern "mise run setup-rust-components" "$BUILD_WORKFLOW"
if [[ "$(grep -Fc 'run: mise run setup-rust-components' "$BUILD_WORKFLOW")" -ne 3 ]]; then
    echo "Every Build job that launches parallel Rust tasks must preinstall pinned components" >&2
    exit 1
fi
require_pattern 'rustup component add --toolchain "$RUSTUP_TOOLCHAIN" clippy rustfmt' "$REPO_DIR/mise.toml"
require_pattern 'ripgrep = "14.1.1"' "$REPO_DIR/mise.toml"
require_pattern "rg --version" "$REPO_DIR/mise.toml"
require_pattern "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" "$BUILD_WORKFLOW"
require_pattern "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c" "$BUILD_WORKFLOW"
require_pattern "retention-days: 21" "$BUILD_WORKFLOW"
require_pattern "scripts/notarize-release.sh build/Wrenflow.dmg" "$BUILD_WORKFLOW"
require_pattern "scripts/verify-release-artifact.sh build/gpui/Wrenflow.app build/Wrenflow.dmg --require-notarized" "$BUILD_WORKFLOW"
require_pattern "cd build/release-payload && shasum -a 256 -c SHA256SUMS" "$BUILD_WORKFLOW"
require_pattern "Refuse to overwrite staged or published candidate bytes" "$BUILD_WORKFLOW"
require_pattern "Stable release must be an empty release-please draft" "$BUILD_WORKFLOW"
require_pattern 'gh release upload "$RELEASE_TAG" release-payload/*' "$BUILD_WORKFLOW"
require_pattern '.isDraft == true and .isPrerelease == false' "$BUILD_WORKFLOW"
require_pattern '--target "$SOURCE_COMMIT"' "$BUILD_WORKFLOW"
require_pattern 'ref: ${{ needs.build_release.outputs.source_commit }}' "$BUILD_WORKFLOW"
require_pattern 'gh release download "$PUBLISH_TAG"' "$BUILD_WORKFLOW"
require_pattern '(cd downloaded && shasum -a 256 -c SHA256SUMS)' "$BUILD_WORKFLOW"
require_pattern "scripts/verify-release-artifact.sh" "$BUILD_WORKFLOW"
require_pattern "artifact-provenance.json" "$BUILD_WORKFLOW"
require_pattern "build/Wrenflow.dmg.notary-result.json" "$BUILD_WORKFLOW"
require_pattern "release-evidence.json" "$BUILD_WORKFLOW"
require_pattern "notarySubmissionId" "$REPO_DIR/scripts/finalize-release-metadata.sh"
require_pattern "workflowRun" "$REPO_DIR/scripts/finalize-release-metadata.sh"
require_pattern "verify_macho_loads" "$REPO_DIR/scripts/verify-release-artifact.sh"
require_pattern "com.apple.security.device.audio-input" "$REPO_DIR/scripts/verify-release-artifact.sh"
require_pattern "shasum -a 256 -c SHA256SUMS" "$REPO_DIR/scripts/verify-release-artifact.sh"
require_pattern 'spctl --assess --type open --context context:primary-signature' "$REPO_DIR/scripts/verify-release-artifact.sh"
require_pattern 'spctl --assess --type execute' "$REPO_DIR/scripts/verify-release-artifact.sh"
reject_pattern "github.event.release.tag_name" "$BUILD_WORKFLOW"
reject_pattern "brew install create-dmg" "$BUILD_WORKFLOW"
reject_pattern "runs-on: macos-latest" "$BUILD_WORKFLOW"
reject_pattern "raw.githubusercontent.com/rhysd/actionlint/main" "$LINT_WORKFLOW"
reject_pattern "softprops/action-gh-release" "$BUILD_WORKFLOW"
reject_pattern "--clobber" "$BUILD_WORKFLOW"
reject_pattern "for sample in 1 2 3 4 5" "$BUILD_WORKFLOW"
reject_pattern 'path: ${{ env.PERFORMANCE_ROOT }}' "$BUILD_WORKFLOW"
reject_pattern 'path: ${{ env.PERFORMANCE_DATA_ROOT }}' "$BUILD_WORKFLOW"
reject_pattern 'path: ${{ env.PERFORMANCE_FIXTURE }}' "$BUILD_WORKFLOW"
reject_pattern 'path: ${{ env.PERFORMANCE_APP }}' "$BUILD_WORKFLOW"

SEAL_BLOCK="$(awk '
    $0 == "      - name: Sanitize and seal constrained evidence" { capture = 1 }
    capture && $0 == "      - name: Enforce constrained performance budgets" { exit }
    capture { print }
' "$BUILD_WORKFLOW")"
if [[ -z "$SEAL_BLOCK" ]]; then
    echo "Constrained sanitize-and-seal block is missing" >&2
    exit 1
fi
for pattern in \
    '      - name: Sanitize and seal constrained evidence' \
    '        id: seal_constrained' \
    '          mise exec -- python3 scripts/perf/gpui-performance.py sanitize \' \
    '          mise exec -- python3 scripts/perf/gpui-performance.py seal \' \
    '            .sanitized == true and .sealed == true and' \
    '            (.candidate | has("app_path") | not) and' \
    '            (.candidate | has("executable_path") | not)'; do
    if ! grep -Fqx -- "$pattern" <<< "$SEAL_BLOCK"; then
        echo "Constrained sanitize-and-seal invariant is missing: $pattern" >&2
        exit 1
    fi
done
for forbidden in \
    'performance-verify' \
    'PERFORMANCE_REPORT'; do
    if grep -Fq -- "$forbidden" <<< "$SEAL_BLOCK"; then
        echo "Constrained sanitize-and-seal block contains verifier concern: $forbidden" >&2
        exit 1
    fi
done

VERIFY_BLOCK="$(awk '
    $0 == "      - name: Enforce constrained performance budgets" { capture = 1 }
    capture && $0 == "      - name: Upload sanitized constrained failure summary" { exit }
    capture { print }
' "$BUILD_WORKFLOW")"
if [[ -z "$VERIFY_BLOCK" ]]; then
    echo "Constrained budget-verification block is missing" >&2
    exit 1
fi
for pattern in \
    '      - name: Enforce constrained performance budgets' \
    '        id: verify_constrained' \
    '          mise run performance-verify -- \' \
    '            --profile constrained \' \
    '            --result "$PERFORMANCE_RESULT" \' \
    '            --report "$PERFORMANCE_REPORT"' \
    '          mise exec -- jq -e '\''.profile == "constrained" and .passed == true'\'' \' \
    '            "$PERFORMANCE_REPORT" >/dev/null'; do
    if ! grep -Fqx -- "$pattern" <<< "$VERIFY_BLOCK"; then
        echo "Constrained budget-verification invariant is missing: $pattern" >&2
        exit 1
    fi
done
for forbidden in \
    'gpui-performance.py sanitize' \
    'gpui-performance.py seal' \
    'continue-on-error: true'; do
    if grep -Fq -- "$forbidden" <<< "$VERIFY_BLOCK"; then
        echo "Constrained budget-verification block contains sealing concern: $forbidden" >&2
        exit 1
    fi
done

EVIDENCE_UPLOAD_BLOCK="$(awk '
    $0 == "      - name: Upload sanitized constrained evidence" { capture = 1 }
    capture && $0 == "  publish:" { exit }
    capture { print }
' "$BUILD_WORKFLOW")"
if [[ -z "$EVIDENCE_UPLOAD_BLOCK" ]]; then
    echo "Constrained evidence upload block is missing" >&2
    exit 1
fi
for pattern in \
    '      - name: Upload sanitized constrained evidence' \
    '        if: >-' \
    '          ${{ always() && steps.seal_constrained.outcome == '\''success'\'' &&' \
    '              (steps.verify_constrained.outcome == '\''success'\'' || steps.verify_constrained.outcome == '\''failure'\'') }}' \
    '          path: |' \
    '            ${{ env.PERFORMANCE_RESULT }}' \
    '            ${{ env.PERFORMANCE_REPORT }}' \
    '          if-no-files-found: error' \
    '          retention-days: 21'; do
    if ! grep -Fqx -- "$pattern" <<< "$EVIDENCE_UPLOAD_BLOCK"; then
        echo "Constrained evidence upload invariant is missing: $pattern" >&2
        exit 1
    fi
done
if [[ "$(grep -c '^            \${{ env\.PERFORMANCE_' <<< "$EVIDENCE_UPLOAD_BLOCK")" -ne 2 ]]; then
    echo "Constrained evidence artifact must upload exactly the sealed result and verifier report" >&2
    exit 1
fi
for forbidden in \
    'PERFORMANCE_ROOT' \
    'PERFORMANCE_APP' \
    'PERFORMANCE_FIXTURE' \
    'PERFORMANCE_DATA_ROOT' \
    'PERFORMANCE_FAILURE_SUMMARY'; do
    if grep -Fq -- "$forbidden" <<< "$EVIDENCE_UPLOAD_BLOCK"; then
        echo "Constrained evidence artifact contains forbidden raw or pathful source: $forbidden" >&2
        exit 1
    fi
done

FAILURE_UPLOAD_BLOCK="$(awk '
    $0 == "      - name: Upload sanitized constrained failure summary" { capture = 1 }
    capture && $0 == "      - name: Upload sanitized constrained evidence" { exit }
    capture { print }
' "$BUILD_WORKFLOW")"
if [[ -z "$FAILURE_UPLOAD_BLOCK" ]]; then
    echo "Constrained failure-summary upload block is missing" >&2
    exit 1
fi
for pattern in \
    '      - name: Upload sanitized constrained failure summary' \
    '        if: failure()' \
    '        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' \
    '          name: constrained-performance-failure-summary-${{ needs.build_release.outputs.source_commit }}' \
    '          path: ${{ env.PERFORMANCE_FAILURE_SUMMARY }}' \
    '          if-no-files-found: ignore' \
    '          retention-days: 7'; do
    if ! grep -Fqx -- "$pattern" <<< "$FAILURE_UPLOAD_BLOCK"; then
        echo "Constrained failure-summary upload invariant is missing: $pattern" >&2
        exit 1
    fi
done
if [[ "$(grep -c '^          path:' <<< "$FAILURE_UPLOAD_BLOCK")" -ne 1 ]]; then
    echo "Constrained failure-summary artifact must upload exactly one path" >&2
    exit 1
fi
for forbidden in \
    'PERFORMANCE_ROOT' \
    'PERFORMANCE_APP' \
    'PERFORMANCE_FIXTURE' \
    'PERFORMANCE_DATA_ROOT' \
    'PERFORMANCE_RESULT' \
    'PERFORMANCE_REPORT' \
    'retention-days: 21' \
    'if: always()'; do
    if grep -Fq -- "$forbidden" <<< "$FAILURE_UPLOAD_BLOCK"; then
        echo "Constrained failure-summary artifact contains forbidden source: $forbidden" >&2
        exit 1
    fi
done

require_pattern '"draft": true' "$RELEASE_CONFIG"
require_pattern "build-staged-stable-release:" "$RELEASE_WORKFLOW"
require_pattern "if: needs.release-please.outputs.release_created == 'true'" "$RELEASE_WORKFLOW"
require_pattern "uses: ./.github/workflows/build.yml" "$RELEASE_WORKFLOW"
require_pattern "release_tag: \${{ needs.release-please.outputs.tag_name }}" "$RELEASE_WORKFLOW"

require_pattern "workflow_dispatch:" "$PROMOTION_WORKFLOW"
require_pattern "release_tag:" "$PROMOTION_WORKFLOW"
require_pattern "expected_dmg_sha256:" "$PROMOTION_WORKFLOW"
require_pattern "PROMOTE_VERIFIED_STABLE" "$PROMOTION_WORKFLOW"
require_pattern "name: stable-production" "$PROMOTION_WORKFLOW"
require_pattern "cancel-in-progress: false" "$PROMOTION_WORKFLOW"
require_pattern 'ref: ${{ inputs.release_tag }}' "$PROMOTION_WORKFLOW"
require_pattern '.isDraft == true and .isPrerelease == false' "$PROMOTION_WORKFLOW"
require_pattern 'gh release download "$RELEASE_TAG"' "$PROMOTION_WORKFLOW"
require_pattern 'shasum -a 256 -c SHA256SUMS' "$PROMOTION_WORKFLOW"
require_pattern 'scripts/verify-release-promotion.sh staged' "$PROMOTION_WORKFLOW"
require_pattern 'scripts/verify-release-artifact.sh' "$PROMOTION_WORKFLOW"
require_pattern 'release-fingerprint-before.json' "$PROMOTION_WORKFLOW"
require_pattern 'cmp release-fingerprint-before.json release-fingerprint-second.json' "$PROMOTION_WORKFLOW"
require_pattern "Stable tag changed during promotion verification" "$PROMOTION_WORKFLOW"
require_pattern 'gh release edit "$RELEASE_TAG"' "$PROMOTION_WORKFLOW"
require_pattern '--draft=false --prerelease=false --latest --verify-tag' "$PROMOTION_WORKFLOW"
require_pattern "Public stable DMG differs from the approved staged bytes" "$PROMOTION_WORKFLOW"
require_pattern "retention-days: 30" "$PROMOTION_WORKFLOW"
reject_pattern "mise run build" "$PROMOTION_WORKFLOW"
reject_pattern "gh release upload" "$PROMOTION_WORKFLOW"
reject_pattern "--clobber" "$PROMOTION_WORKFLOW"

echo "Release workflow trigger and fail-closed artifact invariants are wired"

#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_WORKFLOW="$REPO_DIR/.github/workflows/build.yml"
RELEASE_WORKFLOW="$REPO_DIR/.github/workflows/release-please.yml"
PROMOTION_WORKFLOW="$REPO_DIR/.github/workflows/promote-stable.yml"
LINT_WORKFLOW="$REPO_DIR/.github/workflows/lint-workflows.yml"
RELEASE_CONFIG="$REPO_DIR/release-please-config.json"
PRIVATE_RELEASE_HELPER="$REPO_DIR/scripts/private-release-api.py"

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

require_repo_scoped_gh_release_commands() {
    local file="$1"
    local command=""
    local line
    while IFS= read -r line; do
        if [[ -z "$command" ]]; then
            if [[ "$line" != *"gh release "* ]]; then
                continue
            fi
            command="$line"
        else
            command="$command
$line"
        fi
        if [[ "$line" == *'\' ]]; then
            continue
        fi
        if [[ "$command" != *'--repo "$GITHUB_REPOSITORY"'* ]]; then
            echo "GitHub release command is not explicitly repository-scoped in $file:" >&2
            echo "$command" >&2
            exit 1
        fi
        command=""
    done < "$file"
    if [[ -n "$command" ]]; then
        echo "Unterminated GitHub release command in $file" >&2
        exit 1
    fi
}

require_frozen_stable_baseline_contract() {
    local file="$1"
    local release_file="${2:-$RELEASE_WORKFLOW}"
    local frozen_block publish_block
    frozen_block="$(awk '
        $0 == "  verify_frozen_performance_baseline:" { capture = 1 }
        capture && $0 == "  publish:" { exit }
        capture { print }
    ' "$file")"
    publish_block="$(awk '
        $0 == "  publish:" { capture = 1 }
        capture && $0 == "  verify_staged_or_published:" { exit }
        capture { print }
    ' "$file")"
    [[ -n "$frozen_block" && -n "$publish_block" ]] || return 1
    local required
    for required in \
        '    needs: build_release' \
        "    if: needs.build_release.outputs.skip != 'true' && inputs.release_tag != ''" \
        '      actions: read' \
        '      FROZEN_VERIFIER_SOURCE_COMMIT: "e233cc6db6b37307e9774db228ab11ecc4d0673c"' \
        '      REQUESTED_VERIFIER_SOURCE_COMMIT: ${{ inputs.verifier_source_commit }}' \
        '      - name: Require the reviewed frozen baseline verifier source' \
        '          if [[ "$REQUESTED_VERIFIER_SOURCE_COMMIT" != "$FROZEN_VERIFIER_SOURCE_COMMIT" ]]; then' \
        '          ref: ${{ inputs.verifier_source_commit }}' \
        '          fetch-depth: 0' \
        '      - name: Verify the frozen baseline verifier checkout' \
        '          if [[ "$(git rev-parse HEAD)" != "$FROZEN_VERIFIER_SOURCE_COMMIT" ]]; then' \
        '      FROZEN_ARTIFACT_ID: "9146492644"' \
        '      RELEASE_SOURCE_COMMIT: ${{ needs.build_release.outputs.source_commit }}' \
        '            "repos/$GITHUB_REPOSITORY/actions/artifacts/$FROZEN_ARTIFACT_ID" \' \
        '            "repos/$GITHUB_REPOSITORY/actions/artifacts/$FROZEN_ARTIFACT_ID/zip" \' \
        '          mise run verify-frozen-performance-baseline -- \' \
        '            --release-source "$RELEASE_SOURCE_COMMIT" \' \
        '            .evaluated_metrics == 24 and .evaluated_measurements == 24 and'; do
        grep -Fqx -- "$required" <<< "$frozen_block" || return 1
    done
    if grep -Fq -- 'continue-on-error:' <<< "$frozen_block"; then
        return 1
    fi
    for required in \
        '    needs: [build_release, compatibility-minimum, performance_constrained, verify_frozen_performance_baseline]' \
        "      \${{ always() && needs.build_release.outputs.skip != 'true' &&" \
        "          needs.compatibility-minimum.result == 'success' &&" \
        "          ((inputs.release_tag == '' && needs.performance_constrained.result == 'success') ||" \
        "           (inputs.release_tag != '' && needs.verify_frozen_performance_baseline.result == 'success')) }}"; do
        grep -Fqx -- "$required" <<< "$publish_block" || return 1
    done
    grep -Fqx -- "    if: needs.build_release.outputs.skip != 'true' && inputs.release_tag == ''" "$file" || return 1
    [[ "$(grep -Fxc -- "    if: needs.build_release.outputs.skip != 'true' && inputs.release_tag == ''" "$file")" -eq 3 ]] || return 1
    grep -Fqx -- '      verifier_source_commit: e233cc6db6b37307e9774db228ab11ecc4d0673c' "$release_file" || return 1
    [[ "$(grep -Fxc -- '      verifier_source_commit: e233cc6db6b37307e9774db228ab11ecc4d0673c' "$release_file")" -eq 1 ]] || return 1
    grep -Fqx -- '      actions: read' "$release_file" || return 1
    [[ "$(grep -Fxc -- '      actions: read' "$release_file")" -eq 1 ]] || return 1
    ! grep -Fqx -- '      actions: write' "$release_file"
}

require_frozen_source_history_contract() {
    local file="$1"
    local verify_block compatibility_block build_block verify_pr_block
    verify_block="$(awk '
        $0 == "  verify_frozen_performance_baseline:" { capture = 1 }
        capture && $0 == "  publish:" { exit }
        capture { print }
    ' "$file")"
    compatibility_block="$(awk '
        $0 == "  compatibility-minimum:" { capture = 1 }
        capture && $0 == "  verify_private_release_draft:" { exit }
        capture { print }
    ' "$file")"
    build_block="$(awk '
        $0 == "  build_release:" { capture = 1 }
        capture && $0 == "  performance_cold:" { exit }
        capture { print }
    ' "$file")"
    verify_pr_block="$(awk '
        $0 == "  verify-pr:" { capture = 1 }
        capture && $0 == "  compatibility-minimum:" { exit }
        capture { print }
    ' "$file")"
    [[ -n "$verify_block" && -n "$compatibility_block" && -n "$build_block" && -n "$verify_pr_block" ]] || return 1
    [[ "$(grep -Fxc -- '          fetch-depth: 0' <<< "$verify_block")" -eq 1 ]] || return 1
    [[ "$(grep -Fxc -- '          fetch-depth: 0' <<< "$compatibility_block")" -eq 1 ]] || return 1
    [[ "$(grep -Fxc -- '          fetch-depth: 0' <<< "$build_block")" -eq 1 ]] || return 1
    [[ "$(grep -Fxc -- '        run: mise run test' <<< "$compatibility_block")" -eq 1 ]] || return 1
    [[ "$(grep -Fxc -- '          mise run test' <<< "$build_block")" -eq 1 ]] || return 1
    ! grep -Fqx -- '          fetch-depth: 0' <<< "$verify_pr_block"
}

workflow_job_block() {
    local file="$1"
    local job="$2"
    awk -v target="  $job:" '
        $0 == target { capture = 1 }
        capture && $0 != target && $0 ~ /^  [A-Za-z0-9_-]+:$/ { exit }
        capture { print }
    ' "$file"
}

require_private_draft_permission_contract() {
    local build="$1"
    local release="$2"
    local promotion="$3"
    local preflight build_release publish beta_verify stable_verify existing_verify compatibility frozen verify_pr promote
    preflight="$(workflow_job_block "$build" verify_private_release_draft)"
    build_release="$(workflow_job_block "$build" build_release)"
    publish="$(workflow_job_block "$build" publish)"
    beta_verify="$(workflow_job_block "$build" verify_staged_or_published)"
    stable_verify="$(workflow_job_block "$build" verify_staged_release)"
    existing_verify="$(workflow_job_block "$build" verify_existing_private_release)"
    compatibility="$(workflow_job_block "$build" compatibility-minimum)"
    frozen="$(workflow_job_block "$build" verify_frozen_performance_baseline)"
    verify_pr="$(workflow_job_block "$build" verify-pr)"
    promote="$(workflow_job_block "$promotion" promote)"
    [[ -n "$preflight" && -n "$build_release" && -n "$publish" &&
       -n "$beta_verify" && -n "$stable_verify" && -n "$existing_verify" && -n "$compatibility" &&
       -n "$frozen" && -n "$verify_pr" && -n "$promote" ]] || return 1

    [[ "$(grep -Fxc -- '      contents: write' <<< "$preflight")" -eq 1 ]] || return 1
    grep -Fqx -- "      \${{ inputs.release_tag != '' &&" <<< "$preflight" || return 1
    grep -Fqx -- '      - name: Require exact empty tagless private stable draft' <<< "$preflight" || return 1
    grep -Fqx -- '    needs: verify_private_release_draft' <<< "$build_release" || return 1
    grep -Fqx -- "          inputs.confirmation != 'VERIFY_EXISTING_PRIVATE_DRAFT' &&" \
        <<< "$build_release" || return 1
    grep -Fqx -- "          (inputs.release_tag == '' || needs.verify_private_release_draft.result == 'success') }}" \
        <<< "$build_release" || return 1

    local block
    for block in "$build_release" "$beta_verify" "$compatibility" "$frozen" "$verify_pr"; do
        [[ "$(grep -Fxc -- '      contents: read' <<< "$block")" -eq 1 ]] || return 1
        ! grep -Fqx -- '      contents: write' <<< "$block" || return 1
    done
    grep -Fqx -- "    if: needs.build_release.outputs.skip != 'true' && inputs.release_tag == ''" \
        <<< "$beta_verify" || return 1
    ! grep -Fq -- 'private-release-api.py' <<< "$beta_verify" || return 1

    [[ "$(grep -Fxc -- '      contents: write' <<< "$stable_verify")" -eq 1 ]] || return 1
    grep -Fqx -- "      \${{ always() && inputs.release_tag != '' &&" <<< "$stable_verify" || return 1
    grep -Fqx -- "          needs.build_release.result == 'success' &&" <<< "$stable_verify" || return 1
    grep -Fqx -- "          needs.publish.result == 'success' }}" <<< "$stable_verify" || return 1
    grep -Fqx -- '      - name: Re-download and verify immutable private stable candidate' \
        <<< "$stable_verify" || return 1
    grep -Fq -- 'private-release-api.py download' <<< "$stable_verify" || return 1
    grep -Fq -- 'verify-release-promotion.sh staged' <<< "$stable_verify" || return 1

    [[ "$(grep -Fxc -- '      contents: write' <<< "$existing_verify")" -eq 1 ]] || return 1
    grep -Fqx -- "      \${{ github.event_name == 'workflow_dispatch' &&" <<< "$existing_verify" || return 1
    grep -Fqx -- "          inputs.confirmation == 'VERIFY_EXISTING_PRIVATE_DRAFT' }}" \
        <<< "$existing_verify" || return 1
    grep -Fqx -- '      - name: Require exact verification-only private draft inputs' \
        <<< "$existing_verify" || return 1
    grep -Fqx -- '      VERIFIER_SOURCE_COMMIT: ${{ inputs.verifier_source_commit }}' \
        <<< "$existing_verify" || return 1
    grep -Fq -- 'VERIFIER_SOURCE_COMMIT" != "e233cc6db6b37307e9774db228ab11ecc4d0673c' \
        <<< "$existing_verify" || return 1
    grep -Fqx -- '      - name: Re-download and verify existing immutable private stable candidate' \
        <<< "$existing_verify" || return 1
    grep -Fq -- 'private-release-api.py download' <<< "$existing_verify" || return 1
    grep -Fq -- 'verify-release-promotion.sh staged' <<< "$existing_verify" || return 1
    ! grep -Eq -- 'private-release-api\.py (upload|publish)|gh release (create|upload|edit)|-X (POST|PATCH|DELETE)' \
        <<< "$existing_verify" || return 1

    grep -Fqx -- "    if: github.event_name != 'workflow_dispatch' || inputs.confirmation != 'VERIFY_EXISTING_PRIVATE_DRAFT'" \
        <<< "$compatibility" || return 1
    grep -Fq -- "inputs.confirmation != 'VERIFY_EXISTING_PRIVATE_DRAFT'" <<< "$preflight" || return 1
    grep -Fq -- 'RECOVERY_CONFIRMATION" != "STAGE_EXISTING_PRIVATE_DRAFT' <<< "$preflight" || return 1

    [[ "$(grep -Fxc -- '      contents: write' <<< "$publish")" -eq 1 ]] || return 1
    grep -Fq -- 'private-release-api.py upload' <<< "$publish" || return 1
    [[ "$(grep -Fxc -- '      contents: write' "$build")" -eq 4 ]] || return 1
    [[ "$(grep -Fxc -- '      contents: write' <<< "$promote")" -eq 1 ]] || return 1
    [[ "$(grep -Fxc -- '      contents: write' "$release")" -eq 2 ]] || return 1
    grep -Fqx -- '      actions: read' "$release" || return 1
}

require_pattern "workflow_call:" "$BUILD_WORKFLOW"
require_pattern "workflow_dispatch:" "$BUILD_WORKFLOW"
require_pattern "release_tag:" "$BUILD_WORKFLOW"
require_pattern "release_id:" "$BUILD_WORKFLOW"
require_pattern "release_source_commit:" "$BUILD_WORKFLOW"
if [[ "$(grep -Fxc -- '      release_id:' "$BUILD_WORKFLOW")" -ne 2 ]]; then
    echo "Build workflow must require the immutable release id for recovery and reusable calls" >&2
    exit 1
fi
require_pattern "verifier_source_commit:" "$BUILD_WORKFLOW"
if [[ "$(grep -Fxc -- '      verifier_source_commit:' "$BUILD_WORKFLOW")" -ne 2 ]]; then
    echo "Build workflow must require the verifier source for recovery and reusable stable calls" >&2
    exit 1
fi
if [[ "$(grep -Fxc -- '      release_tool_source_commit:' "$BUILD_WORKFLOW")" -ne 2 ]]; then
    echo "Build workflow must require the immutable release tooling source for recovery and reusable calls" >&2
    exit 1
fi
require_pattern "STAGE_EXISTING_PRIVATE_DRAFT" "$BUILD_WORKFLOW"
require_pattern "VERIFY_EXISTING_PRIVATE_DRAFT" "$BUILD_WORKFLOW"
require_pattern "IS_RELEASE: \${{ inputs.release_tag != '' }}" "$BUILD_WORKFLOW"
require_pattern 'RELEASE_SOURCE_COMMIT: ${{ inputs.release_source_commit }}' "$BUILD_WORKFLOW"
require_pattern 'ref: ${{ inputs.release_source_commit || github.sha }}' "$BUILD_WORKFLOW"
require_pattern "Require exact empty tagless private stable draft" "$BUILD_WORKFLOW"
require_pattern 'private-release-api.py inspect' "$BUILD_WORKFLOW"
require_pattern '--release-id "$RELEASE_ID"' "$BUILD_WORKFLOW"
require_pattern 'git/matching-refs/tags/$RELEASE_TAG' "$BUILD_WORKFLOW"
require_pattern '.targetCommitish == $source' "$BUILD_WORKFLOW"
require_pattern '([.[] | select(.ref == $ref)] | length) == 0' "$BUILD_WORKFLOW"
require_pattern "Explicit private draft recovery confirmation is missing" "$BUILD_WORKFLOW"
reject_pattern 'TAG_COMMIT=$(git rev-list -n 1 "$TAG")' "$BUILD_WORKFLOW"
reject_pattern 'TAG_COMMIT=$(git rev-list -n 1 "$RELEASE_TAG")' "$BUILD_WORKFLOW"
reject_pattern 'gh release view "$RELEASE_TAG"' "$BUILD_WORKFLOW"
reject_pattern 'gh release upload "$RELEASE_TAG"' "$BUILD_WORKFLOW"
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
require_pattern '[tasks.verify-gpui-shader-contract]' "$REPO_DIR/mise.toml"
require_pattern 'scripts/verify-gpui-shader-contract.sh' "$REPO_DIR/mise.toml"
require_pattern '[tasks.setup-app-dependencies]' "$REPO_DIR/mise.toml"
require_pattern 'depends = ["download-ort", "setup-app-dependencies"' "$REPO_DIR/mise.toml"
if ! awk '
    /^  [A-Za-z0-9_-]+:$/ { setup = 0 }
    /mise run setup-app-dependencies/ { setup = 1 }
    /scripts\/verify-macos-support\.sh ci (minimum|current)/ {
        if (!setup) exit 1
        setup = 0
        verified += 1
    }
    END { if (verified != 3) exit 1 }
' "$BUILD_WORKFLOW"; then
    echo "Every macOS CI verifier must follow the locked app dependency setup in its job" >&2
    exit 1
fi
require_pattern "build_release:" "$BUILD_WORKFLOW"
require_pattern "performance_cold:" "$BUILD_WORKFLOW"
require_pattern "shard: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]" "$BUILD_WORKFLOW"
require_pattern "Record one genuine cold start on the fresh constrained runner" "$BUILD_WORKFLOW"
require_pattern "--mode cold" "$BUILD_WORKFLOW"
require_pattern "--iterations 1" "$BUILD_WORKFLOW"
require_pattern "--cold-confirmed" "$BUILD_WORKFLOW"
require_pattern '--fresh-runner-id "gh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-cold-${{ matrix.shard }}"' "$BUILD_WORKFLOW"
require_pattern 'name: constrained-cold-${{ needs.build_release.outputs.source_commit }}-${{ matrix.shard }}' "$BUILD_WORKFLOW"
require_pattern 'pattern: constrained-cold-${{ needs.build_release.outputs.source_commit }}-*' "$BUILD_WORKFLOW"
require_pattern "performance_constrained:" "$BUILD_WORKFLOW"
require_pattern "needs: [build_release, performance_cold]" "$BUILD_WORKFLOW"
require_pattern "verify_frozen_performance_baseline:" "$BUILD_WORKFLOW"
require_pattern '[tasks.verify-frozen-performance-baseline]' "$REPO_DIR/mise.toml"
require_pattern '[tasks.test-frozen-performance-baseline]' "$REPO_DIR/mise.toml"
require_pattern 'scripts/verify-frozen-performance-baseline.py' "$REPO_DIR/mise.toml"
require_frozen_stable_baseline_contract "$BUILD_WORKFLOW"
require_frozen_source_history_contract "$BUILD_WORKFLOW"
require_private_draft_permission_contract \
    "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" "$PROMOTION_WORKFLOW"
require_pattern "scripts/perf/gpui-performance.py merge-cold" "$BUILD_WORKFLOW"
require_pattern '[[ ${#COLD_SHARDS[@]} -eq 20 ]]' "$BUILD_WORKFLOW"
require_pattern 'MERGE_ARGS+=(--shard "$shard")' "$BUILD_WORKFLOW"
require_pattern 'diagnostic_stages_at_unix_ms' "$BUILD_WORKFLOW"
require_pattern "mise run performance-self-test" "$BUILD_WORKFLOW"
require_pattern '[tasks.performance-retained-ack]' "$REPO_DIR/mise.toml"
require_pattern 'gpui-performance.py retained-ack' "$REPO_DIR/mise.toml"
reject_pattern "--retain-ui" "$BUILD_WORKFLOW"
reject_pattern "WRENFLOW_PERFORMANCE_RETAINED_UI" "$BUILD_WORKFLOW"
reject_pattern "--malloc-stack-logging" "$BUILD_WORKFLOW"
require_pattern 'echo "PERFORMANCE_FAILURE_SUMMARY=$PERFORMANCE_ROOT/constrained-failure-summary.json"' "$BUILD_WORKFLOW"
require_pattern '--failure-summary "$PERFORMANCE_FAILURE_SUMMARY"' "$BUILD_WORKFLOW"
require_pattern "--idle-duration 1800" "$BUILD_WORKFLOW"
require_pattern "Measure warm LaunchServices startup" "$BUILD_WORKFLOW"
require_pattern "--mode warm" "$BUILD_WORKFLOW"
require_pattern "--iterations 10" "$BUILD_WORKFLOW"
require_pattern 'ten measured exact signed LaunchServices restarts after one excluded route-aware priming launch' "$BUILD_WORKFLOW"
require_pattern 'unmeasured-route-aware-exact-candidate-v1' "$BUILD_WORKFLOW"
require_pattern 'startup_diagnostic_at_unix_ms' "$BUILD_WORKFLOW"
require_pattern 'external_open_to_startup_ms' "$BUILD_WORKFLOW"
require_pattern '$phase.priming.launch_services_deregistered_at_unix_ms <= $phase.samples[0].started_at_unix_ms' "$BUILD_WORKFLOW"
reject_pattern "mise run performance-sample" "$BUILD_WORKFLOW"
reject_pattern "leaks.txt" "$BUILD_WORKFLOW"
require_pattern "scripts/perf/gpui-performance.py sanitize" "$BUILD_WORKFLOW"
require_pattern "scripts/perf/gpui-performance.py seal" "$BUILD_WORKFLOW"
require_pattern "--profile constrained" "$BUILD_WORKFLOW"
require_pattern 'path: ${{ env.PERFORMANCE_RESULT }}' "$BUILD_WORKFLOW"
require_pattern '${{ env.PERFORMANCE_REPORT }}' "$BUILD_WORKFLOW"
require_pattern "Upload sanitized constrained evidence" "$BUILD_WORKFLOW"
require_pattern "publish:" "$BUILD_WORKFLOW"
require_pattern "verify_staged_or_published:" "$BUILD_WORKFLOW"
require_pattern "verify_staged_release:" "$BUILD_WORKFLOW"
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
require_pattern '          fetch-depth: 0' "$LINT_WORKFLOW"
if [[ "$(grep -Fxc -- '          fetch-depth: 0' "$LINT_WORKFLOW")" -ne 1 ]]; then
    echo "Workflow lint must fetch full history exactly once for pinned-tool byte tests" >&2
    exit 1
fi
if ! awk '
    $0 == "  lint:" { capture = 1 }
    capture && $0 == "        run: mise run lint-workflows" { saw_test = 1 }
    capture && $0 == "          fetch-depth: 0" { saw_history = 1 }
    END { exit !(saw_test && saw_history) }
' "$LINT_WORKFLOW"; then
    echo "Workflow lint history is not bound to the job that executes pinned-tool tests" >&2
    exit 1
fi
require_pattern "retention-days: 21" "$BUILD_WORKFLOW"
require_pattern "scripts/notarize-release.sh build/Wrenflow.dmg" "$BUILD_WORKFLOW"
require_pattern "scripts/verify-release-artifact.sh build/gpui/Wrenflow.app build/Wrenflow.dmg --require-notarized" "$BUILD_WORKFLOW"
require_pattern "cd build/release-payload && shasum -a 256 -c SHA256SUMS" "$BUILD_WORKFLOW"
require_pattern "Refuse to overwrite staged or published candidate bytes" "$BUILD_WORKFLOW"
require_pattern "Stable release must be an empty release-please draft" "$BUILD_WORKFLOW"
require_pattern 'private-release-api.py upload' "$BUILD_WORKFLOW"
require_pattern 'elif gh release view "$PUBLISH_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then' "$BUILD_WORKFLOW"
require_pattern 'gh release create "$PUBLISH_TAG" release-payload/*' "$BUILD_WORKFLOW"
require_pattern '            --repo "$GITHUB_REPOSITORY" \' "$BUILD_WORKFLOW"
require_pattern '.isDraft == true and .isPrerelease == false' "$BUILD_WORKFLOW"
require_pattern '--target "$SOURCE_COMMIT"' "$BUILD_WORKFLOW"
require_pattern 'ref: ${{ needs.build_release.outputs.source_commit }}' "$BUILD_WORKFLOW"
require_pattern 'gh release download "$PUBLISH_TAG"' "$BUILD_WORKFLOW"
require_pattern '(cd downloaded && shasum -a 256 -c SHA256SUMS)' "$BUILD_WORKFLOW"
require_pattern "scripts/verify-release-artifact.sh" "$BUILD_WORKFLOW"
require_pattern "artifact-provenance.json" "$BUILD_WORKFLOW"
require_pattern "build/Wrenflow.dmg.notary-result.json" "$BUILD_WORKFLOW"
require_pattern "release-evidence.json" "$BUILD_WORKFLOW"
require_pattern 'WRENFLOW_RELEASE_SOURCE_COMMIT: ${{ steps.version.outputs.source_commit }}' "$BUILD_WORKFLOW"
require_pattern 'WRENFLOW_RELEASE_SOURCE_COMMIT' "$REPO_DIR/scripts/finalize-release-metadata.sh"
if grep -Fq -- '--arg source_commit "$GITHUB_SHA"' "$REPO_DIR/scripts/finalize-release-metadata.sh"; then
    echo "Release evidence must never derive its source from the workflow event SHA" >&2
    exit 1
fi
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
    capture && $0 == "  verify_frozen_performance_baseline:" { exit }
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
require_pattern "      actions: read" "$RELEASE_WORKFLOW"
require_pattern "uses: ./.github/workflows/build.yml" "$RELEASE_WORKFLOW"
require_pattern "release_tag: \${{ needs.release-please.outputs.tag_name }}" "$RELEASE_WORKFLOW"
require_pattern "release_id: \${{ needs.release-please.outputs.release_id }}" "$RELEASE_WORKFLOW"
require_pattern "release_tool_source_commit: aa025228f4f8d12e29c866b6be43eb2c0bf0834c" "$RELEASE_WORKFLOW"
require_pattern 'steps.release.outputs.upload_url' "$RELEASE_WORKFLOW"
require_pattern "source_commit: \${{ steps.release.outputs.sha }}" "$RELEASE_WORKFLOW"
require_pattern "release_source_commit: \${{ needs.release-please.outputs.source_commit }}" "$RELEASE_WORKFLOW"
require_pattern "verifier_source_commit: e233cc6db6b37307e9774db228ab11ecc4d0673c" "$RELEASE_WORKFLOW"

require_pattern "workflow_dispatch:" "$PROMOTION_WORKFLOW"
require_pattern "release_tag:" "$PROMOTION_WORKFLOW"
require_pattern "release_id:" "$PROMOTION_WORKFLOW"
require_pattern "release_tool_source_commit:" "$PROMOTION_WORKFLOW"
require_pattern "expected_dmg_sha256:" "$PROMOTION_WORKFLOW"
require_pattern "PROMOTE_VERIFIED_STABLE" "$PROMOTION_WORKFLOW"
reject_pattern "stable-production" "$PROMOTION_WORKFLOW"
reject_pattern "environment:" "$PROMOTION_WORKFLOW"
require_pattern "cancel-in-progress: false" "$PROMOTION_WORKFLOW"
require_pattern "Validate manual promotion inputs and derive private draft source" "$PROMOTION_WORKFLOW"
require_pattern 'ref: ${{ steps.inputs.outputs.source_commit }}' "$PROMOTION_WORKFLOW"
require_pattern '.isDraft == true and .isPrerelease == false' "$PROMOTION_WORKFLOW"
require_pattern '.targetCommitish == $source' "$PROMOTION_WORKFLOW"
require_pattern 'git/matching-refs/tags/$RELEASE_TAG' "$PROMOTION_WORKFLOW"
require_pattern '([.[] | select(.ref == $ref)] | length) == 0' "$PROMOTION_WORKFLOW"
require_pattern 'private-release-api.py download' "$PROMOTION_WORKFLOW"
require_pattern 'shasum -a 256 -c SHA256SUMS' "$PROMOTION_WORKFLOW"
require_pattern 'scripts/verify-release-promotion.sh staged' "$PROMOTION_WORKFLOW"
require_pattern 'scripts/verify-release-artifact.sh' "$PROMOTION_WORKFLOW"
require_pattern 'release-fingerprint-before.json' "$PROMOTION_WORKFLOW"
require_pattern 'cmp release-fingerprint-before.json release-fingerprint-second.json' "$PROMOTION_WORKFLOW"
require_pattern 'private-release-api.py publish' "$PROMOTION_WORKFLOW"
require_pattern '--approved-fingerprint release-fingerprint-second.json' "$PROMOTION_WORKFLOW"
require_pattern "Published stable tag does not resolve to the approved source commit" "$PROMOTION_WORKFLOW"
require_pattern '([.[] | select(.ref == $tag)] |' "$PROMOTION_WORKFLOW"
require_pattern 'length == 1 and .[0].object.type == "commit" and' "$PROMOTION_WORKFLOW"
require_pattern '.[0].object.sha == $source)' "$PROMOTION_WORKFLOW"
reject_pattern 'ref: ${{ inputs.release_tag }}' "$PROMOTION_WORKFLOW"
reject_pattern '--verify-tag' "$PROMOTION_WORKFLOW"
require_pattern "Public stable DMG differs from the approved staged bytes" "$PROMOTION_WORKFLOW"
require_pattern "retention-days: 30" "$PROMOTION_WORKFLOW"
reject_pattern "mise run build" "$PROMOTION_WORKFLOW"
reject_pattern "gh release upload" "$PROMOTION_WORKFLOW"
reject_pattern 'gh release view "$RELEASE_TAG"' "$PROMOTION_WORKFLOW"
reject_pattern 'gh release download "$RELEASE_TAG"' "$PROMOTION_WORKFLOW"
reject_pattern 'gh release edit "$RELEASE_TAG"' "$PROMOTION_WORKFLOW"
reject_pattern "--clobber" "$PROMOTION_WORKFLOW"
require_pattern 'f"repos/{args.repo}/releases/{args.release_id_int}"' "$PRIVATE_RELEASE_HELPER"
require_pattern 'f"repos/{args.repo}/releases/assets/{asset['"'"'id'"'"']}"' "$PRIVATE_RELEASE_HELPER"
reject_pattern '"release", "view"' "$PRIVATE_RELEASE_HELPER"
reject_pattern '"release", "upload"' "$PRIVATE_RELEASE_HELPER"
reject_pattern '"release", "download"' "$PRIVATE_RELEASE_HELPER"
reject_pattern '"release", "edit"' "$PRIVATE_RELEASE_HELPER"
require_repo_scoped_gh_release_commands "$BUILD_WORKFLOW"
require_repo_scoped_gh_release_commands "$PROMOTION_WORKFLOW"


REPO_SCOPE_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-release-repo-scope.XXXXXX")"
cleanup_repo_scope_fixture() { rm -rf -- "$REPO_SCOPE_FIXTURE"; }
trap cleanup_repo_scope_fixture EXIT

cp "$LINT_WORKFLOW" "$REPO_SCOPE_FIXTURE/lint-shallow.yml"
sed '/^          fetch-depth: 0$/d' "$REPO_SCOPE_FIXTURE/lint-shallow.yml" \
    > "$REPO_SCOPE_FIXTURE/lint-shallow-mutated.yml"
if grep -Fqx -- '          fetch-depth: 0' "$REPO_SCOPE_FIXTURE/lint-shallow-mutated.yml"; then
    echo "Workflow lint shallow-history negative fixture drifted" >&2
    exit 1
fi
if awk '
    $0 == "  lint:" { capture = 1 }
    capture && $0 == "        run: mise run lint-workflows" { saw_test = 1 }
    capture && $0 == "          fetch-depth: 0" { saw_history = 1 }
    END { exit !(saw_test && saw_history) }
' "$REPO_SCOPE_FIXTURE/lint-shallow-mutated.yml"; then
    echo "Workflow lint audit accepted missing pinned-tool history" >&2
    exit 1
fi

PINNED_RELEASE_TOOL_SOURCE="aa025228f4f8d12e29c866b6be43eb2c0bf0834c"
git cat-file -e "$PINNED_RELEASE_TOOL_SOURCE^{commit}"
git show "$PINNED_RELEASE_TOOL_SOURCE:scripts/private-release-api.py" \
    > "$REPO_SCOPE_FIXTURE/private-release-api.py"
git show "$PINNED_RELEASE_TOOL_SOURCE:scripts/test-private-release-api.py" \
    > "$REPO_SCOPE_FIXTURE/test-private-release-api.py"
rg -F -- '--approved-fingerprint' "$REPO_SCOPE_FIXTURE/private-release-api.py" >/dev/null
mise exec -- python3 "$REPO_SCOPE_FIXTURE/test-private-release-api.py" >/dev/null

expect_frozen_contract_rejected() {
    local label="$1"
    local workflow="$2"
    local release_workflow="${3:-$RELEASE_WORKFLOW}"
    if require_frozen_stable_baseline_contract "$workflow" "$release_workflow"; then
        echo "Frozen stable baseline workflow audit accepted $label" >&2
        exit 1
    fi
}

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-artifact.yml"
sed 's/FROZEN_ARTIFACT_ID: "9146492644"/FROZEN_ARTIFACT_ID: "9146492645"/' \
    "$REPO_SCOPE_FIXTURE/build-frozen-artifact.yml" \
    > "$REPO_SCOPE_FIXTURE/build-frozen-artifact-mutated.yml"
expect_frozen_contract_rejected wrong-frozen-artifact \
    "$REPO_SCOPE_FIXTURE/build-frozen-artifact-mutated.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-actions.yml"
sed '/^      actions: read$/d' "$REPO_SCOPE_FIXTURE/build-frozen-actions.yml" \
    > "$REPO_SCOPE_FIXTURE/build-frozen-actions-mutated.yml"
expect_frozen_contract_rejected missing-actions-read \
    "$REPO_SCOPE_FIXTURE/build-frozen-actions-mutated.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-publish.yml"
sed "s/needs.verify_frozen_performance_baseline.result == 'success'/needs.build_release.result == 'success'/" \
    "$REPO_SCOPE_FIXTURE/build-frozen-publish.yml" \
    > "$REPO_SCOPE_FIXTURE/build-frozen-publish-mutated.yml"
expect_frozen_contract_rejected publish-without-frozen-proof \
    "$REPO_SCOPE_FIXTURE/build-frozen-publish-mutated.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-checkout.yml"
sed 's/ref: ${{ inputs.verifier_source_commit }}/ref: ${{ inputs.release_source_commit }}/' \
    "$REPO_SCOPE_FIXTURE/build-frozen-checkout.yml" \
    > "$REPO_SCOPE_FIXTURE/build-frozen-checkout-mutated.yml"
expect_frozen_contract_rejected verifier-from-old-source \
    "$REPO_SCOPE_FIXTURE/build-frozen-checkout-mutated.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-caller.yml"
sed 's/ref: ${{ inputs.verifier_source_commit }}/ref: ${{ github.sha }}/' \
    "$REPO_SCOPE_FIXTURE/build-frozen-caller.yml" \
    > "$REPO_SCOPE_FIXTURE/build-frozen-caller-mutated.yml"
expect_frozen_contract_rejected verifier-from-dispatch-default-head \
    "$REPO_SCOPE_FIXTURE/build-frozen-caller-mutated.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-pin.yml"
sed 's/e233cc6db6b37307e9774db228ab11ecc4d0673c/e233cc6db6b37307e9774db228ab11ecc4d0673d/' \
    "$REPO_SCOPE_FIXTURE/build-frozen-pin.yml" \
    > "$REPO_SCOPE_FIXTURE/build-frozen-pin-mutated.yml"
expect_frozen_contract_rejected changed-verifier-pin \
    "$REPO_SCOPE_FIXTURE/build-frozen-pin-mutated.yml"

cp "$RELEASE_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-frozen-floating.yml"
sed 's/verifier_source_commit: e233cc6db6b37307e9774db228ab11ecc4d0673c/verifier_source_commit: ${{ github.sha }}/' \
    "$REPO_SCOPE_FIXTURE/release-frozen-floating.yml" \
    > "$REPO_SCOPE_FIXTURE/release-frozen-floating-mutated.yml"
expect_frozen_contract_rejected floating-automatic-verifier \
    "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-frozen-floating-mutated.yml"

cp "$RELEASE_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-frozen-actions.yml"
sed 's/^      actions: read$/      actions: write/' \
    "$REPO_SCOPE_FIXTURE/release-frozen-actions.yml" \
    > "$REPO_SCOPE_FIXTURE/release-frozen-actions-mutated.yml"
expect_frozen_contract_rejected writable-artifact-permission \
    "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-frozen-actions-mutated.yml"

expect_frozen_history_rejected() {
    local label="$1"
    local workflow="$2"
    if require_frozen_source_history_contract "$workflow"; then
        echo "Frozen source-history workflow audit accepted $label" >&2
        exit 1
    fi
}

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-shallow-compatibility.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-frozen-shallow-compatibility.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
start = source.index("  compatibility-minimum:\n")
end = source.index("  build_release:\n", start)
block = source[start:end]
needle = "          fetch-depth: 0\n"
if block.count(needle) != 1:
    raise SystemExit("compatibility full-history fixture drifted")
path.write_text(source[:start] + block.replace(needle, "", 1) + source[end:])
PY
expect_frozen_history_rejected shallow-compatibility-history \
    "$REPO_SCOPE_FIXTURE/build-frozen-shallow-compatibility.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-frozen-unnecessary-pr-history.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-frozen-unnecessary-pr-history.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
start = source.index("  verify-pr:\n")
end = source.index("  compatibility-minimum:\n", start)
block = source[start:end]
needle = "          persist-credentials: false\n"
if block.count(needle) != 1:
    raise SystemExit("verify-pr checkout fixture drifted")
path.write_text(source[:start] + block.replace(needle, "          fetch-depth: 0\n" + needle, 1) + source[end:])
PY
expect_frozen_history_rejected unnecessary-pr-history \
    "$REPO_SCOPE_FIXTURE/build-frozen-unnecessary-pr-history.yml"

expect_private_permission_rejected() {
    local label="$1"
    local build="${2:-$BUILD_WORKFLOW}"
    local release="${3:-$RELEASE_WORKFLOW}"
    local promotion="${4:-$PROMOTION_WORKFLOW}"
    if require_private_draft_permission_contract "$build" "$release" "$promotion"; then
        echo "Private draft permission audit accepted $label" >&2
        exit 1
    fi
}

mutate_job_permission() {
    local input="$1"
    local output="$2"
    local job="$3"
    local before="$4"
    local after="$5"
    mise exec -- python3 - "$input" "$output" "$job" "$before" "$after" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
target = f"  {sys.argv[3]}:\n"
start = source.index(target)
match = re.search(r"^  [A-Za-z0-9_-]+:\n", source[start + len(target):], re.MULTILINE)
end = len(source) if match is None else start + len(target) + match.start()
block = source[start:end]
before = f"      contents: {sys.argv[4]}\n"
after = f"      contents: {sys.argv[5]}\n"
if block.count(before) != 1:
    raise SystemExit(f"permission fixture drifted for {sys.argv[3]}")
Path(sys.argv[2]).write_text(source[:start] + block.replace(before, after, 1) + source[end:])
PY
}

mutate_job_permission "$BUILD_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/build-private-preflight-read.yml" \
    verify_private_release_draft write read
expect_private_permission_rejected private-preflight-read \
    "$REPO_SCOPE_FIXTURE/build-private-preflight-read.yml"

mutate_job_permission "$BUILD_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/build-release-write.yml" \
    build_release read write
expect_private_permission_rejected beta-build-write \
    "$REPO_SCOPE_FIXTURE/build-release-write.yml"

mutate_job_permission "$BUILD_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/build-beta-verify-write.yml" \
    verify_staged_or_published read write
expect_private_permission_rejected beta-verify-write \
    "$REPO_SCOPE_FIXTURE/build-beta-verify-write.yml"

mutate_job_permission "$BUILD_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/build-stable-verify-read.yml" \
    verify_staged_release write read
expect_private_permission_rejected stable-verify-read \
    "$REPO_SCOPE_FIXTURE/build-stable-verify-read.yml"

mutate_job_permission "$BUILD_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/build-existing-verify-read.yml" \
    verify_existing_private_release write read
expect_private_permission_rejected existing-private-verify-read \
    "$REPO_SCOPE_FIXTURE/build-existing-verify-read.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-stable-verify-without-always.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-stable-verify-without-always.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = "      ${{ always() && inputs.release_tag != '' &&\n"
if source.count(needle) != 1:
    raise SystemExit("stable verification always fixture drifted")
path.write_text(source.replace(needle, "      ${{ inputs.release_tag != '' &&\n", 1))
PY
expect_private_permission_rejected stable-verify-skip-propagation \
    "$REPO_SCOPE_FIXTURE/build-stable-verify-without-always.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-existing-verify-mutation.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-existing-verify-mutation.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
marker = "      - name: Re-download and verify existing immutable private stable candidate\n"
if source.count(marker) != 1:
    raise SystemExit("verification-only job fixture drifted")
mutation = "      - name: Mutate the private draft\n        run: mise exec -- python3 .release-workflow/scripts/private-release-api.py upload\n"
path.write_text(source.replace(marker, mutation + marker, 1))
PY
expect_private_permission_rejected existing-private-verification-mutation \
    "$REPO_SCOPE_FIXTURE/build-existing-verify-mutation.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-existing-verify-build-enabled.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-existing-verify-build-enabled.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = "          inputs.confirmation != 'VERIFY_EXISTING_PRIVATE_DRAFT' &&\n"
if source.count(needle) != 1:
    raise SystemExit("verification-only build exclusion fixture drifted")
path.write_text(source.replace(needle, "", 1))
PY
expect_private_permission_rejected existing-private-build-enabled \
    "$REPO_SCOPE_FIXTURE/build-existing-verify-build-enabled.yml"

mutate_job_permission "$BUILD_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/build-pr-write.yml" \
    verify-pr read write
expect_private_permission_rejected untrusted-pr-write \
    "$REPO_SCOPE_FIXTURE/build-pr-write.yml"

mutate_job_permission "$BUILD_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/build-publish-read.yml" \
    publish write read
expect_private_permission_rejected release-publish-read \
    "$REPO_SCOPE_FIXTURE/build-publish-read.yml"

mutate_job_permission "$PROMOTION_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/promotion-read.yml" \
    promote write read
expect_private_permission_rejected promotion-read \
    "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" "$REPO_SCOPE_FIXTURE/promotion-read.yml"

mutate_job_permission "$RELEASE_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/release-caller-read.yml" \
    build-staged-stable-release write read
expect_private_permission_rejected reusable-caller-read \
    "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-caller-read.yml" "$PROMOTION_WORKFLOW"

validate_empty_tagless_draft_fixture() {
    local release_json="$1"
    local refs_json="$2"
    local tag="$3"
    local source="$4"
    local confirmation="$5"
    local release_id="${6-369445618}"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$source" =~ ^[0-9a-f]{40}$ ]] || return 1
    [[ "$confirmation" == "STAGE_EXISTING_PRIVATE_DRAFT" ]] || return 1
    [[ "$release_id" =~ ^[1-9][0-9]*$ ]] || return 1
    mise exec -- jq -e --argjson id "$release_id" --arg tag "$tag" --arg source "$source" '
      (keys | sort) == (["assets", "id", "isDraft", "isPrerelease", "tagName", "targetCommitish"] | sort) and
      .id == $id and .tagName == $tag and .targetCommitish == $source and
      .isDraft == true and .isPrerelease == false and
      (.assets | type == "array" and length == 0)
    ' "$release_json" >/dev/null || return 1
    mise exec -- jq -e --arg ref "refs/tags/$tag" '
      type == "array" and ([.[] | select(.ref == $ref)] | length) == 0
    ' "$refs_json" >/dev/null || return 1
}

expect_draft_fixture_rejected() {
    local label="$1"
    local release_json="$2"
    local refs_json="$3"
    local tag="${4-v0.4.0}"
    local source="${5-1111111111111111111111111111111111111111}"
    local confirmation="${6-STAGE_EXISTING_PRIVATE_DRAFT}"
    local release_id="${7-369445618}"
    if validate_empty_tagless_draft_fixture \
        "$release_json" "$refs_json" "$tag" "$source" "$confirmation" "$release_id"; then
        echo "Tagless private draft fixture unexpectedly accepted $label" >&2
        exit 1
    fi
}

TAGLESS_SOURCE="1111111111111111111111111111111111111111"
mise exec -- jq -S -n --arg source "$TAGLESS_SOURCE" '{
  id: 369445618,
  assets: [],
  isDraft: true,
  isPrerelease: false,
  tagName: "v0.4.0",
  targetCommitish: $source
}' > "$REPO_SCOPE_FIXTURE/tagless-release.json"
mise exec -- jq -S -n '[{
  ref: "refs/tags/v0.4.0-beta.64",
  object: {type: "commit", sha: "2222222222222222222222222222222222222222"}
}]' > "$REPO_SCOPE_FIXTURE/tagless-refs.json"
validate_empty_tagless_draft_fixture \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" \
    "$REPO_SCOPE_FIXTURE/tagless-refs.json" \
    v0.4.0 "$TAGLESS_SOURCE" STAGE_EXISTING_PRIVATE_DRAFT

mise exec -- jq '.targetCommitish = ("3" * 40)' \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" \
    > "$REPO_SCOPE_FIXTURE/wrong-target.json"
expect_draft_fixture_rejected wrong-target \
    "$REPO_SCOPE_FIXTURE/wrong-target.json" "$REPO_SCOPE_FIXTURE/tagless-refs.json"

mise exec -- jq '.assets = [{name:"unexpected.dmg"}]' \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" \
    > "$REPO_SCOPE_FIXTURE/nonempty-assets.json"
expect_draft_fixture_rejected nonempty-assets \
    "$REPO_SCOPE_FIXTURE/nonempty-assets.json" "$REPO_SCOPE_FIXTURE/tagless-refs.json"

mise exec -- jq '.unexpected = "private"' \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" \
    > "$REPO_SCOPE_FIXTURE/extra-release-field.json"
expect_draft_fixture_rejected extra-release-field \
    "$REPO_SCOPE_FIXTURE/extra-release-field.json" "$REPO_SCOPE_FIXTURE/tagless-refs.json"

mise exec -- jq --arg source "$TAGLESS_SOURCE" '. + [{
  ref:"refs/tags/v0.4.0", object:{type:"commit", sha:$source}
}]' "$REPO_SCOPE_FIXTURE/tagless-refs.json" \
    > "$REPO_SCOPE_FIXTURE/preexisting-stable-tag.json"
expect_draft_fixture_rejected preexisting-stable-tag \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" \
    "$REPO_SCOPE_FIXTURE/preexisting-stable-tag.json"

expect_draft_fixture_rejected invalid-confirmation \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" "$REPO_SCOPE_FIXTURE/tagless-refs.json" \
    v0.4.0 "$TAGLESS_SOURCE" STAGE_PRIVATE_DRAFT
expect_draft_fixture_rejected missing-source \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" "$REPO_SCOPE_FIXTURE/tagless-refs.json" \
    v0.4.0 "" STAGE_EXISTING_PRIVATE_DRAFT
expect_draft_fixture_rejected noncanonical-release-id \
    "$REPO_SCOPE_FIXTURE/tagless-release.json" "$REPO_SCOPE_FIXTURE/tagless-refs.json" \
    v0.4.0 "$TAGLESS_SOURCE" STAGE_EXISTING_PRIVATE_DRAFT 0369445618
mise exec -- jq '.id = 369445619' "$REPO_SCOPE_FIXTURE/tagless-release.json" \
    > "$REPO_SCOPE_FIXTURE/wrong-release-id.json"
expect_draft_fixture_rejected wrong-release-id \
    "$REPO_SCOPE_FIXTURE/wrong-release-id.json" "$REPO_SCOPE_FIXTURE/tagless-refs.json"

validate_published_tag_refs_fixture() {
    local refs_json="$1"
    local tag="$2"
    local source="$3"
    mise exec -- jq -e --arg tag "refs/tags/$tag" --arg source "$source" '
      type == "array" and
      ([.[] | select(.ref == $tag)] |
        length == 1 and .[0].object.type == "commit" and
        .[0].object.sha == $source)
    ' "$refs_json" >/dev/null
}

expect_published_tag_refs_rejected() {
    local label="$1"
    local refs_json="$2"
    if validate_published_tag_refs_fixture \
        "$refs_json" v0.4.0 "$TAGLESS_SOURCE"; then
        echo "Published stable tag fixture unexpectedly accepted $label" >&2
        exit 1
    fi
}

mise exec -- jq --arg source "$TAGLESS_SOURCE" '. + [{
  ref:"refs/tags/v0.4.0", object:{type:"commit", sha:$source}
}]' "$REPO_SCOPE_FIXTURE/tagless-refs.json" \
    > "$REPO_SCOPE_FIXTURE/published-tag-refs.json"
validate_published_tag_refs_fixture \
    "$REPO_SCOPE_FIXTURE/published-tag-refs.json" v0.4.0 "$TAGLESS_SOURCE"

mise exec -- jq 'map(if .ref == "refs/tags/v0.4.0" then
  .object.sha = ("4" * 40) else . end)' \
    "$REPO_SCOPE_FIXTURE/published-tag-refs.json" \
    > "$REPO_SCOPE_FIXTURE/wrong-stable-sha.json"
expect_published_tag_refs_rejected wrong-stable-sha \
    "$REPO_SCOPE_FIXTURE/wrong-stable-sha.json"

mise exec -- jq 'map(if .ref == "refs/tags/v0.4.0" then
  .object.type = "tag" else . end)' \
    "$REPO_SCOPE_FIXTURE/published-tag-refs.json" \
    > "$REPO_SCOPE_FIXTURE/annotated-stable-tag.json"
expect_published_tag_refs_rejected wrong-stable-type \
    "$REPO_SCOPE_FIXTURE/annotated-stable-tag.json"

mise exec -- jq '. + [last]' \
    "$REPO_SCOPE_FIXTURE/published-tag-refs.json" \
    > "$REPO_SCOPE_FIXTURE/duplicate-stable-ref.json"
expect_published_tag_refs_rejected duplicate-stable-ref \
    "$REPO_SCOPE_FIXTURE/duplicate-stable-ref.json"

audit_tagless_source_contract() {
    local build="$1"
    local release="$2"
    local promotion="$3"
    require_pattern "STAGE_EXISTING_PRIVATE_DRAFT" "$build"
    require_pattern 'RELEASE_SOURCE_COMMIT: ${{ inputs.release_source_commit }}' "$build"
    require_pattern 'RELEASE_ID: ${{ inputs.release_id }}' "$build"
    require_pattern 'RELEASE_TOOL_SOURCE_COMMIT: ${{ inputs.release_tool_source_commit }}' "$build"
    require_pattern 'ref: ${{ inputs.release_tool_source_commit }}' "$build"
    require_pattern 'aa025228f4f8d12e29c866b6be43eb2c0bf0834c' "$build"
    require_pattern "Require exact empty tagless private stable draft" "$build"
    require_pattern 'git/matching-refs/tags/$RELEASE_TAG' "$build"
    require_pattern '([.[] | select(.ref == $ref)] | length) == 0' "$build"
    if [[ "$(grep -Fc 'ref: ${{ inputs.release_source_commit || github.sha }}' "$build")" -ne 2 ]] || \
       [[ "$(grep -Fc 'ref: ${{ inputs.release_source_commit }}' "$build")" -ne 2 ]]; then
        echo "Stable preflight, verification-only, build, and minimum-OS jobs must checkout the explicit release source" >&2
        return 1
    fi
    reject_pattern 'TAG_COMMIT=$(git rev-list -n 1 "$TAG")' "$build"
    reject_pattern 'TAG_COMMIT=$(git rev-list -n 1 "$RELEASE_TAG")' "$build"
    require_pattern 'source_commit: ${{ steps.release.outputs.sha }}' "$release"
    require_pattern 'release_id: ${{ steps.release-id.outputs.release_id }}' "$release"
    require_pattern 'release_id: ${{ needs.release-please.outputs.release_id }}' "$release"
    require_pattern 'release_tool_source_commit: aa025228f4f8d12e29c866b6be43eb2c0bf0834c' "$release"
    require_pattern 'ref: aa025228f4f8d12e29c866b6be43eb2c0bf0834c' "$release"
    require_pattern 'RELEASE_UPLOAD_URL: ${{ steps.release.outputs.upload_url }}' "$release"
    require_pattern 'release_source_commit: ${{ needs.release-please.outputs.source_commit }}' "$release"
    require_pattern 'RELEASE_ID: ${{ inputs.release_id }}' "$promotion"
    require_pattern 'RELEASE_TOOL_SOURCE_COMMIT: ${{ inputs.release_tool_source_commit }}' "$promotion"
    require_pattern 'ref: ${{ inputs.release_tool_source_commit }}' "$promotion"
    require_pattern 'aa025228f4f8d12e29c866b6be43eb2c0bf0834c' "$promotion"
    require_pattern 'ref: ${{ steps.inputs.outputs.source_commit }}' "$promotion"
    require_pattern 'private-release-api.py publish' "$promotion"
    require_pattern "Published stable tag does not resolve to the approved source commit" "$promotion"
    reject_pattern 'ref: ${{ inputs.release_tag }}' "$promotion"
    reject_pattern '--verify-tag' "$promotion"
}

expect_tagless_source_rejected() {
    local label="$1"
    local build="$2"
    local release="$3"
    local promotion="$4"
    if (audit_tagless_source_contract "$build" "$release" "$promotion") \
        > "$REPO_SCOPE_FIXTURE/$label.stdout" \
        2> "$REPO_SCOPE_FIXTURE/$label.stderr"; then
        echo "Tagless source-contract audit accepted $label" >&2
        exit 1
    fi
}

audit_tagless_source_contract "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" "$PROMOTION_WORKFLOW"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-missing-checkout.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-missing-checkout.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = '          ref: ${{ inputs.release_source_commit || github.sha }}\n'
if source.count(needle) != 2:
    raise SystemExit("explicit stable checkout fixture drifted")
path.write_text(source.replace(needle, "", 1))
PY
expect_tagless_source_rejected missing-explicit-checkout \
    "$REPO_SCOPE_FIXTURE/build-missing-checkout.yml" \
    "$RELEASE_WORKFLOW" "$PROMOTION_WORKFLOW"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-half-confirmation.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-half-confirmation.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = 'STAGE_EXISTING_PRIVATE_DRAFT'
if source.count(needle) < 2:
    raise SystemExit("recovery confirmation fixture drifted")
path.write_text(source.replace(needle, 'STAGE_PRIVATE_DRAFT'))
PY
expect_tagless_source_rejected half-recovery-confirmation \
    "$REPO_SCOPE_FIXTURE/build-half-confirmation.yml" \
    "$RELEASE_WORKFLOW" "$PROMOTION_WORKFLOW"

cp "$RELEASE_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-missing-source.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/release-missing-source.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = '      source_commit: ${{ steps.release.outputs.sha }}\n'
if source.count(needle) != 1:
    raise SystemExit("release source output fixture drifted")
path.write_text(source.replace(needle, "", 1))
PY
expect_tagless_source_rejected missing-release-source \
    "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-missing-source.yml" \
    "$PROMOTION_WORKFLOW"

cp "$RELEASE_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-missing-id.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/release-missing-id.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = '      release_id: ${{ steps.release-id.outputs.release_id }}\n'
if source.count(needle) != 1:
    raise SystemExit("release id output fixture drifted")
path.write_text(source.replace(needle, "", 1))
PY
expect_tagless_source_rejected missing-release-id \
    "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-missing-id.yml" \
    "$PROMOTION_WORKFLOW"

cp "$RELEASE_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-floating-tool.yml"
sed 's/ref: aa025228f4f8d12e29c866b6be43eb2c0bf0834c/ref: ${{ github.sha }}/' \
    "$REPO_SCOPE_FIXTURE/release-floating-tool.yml" \
    > "$REPO_SCOPE_FIXTURE/release-floating-tool-mutated.yml"
expect_tagless_source_rejected floating-release-tool-source \
    "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/release-floating-tool-mutated.yml" \
    "$PROMOTION_WORKFLOW"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-floating-tool.yml"
sed 's/ref: ${{ inputs.release_tool_source_commit }}/ref: ${{ github.sha }}/' \
    "$REPO_SCOPE_FIXTURE/build-floating-tool.yml" \
    > "$REPO_SCOPE_FIXTURE/build-floating-tool-mutated.yml"
expect_tagless_source_rejected floating-build-tool-source \
    "$REPO_SCOPE_FIXTURE/build-floating-tool-mutated.yml" "$RELEASE_WORKFLOW" \
    "$PROMOTION_WORKFLOW"

cp "$PROMOTION_WORKFLOW" "$REPO_SCOPE_FIXTURE/promote-floating-tool.yml"
sed 's/ref: ${{ inputs.release_tool_source_commit }}/ref: ${{ github.sha }}/' \
    "$REPO_SCOPE_FIXTURE/promote-floating-tool.yml" \
    > "$REPO_SCOPE_FIXTURE/promote-floating-tool-mutated.yml"
expect_tagless_source_rejected floating-promotion-tool-source \
    "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/promote-floating-tool-mutated.yml"

cp "$PROMOTION_WORKFLOW" "$REPO_SCOPE_FIXTURE/promote-tag-checkout.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/promote-tag-checkout.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = '          ref: ${{ steps.inputs.outputs.source_commit }}'
if source.count(needle) != 1:
    raise SystemExit("promotion source checkout fixture drifted")
path.write_text(source.replace(needle, '          ref: ${{ inputs.release_tag }}', 1))
PY
expect_tagless_source_rejected promotion-tag-checkout \
    "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/promote-tag-checkout.yml"

cp "$PROMOTION_WORKFLOW" "$REPO_SCOPE_FIXTURE/promote-tag-publish.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/promote-tag-publish.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = 'mise exec -- python3 .release-workflow/scripts/private-release-api.py publish'
if source.count(needle) != 1:
    raise SystemExit("promotion publication fixture drifted")
path.write_text(source.replace(needle, 'gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY"', 1))
PY
expect_tagless_source_rejected promotion-preexisting-tag-assumption \
    "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" \
    "$REPO_SCOPE_FIXTURE/promote-tag-publish.yml"

expect_repo_scope_rejected() {
    local label="$1"
    local workflow="$2"
    if (require_repo_scoped_gh_release_commands "$workflow") \
        >"$REPO_SCOPE_FIXTURE/$label.stdout" 2>"$REPO_SCOPE_FIXTURE/$label.stderr"; then
        echo "Release workflow repository-scope audit accepted $label" >&2
        exit 1
    fi
    rg -F "GitHub release command is not explicitly repository-scoped" \
        "$REPO_SCOPE_FIXTURE/$label.stderr" >/dev/null
}

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-create.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-create.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
create_index = next(
    index
    for index, line in enumerate(lines)
    if 'gh release create "$PUBLISH_TAG" release-payload/*' in line
)
scope_index = create_index + 1
if '--repo "$GITHUB_REPOSITORY"' not in lines[scope_index]:
    raise SystemExit("beta release create repository scope fixture drifted")
del lines[scope_index]
path.write_text("".join(lines))
PY
expect_repo_scope_rejected unscoped-beta-create "$REPO_SCOPE_FIXTURE/build-create.yml"

cp "$BUILD_WORKFLOW" "$REPO_SCOPE_FIXTURE/build-view.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/build-view.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = 'gh release view "$PUBLISH_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1'
replacement = 'gh release view "$PUBLISH_TAG" >/dev/null 2>&1'
if source.count(needle) != 1:
    raise SystemExit("beta release view repository scope fixture drifted")
path.write_text(source.replace(needle, replacement, 1))
PY
expect_repo_scope_rejected unscoped-beta-view "$REPO_SCOPE_FIXTURE/build-view.yml"

cp "$PROMOTION_WORKFLOW" "$REPO_SCOPE_FIXTURE/promote-stable.yml"
mise exec -- python3 - "$REPO_SCOPE_FIXTURE/promote-stable.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
needle = 'gh release view --repo "$GITHUB_REPOSITORY" --json tagName --jq .tagName'
replacement = 'gh release view --json tagName --jq .tagName'
if source.count(needle) != 1:
    raise SystemExit("stable latest-view repository scope fixture drifted")
path.write_text(source.replace(needle, replacement, 1))
PY
expect_repo_scope_rejected unscoped-stable-latest-view "$REPO_SCOPE_FIXTURE/promote-stable.yml"

echo "Release workflow trigger and fail-closed artifact invariants are wired"

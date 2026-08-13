#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="$REPO_DIR/support/release-runbook-policy.json"
FROZEN_PERFORMANCE_POLICY="$REPO_DIR/support/performance/frozen-stable-baseline-v1.json"
RUNBOOK="$REPO_DIR/docs/production-release-runbook.md"
PAYLOAD_FILES=(
    Wrenflow.dmg
    Wrenflow.cdx.json
    RustThirdPartyLicenses.txt
    pins.json
    exceptions.json
    provenance.json
    artifact-provenance.json
    release-evidence.json
    SHA256SUMS
)

usage() {
    echo "Usage: $0 source | staged|published <release.json> <payload> <tag> <dmg-sha256> <source-commit> <release-id> | promotion <approved-draft-payload> <public-payload>" >&2
}

verify_source_contract() {
    jq -e '
      .schema_version == 1 and
      .release_line == "gpui-first-public-v1" and
      .release_assumption == {
        existing_users:0,
        production_deployments:0,
        compatibility_scope:"clean_first_install_only",
        legacy_migration:"not_supported",
        downgrade_or_rollback:"not_supported",
        update_from_prerelease:"not_a_release_gate"
      } and
      .preflight.required_tracker_gates == [
        "wrenflow-duh.9.8",
        "wrenflow-duh.9.9",
        "wrenflow-duh.9.10",
        "wrenflow-duh.9.11"
      ] and
      .owner == {name:"Ilya Gulya",contact:"ilya@gulya.me"} and
      .privacy.default_telemetry == "disabled" and
      .privacy.owner_evidence_retention_days == 30 and
      .go_no_go.decision_mode == "single_owner_recorded" and
      .go_no_go.required_gates == [
        "exact_signed_notarized_private_stable_draft",
        "sealed_automated_performance_24_of_24",
        "owner_core_first_install_smoke",
        "owner_accessibility_appearance_display_smoke",
        "owner_first_release_lifecycle_smoke",
        "security_privacy_supply_chain"
      ] and
      .go_no_go.open_release_blockers_max == 0 and
      .go_no_go.security_privacy_or_data_loss_events_max == 0 and
      .go_no_go.signature_notary_gatekeeper_failures_max == 0 and
      .go_no_go.core_workflow_failures_max == 0 and
      .go_no_go.support_bundle_secret_findings_max == 0 and
      .promotion.policy == "exact_private_draft_bytes_only" and
      .promotion.stable_architecture == "release_please_draft_then_manual_exact_byte_promotion" and
      .promotion.private_draft_identity == "exact_positive_github_release_id" and
      .promotion.staged_payload_retention_days == 21 and
      .promotion.promotion_evidence_retention_days == 30 and
      .promotion.required_tracker_gates == ["wrenflow-duh.9.8", "wrenflow-duh.9.9", "wrenflow-duh.9.10", "wrenflow-duh.9.11"] and
      .promotion.github_environment_required == false and
      .promotion.required_external_reviewers == 0 and
      .post_publish.production_watch_hours == 0 and
      .post_publish.cohort_required == false and
      (.post_publish.required_checks | length) == 5
    ' "$POLICY" >/dev/null

    jq -e '
      .schema_version == 1 and
      .contract == "wrenflow.frozen-stable-performance.v1" and
      .artifact.repository == "IlyaGulya/wrenflow" and
      .artifact.run_id == 31603344709 and
      .artifact.artifact_id == 9146492644 and
      .artifact.archive_sha256 == "fc0ec7df15c1e91480ebd198986700ecd093e4a6b21de632df89c3f106ffb7de" and
      .artifact.result_sha256 == "ade2e5b50cdabd525eee87fc9f78f213cdf62205c70ce7b2742e05910f668553" and
      .artifact.report_sha256 == "d8d75160831c55fd9d13ef2ceb49a1ed9617264ed5bd174ec0ca4874b7593126" and
      .baseline.source_commit == "d3e01e0ec085121f3bd3e78038836a16608b98a0" and
      .baseline.dmg_sha256 == "d7a04beb4513026dda7f72847ab2c53a5c1a82861b49192c7c6ae6937b35e1a5" and
      .baseline.executable_sha256 == "3a2d786a31ac6491a88d3a3f9fa8b9d66f4991f5f5d32e507c0db3caf6f573af" and
      .baseline.evaluated_metrics == 24 and
      .baseline.evaluated_measurements == 24 and
      .stable_release.source_commit == "7e0e698191d003fe507b0729265cafceaf640c1e" and
      (.stable_release.allowed_diff | length) == 41
    ' "$FROZEN_PERFORMANCE_POLICY" >/dev/null

    local required_text
    for required_text in \
        "No default telemetry" \
        "Single-owner go/no-go" \
        "Exact-byte promotion" \
        "Clean-break first release" \
        "No legacy compatibility claim" \
        "Immediate public verification" \
        "wrenflow-duh.9.9" \
        "wrenflow-duh.9.10" \
        "wrenflow-duh.9.11"; do
        rg -F "$required_text" "$RUNBOOK" >/dev/null
    done

    rg -F 'Refuse to overwrite staged or published candidate bytes' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'Re-download and verify immutable published beta candidate' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'Re-download and verify immutable private stable candidate' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'Re-download and verify existing immutable private stable candidate' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F "inputs.confirmation == 'VERIFY_EXISTING_PRIVATE_DRAFT'" \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'needs.publish.result == '\''success'\'' }}' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'confirmation=VERIFY_EXISTING_PRIVATE_DRAFT' "$RUNBOOK" >/dev/null
    rg -F 'Require exact empty tagless private stable draft' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'verify_frozen_performance_baseline:' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'FROZEN_ARTIFACT_ID: "9146492644"' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'FROZEN_VERIFIER_SOURCE_COMMIT: "e233cc6db6b37307e9774db228ab11ecc4d0673c"' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'ref: ${{ inputs.verifier_source_commit }}' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'needs.verify_frozen_performance_baseline.result == '\''success'\''' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'googleapis/release-please-action@' \
        "$REPO_DIR/.github/workflows/release-please.yml" >/dev/null
    rg -F 'release_tag: ${{ needs.release-please.outputs.tag_name }}' \
        "$REPO_DIR/.github/workflows/release-please.yml" >/dev/null
    rg -F 'release_id: ${{ needs.release-please.outputs.release_id }}' \
        "$REPO_DIR/.github/workflows/release-please.yml" >/dev/null
    rg -F 'release_source_commit: ${{ needs.release-please.outputs.source_commit }}' \
        "$REPO_DIR/.github/workflows/release-please.yml" >/dev/null
    rg -F 'verifier_source_commit: e233cc6db6b37307e9774db228ab11ecc4d0673c' \
        "$REPO_DIR/.github/workflows/release-please.yml" >/dev/null
    rg -F 'private-release-api.py derive-source' \
        "$REPO_DIR/.github/workflows/promote-stable.yml" >/dev/null
    rg -F 'private-release-api.py publish' \
        "$REPO_DIR/.github/workflows/promote-stable.yml" >/dev/null
    rg -F 'scripts/verify-release-promotion.sh published' \
        "$REPO_DIR/.github/workflows/promote-stable.yml" >/dev/null
    rg -F '"release-evidence.json"' \
        "$REPO_DIR/.github/workflows/promote-stable.yml" >/dev/null
}

canonical_payload_directory() {
    local directory="$1"
    local file actual_entries expected_entries
    if [[ "$directory" != /* || ! -d "$directory" || -L "$directory" ]]; then
        echo "Release payload must be an absolute non-symlink directory: $directory" >&2
        exit 64
    fi
    directory="$(cd "$directory" && pwd)"
    actual_entries="$(cd "$directory" && find . -mindepth 1 -maxdepth 1 -print | sed 's#^\./##' | LC_ALL=C sort)"
    expected_entries="$(printf '%s\n' "${PAYLOAD_FILES[@]}" | LC_ALL=C sort)"
    if [[ "$actual_entries" != "$expected_entries" ]]; then
        echo "Release payload directory does not contain the exact nine-file allowlist" >&2
        exit 65
    fi
    for file in "${PAYLOAD_FILES[@]}"; do
        if [[ ! -f "$directory/$file" || -L "$directory/$file" ]]; then
            echo "Release payload is missing regular file $file" >&2
            exit 65
        fi
    done
    (
        cd "$directory"
        shasum -a 256 -c SHA256SUMS
    ) >/dev/null
    jq -e '
      .schema_version == 1 and
      .source.repository == "IlyaGulya/wrenflow" and
      (.source.commit | test("^[0-9a-f]{40}$")) and
      (.release.tag == ("v" + .release.version)) and
      (.release.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$")) and
      .notarization.status == "Accepted" and
      .identity.bundle_id == "me.gulya.wrenflow" and
      .identity.team_id == "T4LV8K9BGV" and
      (.artifact.sha256 | test("^[0-9a-f]{64}$"))
    ' "$directory/release-evidence.json" >/dev/null
    local actual evidence_sha
    actual="$(shasum -a 256 "$directory/Wrenflow.dmg" | awk '{print $1}')"
    evidence_sha="$(jq -r '.artifact.sha256' "$directory/release-evidence.json")"
    if [[ "$actual" != "$evidence_sha" ]]; then
        echo "Release evidence does not authenticate the payload DMG" >&2
        exit 66
    fi
    printf '%s\n' "$directory"
}

verify_release() {
    local release_state="$1"
    shift
    local release_json="$1"
    local payload tag expected_sha source_commit release_id expected_draft result_label
    if [[ ! -f "$release_json" || -L "$release_json" ]]; then
        echo "Staged release metadata must be a regular JSON file" >&2
        exit 64
    fi
    payload="$(canonical_payload_directory "$2")"
    tag="$3"
    expected_sha="$4"
    source_commit="$5"
    release_id="$6"
    if [[ "$release_state" == "staged" ]]; then
        expected_draft=true
        result_label="Staged"
    else
        expected_draft=false
        result_label="Published"
    fi
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || \
          ! "$expected_sha" =~ ^[0-9a-f]{64}$ || \
          ! "$source_commit" =~ ^[0-9a-f]{40}$ || \
          ! "$release_id" =~ ^[1-9][0-9]*$ ]]; then
        echo "Staged tag, digest, source commit or release id failed its closed schema" >&2
        exit 64
    fi
    jq -e --argjson id "$release_id" --arg tag "$tag" --arg source "$source_commit" --argjson draft "$expected_draft" '
      (keys | sort) == (["assets", "id", "isDraft", "isPrerelease", "tagName", "targetCommitish"] | sort) and
      .id == $id and .tagName == $tag and .targetCommitish == $source and
      .isDraft == $draft and .isPrerelease == false and
      (.assets | type == "array" and length == 9) and
      all(.assets[];
        (keys | sort) == (["contentType", "createdAt", "digest", "id", "name", "size", "state", "updatedAt", "url"] | sort) and
        (.id | type == "number" and . > 0 and floor == .) and
        (.size | type == "number" and . > 0 and floor == .) and
        .state == "uploaded" and
        (.contentType | type == "string" and length > 0) and
        (.createdAt | type == "string" and length > 0) and
        (.updatedAt | type == "string" and length > 0) and
        (.url == ("https://api.github.com/repos/IlyaGulya/wrenflow/releases/assets/" + (.id | tostring))) and
        (.digest == null or (.digest | test("^sha256:[0-9a-f]{64}$")))) and
      ([.assets[].id] | unique | length) == 9 and
      ([.assets[].name] | sort) == ([
        "RustThirdPartyLicenses.txt",
        "SHA256SUMS",
        "Wrenflow.cdx.json",
        "Wrenflow.dmg",
        "artifact-provenance.json",
        "exceptions.json",
        "pins.json",
        "provenance.json",
        "release-evidence.json"
      ] | sort)
    ' "$release_json" >/dev/null
    jq -e \
        --arg tag "$tag" \
        --arg source "$source_commit" \
        --arg sha "$expected_sha" '
      .schema_version == 1 and
      .source.repository == "IlyaGulya/wrenflow" and
      .source.commit == $source and
      .release.tag == $tag and
      .release.version == ($tag | ltrimstr("v")) and
      (.release.version | contains("-") | not) and
      .notarization.status == "Accepted" and
      .identity.bundle_id == "me.gulya.wrenflow" and
      .identity.team_id == "T4LV8K9BGV" and
      .artifact.name == "Wrenflow.dmg" and
      .artifact.sha256 == $sha
    ' "$payload/release-evidence.json" >/dev/null
    jq -e --arg sha "$expected_sha" '
      ._type == "https://in-toto.io/Statement/v1" and
      .predicateType == "https://slsa.dev/provenance/v1" and
      any(.subject[]; .name == "Wrenflow.dmg" and .digest.sha256 == $sha) and
      (.predicate.runDetails.metadata.workflowRun |
        startswith("https://github.com/IlyaGulya/wrenflow/actions/runs/")) and
      (.predicate.runDetails.metadata.notarySubmissionId |
        test("^[0-9A-Fa-f-]{36}$"))
    ' "$payload/artifact-provenance.json" >/dev/null
    if [[ "$(shasum -a 256 "$payload/Wrenflow.dmg" | awk '{print $1}')" != "$expected_sha" ]]; then
        echo "Staged payload bytes do not match the approved digest" >&2
        exit 66
    fi
    echo "$result_label stable payload metadata passed: $expected_sha"
}

verify_promotion() {
    local candidate stable file
    local candidate_sha stable_sha candidate_version stable_version
    local candidate_source stable_source
    candidate="$(canonical_payload_directory "$1")"
    stable="$(canonical_payload_directory "$2")"
    candidate_sha="$(jq -r '.artifact.sha256' "$candidate/release-evidence.json")"
    stable_sha="$(jq -r '.artifact.sha256' "$stable/release-evidence.json")"
    candidate_version="$(jq -r '.release.version' "$candidate/release-evidence.json")"
    stable_version="$(jq -r '.release.version' "$stable/release-evidence.json")"
    candidate_source="$(jq -r '.source.commit' "$candidate/release-evidence.json")"
    stable_source="$(jq -r '.source.commit' "$stable/release-evidence.json")"

    if [[ "$stable_version" == *-* ]]; then
        echo "Stable promotion target must have a non-prerelease SemVer" >&2
        exit 66
    fi

    if [[ "$candidate_sha" != "$stable_sha" || \
          "$candidate_version" != "$stable_version" || \
          "$candidate_source" != "$stable_source" ]]; then
        echo "Public promotion must use the exact approved private draft identity and DMG bytes" >&2
        exit 67
    fi
    for file in "${PAYLOAD_FILES[@]}"; do
        if [[ "$(shasum -a 256 "$candidate/$file" | awk '{print $1}')" != \
              "$(shasum -a 256 "$stable/$file" | awk '{print $1}')" ]]; then
            echo "Public promotion changed approved draft asset $file" >&2
            exit 67
        fi
    done
    echo "Exact private-draft promotion verified: $stable_sha"
}

case "${1:-}" in
    source)
        [[ $# -eq 1 ]] || { usage; exit 64; }
        verify_source_contract
        echo "Production release runbook source contract passed"
        ;;
    staged)
        [[ $# -eq 7 ]] || { usage; exit 64; }
        verify_release staged "$2" "$3" "$4" "$5" "$6" "$7"
        ;;
    published)
        [[ $# -eq 7 ]] || { usage; exit 64; }
        verify_release published "$2" "$3" "$4" "$5" "$6" "$7"
        ;;
    promotion)
        [[ $# -eq 3 ]] || { usage; exit 64; }
        verify_promotion "$2" "$3"
        ;;
    *) usage; exit 64 ;;
esac

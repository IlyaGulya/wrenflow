#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="$REPO_DIR/support/release-runbook-policy.json"
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
    echo "Usage: $0 source | staged <release.json> <payload> <tag> <dmg-sha256> <source-commit> | promotion <candidate-payload> <stable-payload> [successor-revalidation.json]" >&2
}

verify_source_contract() {
    jq -e '
      .schema_version == 1 and
      .release_line == "gpui-v1" and
      .preflight.status == "blocked" and
      .preflight.blockers == [
        "wrenflow-duh.9.9",
        "wrenflow-duh.9.10",
        "wrenflow-duh.9.11"
      ] and
      ([.owners[] | .contact] | all(. == "ilya@gulya.me")) and
      .owners.security_and_privacy.subject == "Wrenflow security" and
      .owners.support.subject == "Wrenflow support" and
      .privacy.default_telemetry == "disabled" and
      .privacy.cohort_collection == "explicit_opt_in_manual" and
      .privacy.participant_code_retention_days_after_stable == 30 and
      .cohort.invitation_cap == 20 and
      .cohort.enrollment_target == 10 and
      .cohort.minimum_exact_candidate_installers == 8 and
      .cohort.minimum_response_rate_percent == 80 and
      .cohort.minimum_observation_days == 7 and
      .cohort.maximum_observation_days == 14 and
      .cohort.minimum_update_attempts == 20 and
      .cohort.transcriptions_per_installer == 20 and
      .go_no_go.open_release_blockers_max == 0 and
      .go_no_go.security_privacy_or_data_loss_events_max == 0 and
      .go_no_go.signature_notary_gatekeeper_failures_max == 0 and
      .go_no_go.unlaunchable_update_recoveries_max == 0 and
      .go_no_go.crash_loops_max == 0 and
      .go_no_go.stuck_input_overlay_or_duplicate_process_events_max == 0 and
      .go_no_go.support_bundle_secret_findings_max == 0 and
      .go_no_go.install_and_launch_success_percent_min == 100 and
      .go_no_go.current_line_update_success_percent_min == 95 and
      .go_no_go.tcc_and_core_workflow_success_percent_min == 95 and
      .go_no_go.transcription_success_percent_min == 99 and
      .promotion.policy == "byte_identical_or_fully_revalidated_successor" and
      .promotion.stable_architecture == "release_please_draft_then_manual_exact_byte_promotion" and
      .promotion.staged_payload_retention_days == 21 and
      .promotion.promotion_evidence_retention_days == 30 and
      .promotion.beta_to_stable_requires_successor_revalidation == true and
      .promotion.required_successor_gates == ["wrenflow-duh.9.9", "wrenflow-duh.9.10", "wrenflow-duh.9.11"] and
      .promotion.post_stable_observation_hours == 48
    ' "$POLICY" >/dev/null

    local required_text
    for required_text in \
        "No default telemetry" \
        "Frozen denominator" \
        "Byte-identical promotion" \
        "Fully revalidated successor" \
        "Clean-break release copy" \
        "Stop and recovery drill" \
        "release-please stable procedure" \
        "wrenflow-duh.9.9" \
        "wrenflow-duh.9.10" \
        "wrenflow-duh.9.11"; do
        rg -F "$required_text" "$RUNBOOK" >/dev/null
    done

    rg -F 'Refuse to overwrite staged or published candidate bytes' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'Re-download and verify immutable staged or published candidate' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'Release tag $TAG does not resolve to checked-out commit' \
        "$REPO_DIR/.github/workflows/build.yml" >/dev/null
    rg -F 'googleapis/release-please-action@' \
        "$REPO_DIR/.github/workflows/release-please.yml" >/dev/null
    rg -F 'release_tag: ${{ needs.release-please.outputs.tag_name }}' \
        "$REPO_DIR/.github/workflows/release-please.yml" >/dev/null
}

canonical_payload_directory() {
    local directory="$1"
    local file
    if [[ "$directory" != /* || ! -d "$directory" || -L "$directory" ]]; then
        echo "Release payload must be an absolute non-symlink directory: $directory" >&2
        exit 64
    fi
    directory="$(cd "$directory" && pwd)"
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

verify_staged() {
    local release_json="$1"
    local payload tag expected_sha source_commit
    if [[ ! -f "$release_json" || -L "$release_json" ]]; then
        echo "Staged release metadata must be a regular JSON file" >&2
        exit 64
    fi
    payload="$(canonical_payload_directory "$2")"
    tag="$3"
    expected_sha="$4"
    source_commit="$5"
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || \
          ! "$expected_sha" =~ ^[0-9a-f]{64}$ || \
          ! "$source_commit" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Staged tag, digest or source commit failed its closed schema" >&2
        exit 64
    fi
    jq -e --arg tag "$tag" '
      .tagName == $tag and .isDraft == true and .isPrerelease == false and
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
    echo "Staged stable payload metadata passed: $expected_sha"
}

verify_promotion() {
    local candidate stable revalidation
    local candidate_sha stable_sha candidate_version stable_version
    local candidate_source stable_source
    candidate="$(canonical_payload_directory "$1")"
    stable="$(canonical_payload_directory "$2")"
    revalidation="${3:-}"
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

    if [[ "$candidate_sha" == "$stable_sha" ]]; then
        if [[ "$candidate_version" != "$stable_version" || \
              "$candidate_source" != "$stable_source" ]]; then
            echo "Equal DMG bytes have conflicting version/source evidence" >&2
            exit 66
        fi
        echo "Byte-identical promotion verified: $stable_sha"
        return
    fi

    if [[ -z "$revalidation" || "$revalidation" != /* || ! -f "$revalidation" || -L "$revalidation" ]]; then
        echo "Changed stable bytes require an absolute successor revalidation record" >&2
        exit 67
    fi
    jq -e \
        --arg candidate_sha "$candidate_sha" \
        --arg stable_sha "$stable_sha" \
        --arg stable_source "$stable_source" '
      .schema_version == 1 and
      .decision == "approved" and
      .candidate_dmg_sha256 == $candidate_sha and
      .stable_dmg_sha256 == $stable_sha and
      .stable_source_commit == $stable_source and
      .owner == "Ilya Gulya" and
      (.approved_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .gates["wrenflow-duh.9.9"] == "passed" and
      .gates["wrenflow-duh.9.10"] == "passed" and
      .gates["wrenflow-duh.9.11"] == "passed"
    ' "$revalidation" >/dev/null
    echo "Fully revalidated successor promotion verified: $stable_sha"
}

case "${1:-}" in
    source)
        [[ $# -eq 1 ]] || { usage; exit 64; }
        verify_source_contract
        echo "Production release runbook source contract passed"
        ;;
    staged)
        [[ $# -eq 6 ]] || { usage; exit 64; }
        verify_staged "$2" "$3" "$4" "$5" "$6"
        ;;
    promotion)
        [[ $# -ge 3 && $# -le 4 ]] || { usage; exit 64; }
        verify_promotion "$2" "$3" "${4:-}"
        ;;
    *) usage; exit 64 ;;
esac

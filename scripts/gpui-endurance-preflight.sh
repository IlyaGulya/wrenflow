#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CYCLES=20
DISPOSABLE_CONFIRMATION="me.gulya.wrenflow-gpui-v1-delete"
EVIDENCE_POLICY="$REPO_DIR/support/acceptance/endurance-v1-policy.json"
EVIDENCE_VERIFIER="$REPO_DIR/scripts/gpui-endurance-evidence.py"
PAYLOAD_FILES=(
    Wrenflow.dmg Wrenflow.cdx.json RustThirdPartyLicenses.txt pins.json
    exceptions.json provenance.json artifact-provenance.json
    release-evidence.json SHA256SUMS
)

usage() {
    cat >&2 <<'USAGE'
Usage:
  gpui-endurance-preflight.sh automated [absolute-output-directory]
  gpui-endurance-preflight.sh candidate-plan <absolute-output-directory>
  gpui-endurance-preflight.sh verify-evidence <automated-json> <candidate-plan-json> <manifest-json>
  gpui-endurance-preflight.sh verify-post-promotion <candidate-plan-json> <observation-json>
  gpui-endurance-preflight.sh capture-hooks <checkpoint> <absolute-output-json>
  gpui-endurance-preflight.sh kill-stage <stage> <pid> <absolute-output-json>

Candidate execution modes require WRENFLOW_CONFIRM_DISPOSABLE_ACCOUNT and an
exact WRENFLOW_TEST_APP. Candidate-plan and both evidence verifiers require
WRENFLOW_BASELINE_PAYLOAD and WRENFLOW_TARGET_PAYLOAD, each naming one exact
published nine-file payload directory.
USAGE
}

require_output_directory() {
    local output="$1"
    if [[ "$output" != /* || -L "$output" ]]; then
        echo "Evidence output must be an absolute, non-symlink directory" >&2
        exit 64
    fi
    mkdir -p "$output"
    if [[ ! -d "$output" || -L "$output" ]]; then
        echo "Evidence output is not a real directory: $output" >&2
        exit 64
    fi
    (cd "$output" && pwd)
}

require_new_output_file() {
    local output="$1"
    local parent
    if [[ "$output" != /* || -e "$output" || -L "$output" ]]; then
        echo "Evidence file must be a new absolute path" >&2
        exit 64
    fi
    parent="$(dirname "$output")"
    if [[ ! -d "$parent" || -L "$parent" ]]; then
        echo "Evidence parent must be an existing non-symlink directory" >&2
        exit 64
    fi
}

canonical_new_output_file() {
    local output="$1"
    local parent
    require_new_output_file "$output"
    parent="$(cd -P "$(dirname "$output")" && pwd)"
    printf '%s/%s\n' "$parent" "$(basename "$output")"
}

require_regular_input() {
    local input="$1"
    local label="$2"
    if [[ "$input" != /* || ! -f "$input" || -L "$input" ]]; then
        echo "$label must be an absolute, regular, non-symlink file" >&2
        exit 65
    fi
}

require_disposable_candidate_app() {
    local app_path="$1"
    local label="$2"
    if [[ "${WRENFLOW_CONFIRM_DISPOSABLE_ACCOUNT:-}" != "$DISPOSABLE_CONFIRMATION" ]]; then
        echo "Refusing candidate mutation outside an explicitly confirmed disposable account" >&2
        exit 67
    fi
    if [[ "$app_path" != /* || "$(basename "$app_path")" != "Wrenflow.app" || \
          ! -d "$app_path" || -L "$app_path" ]]; then
        echo "$label must be an exact absolute non-symlink Wrenflow.app" >&2
        exit 65
    fi
    codesign --verify --deep --strict "$app_path"
    local signature identifier team_id
    signature="$(codesign --display --verbose=4 "$app_path" 2>&1)"
    identifier="$(sed -n 's/^Identifier=//p' <<<"$signature")"
    team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature")"
    if [[ "$identifier" != "me.gulya.wrenflow" || "$team_id" != "T4LV8K9BGV" ]]; then
        echo "Candidate app identity is not the production Wrenflow identity" >&2
        exit 67
    fi
    printf '%s\n' "$app_path"
}

automated_preflight() {
    local output disposable_root log source_commit tree_state temporary_base
    local update_source_sha data_paths_source_sha recovery_source_sha verifier_source_sha policy_sha log_sha
    output="$(require_output_directory "${1:-$REPO_DIR/build/gpui-endurance-preflight}")"
    log="$(canonical_new_output_file "$output/runtime-twenty-cycles.log")"
    require_new_output_file "$output/automated-preflight.json"
    source_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
    tree_state="clean"
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
        tree_state="dirty"
    fi

    temporary_base="${TMPDIR:-/tmp}"
    temporary_base="${temporary_base%/}"
    disposable_root="$(mktemp -d "$temporary_base/wrenflow-gpui-v1-preflight.XXXXXX")"
    touch "$disposable_root/.wrenflow-disposable-root"
    cleanup_disposable_root() {
        if [[ -n "${disposable_root:-}" && \
              "$(basename "$disposable_root")" == wrenflow-gpui-v1-preflight.* && \
              -f "$disposable_root/.wrenflow-disposable-root" ]]; then
            rm -rf -- "$disposable_root"
        fi
    }
    trap cleanup_disposable_root RETURN

    (
        cd "$REPO_DIR"
        WRENFLOW_ENDURANCE_DISPOSABLE_ROOT="$disposable_root" \
            mise exec -- cargo test -p wrenflow-runtime twenty_ -- --test-threads=1
        mise exec -- cargo test -p wrenflow-runtime update::tests:: -- --test-threads=1
    ) 2>&1 | tee "$log"

    local test_name
    for test_name in \
        "data_paths::tests::twenty_current_line_relaunches_preserve_only_gpui_v1_state" \
        "recovery::tests::twenty_interrupted_launches_clean_only_bounded_temporary_state" \
        "update::tests::stable_and_beta_channels_are_strictly_isolated" \
        "update::tests::offline_and_rate_limit_failures_are_actionable_and_bounded" \
        "update::tests::duplicate_malformed_and_unexpected_host_metadata_are_rejected" \
        "update::tests::partial_download_is_removed_and_never_published" \
        "update::tests::twenty_channel_download_and_transaction_fault_cycles_fail_closed"; do
        rg -F "test $test_name ... ok" "$log" >/dev/null
    done

    update_source_sha="$(shasum -a 256 "$REPO_DIR/core/wrenflow-runtime/src/update.rs" | awk '{print $1}')"
    data_paths_source_sha="$(shasum -a 256 "$REPO_DIR/core/wrenflow-runtime/src/data_paths.rs" | awk '{print $1}')"
    recovery_source_sha="$(shasum -a 256 "$REPO_DIR/core/wrenflow-runtime/src/recovery.rs" | awk '{print $1}')"
    verifier_source_sha="$(shasum -a 256 "$EVIDENCE_VERIFIER" | awk '{print $1}')"
    policy_sha="$(shasum -a 256 "$EVIDENCE_POLICY" | awk '{print $1}')"
    log_sha="$(shasum -a 256 "$log" | awk '{print $1}')"

    jq -S -n \
        --slurpfile policy "$EVIDENCE_POLICY" \
        --arg source_commit "$source_commit" \
        --arg tree_state "$tree_state" \
        --arg update_source_sha "$update_source_sha" \
        --arg data_paths_source_sha "$data_paths_source_sha" \
        --arg recovery_source_sha "$recovery_source_sha" \
        --arg verifier_source_sha "$verifier_source_sha" \
        --arg policy_sha "$policy_sha" \
        --arg log_sha "$log_sha" \
        --argjson cycles "$CYCLES" \
        '{
          schema_version: 1,
          contract: $policy[0].contract,
          source: {
            commit: $source_commit,
            tree_state: $tree_state,
            update_source_path: $policy[0].automated_update_fixtures.source_path,
            update_source_sha256: $update_source_sha,
            verifier_source_path: $policy[0].automated_update_fixtures.verifier_path,
            verifier_source_sha256: $verifier_source_sha,
            policy_sha256: $policy_sha
          },
          cycles: $cycles,
          automated_update_fixtures: {
            status: "passed",
            log: {file: "runtime-twenty-cycles.log", sha256: $log_sha},
            cases: [
              $policy[0].automated_update_fixtures.cases[] + {
                status: "passed",
                source_sha256: $update_source_sha,
                log_sha256: $log_sha
              }
            ]
          },
          other_automated: {
            current_line_relaunch: ($policy[0].automated_update_fixtures.other_cases[0] + {
              status: "passed",
              source_sha256: $data_paths_source_sha,
              log_sha256: $log_sha
            }),
            interrupted_write_cleanup: ($policy[0].automated_update_fixtures.other_cases[1] + {
              status: "passed",
              source_sha256: $recovery_source_sha,
              log_sha256: $log_sha
            })
          },
          candidate: "blocked_pending_immutable_notarized_artifacts",
          manual_candidate_rows: {
            M13: "pending_signed_manual",
            M14: "pending",
            M15: "pending",
            M16: "pending",
            M21: "pending_instruments_budget",
            M22: "pending_signed_manual"
          }
        }' >"$output/automated-preflight.json"

    mise exec -- python3 "$EVIDENCE_VERIFIER" source >/dev/null

    echo "Automated disposable-root preflight passed; signed candidate rows remain pending"
    echo "$output/automated-preflight.json"
}

candidate_identity() (
    set -euo pipefail
    local label="$1"
    local payload="$2"
    local output="$3"
    local expected_entries actual_entries expected_checksums actual_checksums
    local dmg_path evidence provenance checksums dmg_sha evidence_dmg_sha
    local release_evidence_sha provenance_sha checksums_sha version build_number
    local signature cdhash mount_root mounted_app app_count payload_json
    if [[ "$payload" != /* || ! -d "$payload" || -L "$payload" ]]; then
        echo "$label payload must be an absolute non-symlink directory" >&2
        exit 65
    fi
    payload="$(cd -P "$payload" && pwd)"
    expected_entries="$(printf '%s\n' "${PAYLOAD_FILES[@]}" | LC_ALL=C sort)"
    actual_entries="$(find "$payload" -mindepth 1 -maxdepth 1 -print | sed 's#^.*/##' | LC_ALL=C sort)"
    if [[ "$actual_entries" != "$expected_entries" ]]; then
        echo "$label payload must contain exactly the published nine-file allowlist" >&2
        exit 65
    fi
    local file
    for file in "${PAYLOAD_FILES[@]}"; do
        require_regular_input "$payload/$file" "$label payload $file"
    done
    mise exec -- python3 "$REPO_DIR/scripts/gpui-human-acceptance.py" \
        verify-candidate --candidate-dir "$payload" >/dev/null
    dmg_path="$payload/Wrenflow.dmg"
    evidence="$payload/release-evidence.json"
    provenance="$payload/artifact-provenance.json"
    checksums="$payload/SHA256SUMS"
    if rg -n -v '^[0-9a-f]{64}  [A-Za-z0-9._-]+$' "$checksums"; then
        echo "$label checksum set is outside the closed format" >&2
        exit 65
    fi
    expected_checksums="$(printf '%s\n' "${PAYLOAD_FILES[@]:0:8}" | LC_ALL=C sort)"
    actual_checksums="$(awk '{print $2}' "$checksums" | LC_ALL=C sort)"
    if [[ "$actual_checksums" != "$expected_checksums" ]]; then
        echo "$label checksum set must name each non-self payload file exactly once" >&2
        exit 65
    fi
    (cd "$payload" && shasum -a 256 -c SHA256SUMS)
    dmg_sha="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
    evidence_dmg_sha="$(jq -er '
      select(type == "object") |
      select((keys | sort) == (["artifact","identity","notarization","release","schema_version","source","workflow"] | sort)) |
      select(.schema_version == 1) |
      select(.source.repository == "IlyaGulya/wrenflow") |
      select(.source.commit | test("^[0-9a-f]{40}$")) |
      select(.workflow.url | test("^https://github\\.com/IlyaGulya/wrenflow/actions/runs/[0-9]+/attempts/[0-9]+$")) |
      select(.notarization.status == "Accepted") |
      select(.notarization.submission_id | test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")) |
      select(.identity == {bundle_id:"me.gulya.wrenflow",team_id:"T4LV8K9BGV"}) |
      select(.artifact.name == "Wrenflow.dmg") |
      .artifact.sha256 | select(test("^[0-9a-f]{64}$"))
    ' "$evidence")"
    if [[ "$dmg_sha" != "$evidence_dmg_sha" ]]; then
        echo "$label DMG does not match release-evidence.json" >&2
        exit 66
    fi
    jq -e \
        --arg dmg_sha "$dmg_sha" \
        --arg workflow "$(jq -r '.workflow.url' "$evidence")" \
        --arg notary "$(jq -r '.notarization.submission_id' "$evidence")" \
        --arg source "$(jq -r '.source.commit' "$evidence")" \
        --arg pins_sha "$(shasum -a 256 "$payload/pins.json" | awk '{print $1}')" '
      type == "object" and
      ._type == "https://in-toto.io/Statement/v1" and
      .predicateType == "https://slsa.dev/provenance/v1" and
      any(.subject[]; .name == "Wrenflow.dmg" and .digest == {sha256:$dmg_sha}) and
      .predicate.runDetails.metadata.workflowRun == $workflow and
      .predicate.runDetails.metadata.notarySubmissionId == $notary and
      .predicate.runDetails.metadata.invocationId == $source and
      any(.predicate.buildDefinition.resolvedDependencies[];
        .uri == "git+https://github.com/ilyagulya/wrenflow" and .digest == {gitCommit:$source}) and
      any(.predicate.buildDefinition.resolvedDependencies[];
        .uri == "file:supply-chain/pins.json" and .digest == {sha256:$pins_sha})
    ' "$provenance" >/dev/null
    jq -e \
        --arg source "$(jq -r '.source.commit' "$evidence")" \
        --slurpfile artifact "$provenance" '
      .predicateType == "https://slsa.dev/provenance/v1" and
      .runDetails.metadata.invocationId == $source and
      .buildDefinition == $artifact[0].predicate.buildDefinition and
      .runDetails.builder == $artifact[0].predicate.runDetails.builder
    ' "$payload/provenance.json" >/dev/null

    mount_root="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-candidate-mount.XXXXXX")"
    cleanup_candidate_mount() {
        /usr/bin/hdiutil detach "$mount_root" >/dev/null 2>&1 || true
        rmdir "$mount_root" >/dev/null 2>&1 || true
    }
    trap cleanup_candidate_mount EXIT
    /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_root" "$dmg_path" >/dev/null
    mounted_app="$mount_root/Wrenflow.app"
    app_count="$(find "$mount_root" -type d -name '*.app' -print | wc -l | tr -d '[:space:]')"
    if [[ ! -d "$mounted_app" || -L "$mounted_app" || "$app_count" != "1" ]]; then
        echo "$label DMG must contain exactly one root Wrenflow.app" >&2
        exit 65
    fi
    "$REPO_DIR/scripts/verify-release-artifact.sh" "$mounted_app" "$dmg_path" --require-notarized
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$mounted_app/Contents/Info.plist")"
    build_number="$(plutil -extract CFBundleVersion raw -o - "$mounted_app/Contents/Info.plist")"
    signature="$(codesign --display --verbose=4 "$mounted_app" 2>&1)"
    cdhash="$(sed -n 's/^CDHash=//p' <<<"$signature" | head -n 1 | tr '[:upper:]' '[:lower:]')"
    jq -e --arg version "$version" --arg build_number "$build_number" '
      .release.version == $version and
      .release.tag == ("v" + $version) and
      .release.build_number == $build_number and
      ($build_number | test("^[0-9]+$"))
    ' "$evidence" >/dev/null
    release_evidence_sha="$(shasum -a 256 "$evidence" | awk '{print $1}')"
    provenance_sha="$(shasum -a 256 "$provenance" | awk '{print $1}')"
    checksums_sha="$(shasum -a 256 "$checksums" | awk '{print $1}')"
    payload_json="$({
        for file in "${PAYLOAD_FILES[@]}"; do
            jq -n --arg name "$file" \
                --arg sha256 "$(shasum -a 256 "$payload/$file" | awk '{print $1}')" \
                '{name:$name,sha256:$sha256}'
        done
    } | jq -s '.')"
    jq -S -n \
        --argjson release "$(jq -c '.release' "$evidence")" \
        --arg source_commit "$(jq -r '.source.commit' "$evidence")" \
        --arg dmg_sha256 "$dmg_sha" \
        --arg release_evidence_sha256 "$release_evidence_sha" \
        --arg artifact_provenance_sha256 "$provenance_sha" \
        --arg checksum_set_sha256 "$checksums_sha" \
        --arg notary_id "$(jq -r '.notarization.submission_id' "$evidence")" \
        --arg app_cdhash "$cdhash" \
        --argjson payload_files "$payload_json" '
      {
        release_line: "gpui-v1",
        version: $release.version,
        tag: $release.tag,
        build_number: $release.build_number,
        source_commit: $source_commit,
        bundle_id: "me.gulya.wrenflow",
        team_id: "T4LV8K9BGV",
        dmg_sha256: $dmg_sha256,
        release_evidence_sha256: $release_evidence_sha256,
        artifact_provenance_sha256: $artifact_provenance_sha256,
        checksum_set_sha256: $checksum_set_sha256,
        notarization_submission_id: $notary_id,
        app_cdhash: $app_cdhash,
        payload_files: $payload_files
      }
    ' >"$output"
)

require_candidate_payload_inputs() {
    if [[ -z "${WRENFLOW_BASELINE_PAYLOAD:-}" ]]; then
        echo "WRENFLOW_BASELINE_PAYLOAD must name the exact published baseline payload" >&2
        return 64
    fi
    if [[ -z "${WRENFLOW_TARGET_PAYLOAD:-}" ]]; then
        echo "WRENFLOW_TARGET_PAYLOAD must name the exact published target payload" >&2
        return 64
    fi
}

authenticate_candidate_plan() (
    local plan="$1"
    local temporary baseline_identity target_identity
    require_regular_input "$plan" "candidate plan"
    if ! require_candidate_payload_inputs; then
        return 64
    fi
    mise exec -- python3 "$EVIDENCE_VERIFIER" validate-plan "$plan" >/dev/null
    temporary="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-plan-auth.XXXXXX")"
    cleanup_plan_authentication() { rm -rf -- "$temporary"; }
    trap cleanup_plan_authentication EXIT
    baseline_identity="$temporary/baseline.json"
    target_identity="$temporary/target.json"
    candidate_identity "WRENFLOW_BASELINE" "$WRENFLOW_BASELINE_PAYLOAD" "$baseline_identity"
    candidate_identity "WRENFLOW_TARGET" "$WRENFLOW_TARGET_PAYLOAD" "$target_identity"
    jq -e --slurpfile baseline "$baseline_identity" --slurpfile target "$target_identity" '
      .baseline == $baseline[0] and .target == $target[0]
    ' "$plan" >/dev/null || {
        echo "Candidate plan does not match the re-verified mounted payloads" >&2
        exit 66
    }
)

candidate_plan() (
    local output temporary baseline_identity target_identity
    if ! require_candidate_payload_inputs; then
        return 64
    fi
    output="$(require_output_directory "${1:-}")"
    require_new_output_file "$output/candidate-plan.json"
    temporary="$(mktemp -d "$output/.candidate-plan.XXXXXX")"
    cleanup_candidate_plan() {
        rm -rf -- "$temporary"
    }
    trap cleanup_candidate_plan EXIT
    baseline_identity="$temporary/baseline.json"
    target_identity="$temporary/target.json"
    candidate_identity "WRENFLOW_BASELINE" "$WRENFLOW_BASELINE_PAYLOAD" "$baseline_identity"
    candidate_identity "WRENFLOW_TARGET" "$WRENFLOW_TARGET_PAYLOAD" "$target_identity"
    jq -S -n \
        --slurpfile baseline "$baseline_identity" \
        --slurpfile target "$target_identity" \
        '{
          schema_version: 1,
          contract: "wrenflow.gpui.endurance.candidate-pair.v1",
          verification: "exact_notarized_candidate_pair_passed",
          baseline: $baseline[0],
          target: $target[0],
          rows: {M13:"pending_signed_manual",M22:"pending_signed_manual"}
        }' >"$temporary/candidate-plan.json"
    mise exec -- python3 "$EVIDENCE_VERIFIER" validate-plan "$temporary/candidate-plan.json" >/dev/null
    /usr/bin/install -m 600 "$temporary/candidate-plan.json" "$output/candidate-plan.json"
    echo "Signed lower GPUI baseline and exact target passed; M13/M22 remain pending"
)

capture_hooks() {
    local checkpoint="$1"
    local output="$2"
    local app_path binary process_count audio_node_count idle_sleep_assertion
    case "$checkpoint" in
        before|after_sleep_wake|after_lock_unlock|after_device_change|after_fault_recovery) ;;
        *) echo "Unknown privacy-safe hook checkpoint: $checkpoint" >&2; exit 64 ;;
    esac
    require_new_output_file "$output"
    app_path="$(require_disposable_candidate_app "${WRENFLOW_TEST_APP:-}" "WRENFLOW_TEST_APP")"
    binary="$app_path/Contents/MacOS/wrenflow"
    process_count="$(ps -axo command= | awk -v binary="$binary" \
        '$0 == binary || index($0, binary " ") == 1 { count++ } END { print count + 0 }')"
    audio_node_count="$(/usr/sbin/system_profiler SPAudioDataType -json 2>/dev/null | \
        jq '[.. | objects | select(has("_name"))] | length')"
    idle_sleep_assertion="$(/usr/bin/pmset -g assertions | \
        awk '$1 == "PreventUserIdleSystemSleep" { print $2; exit }')"
    if [[ ! "$process_count" =~ ^[0-9]+$ || ! "$audio_node_count" =~ ^[0-9]+$ || \
          ! "$idle_sleep_assertion" =~ ^[0-9]+$ ]]; then
        echo "Host hook collection failed its closed numeric schema" >&2
        exit 65
    fi
    jq -S -n \
        --arg checkpoint "$checkpoint" \
        --argjson app_process_count "$process_count" \
        --argjson audio_tree_node_count "$audio_node_count" \
        --argjson prevent_idle_sleep "$idle_sleep_assertion" \
        '{
          schema_version: 1,
          checkpoint: $checkpoint,
          app_process_count: $app_process_count,
          audio_tree_node_count: $audio_tree_node_count,
          prevent_user_idle_system_sleep: $prevent_idle_sleep,
          contains_device_names_or_paths: false
        }' >"$output"
}

kill_stage() {
    local stage="$1"
    local pid="$2"
    local output="$3"
    local app_path binary command_line source_commit
    local plan journal journal_evidence expected_phase expected_app_version
    local app_version plan_sha journal_sha expected_cdhash installed_cdhash signature
    local process_state process_role helper_arguments helper_parent helper_token helper_extra journal_token
    case "$stage" in
        recording|model_download|settings_write|update_staging|update_prepared|update_swapped|before_ready_finalization) ;;
        *) echo "Unknown fault-injection stage: $stage" >&2; exit 64 ;;
    esac
    if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "Fault-injection PID must be explicit and numeric" >&2
        exit 64
    fi
    output="$(canonical_new_output_file "$output")"
    case "$stage" in
        update_staging|update_prepared|update_swapped|before_ready_finalization)
            journal_evidence="${WRENFLOW_JOURNAL_EVIDENCE:-}"
            journal_evidence="$(canonical_new_output_file "$journal_evidence")"
            if [[ "$journal_evidence" == "$output" ]]; then
                echo "Journal evidence and SIGKILL record must be distinct new files" >&2
                exit 64
            fi
            ;;
    esac
    app_path="$(require_disposable_candidate_app "${WRENFLOW_TEST_APP:-}" "WRENFLOW_TEST_APP")"
    binary="$app_path/Contents/MacOS/wrenflow"
    command_line="$(ps -p "$pid" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$command_line" != "$binary" && "$command_line" != "$binary "* ]]; then
        echo "PID does not belong to the exact candidate app" >&2
        exit 67
    fi
    case "$stage" in
        update_staging|update_prepared|update_swapped|before_ready_finalization)
            plan="${WRENFLOW_M13_M22_PLAN:-}"
            journal="${WRENFLOW_UPDATE_JOURNAL:-}"
            require_regular_input "$plan" "WRENFLOW_M13_M22_PLAN"
            require_regular_input "$journal" "WRENFLOW_UPDATE_JOURNAL"
            authenticate_candidate_plan "$plan"
            case "$stage" in
                update_staging)
                    expected_phase="staging"
                    expected_app_version="$(jq -r '.baseline.version' "$plan")"
                    expected_cdhash="$(jq -r '.baseline.app_cdhash' "$plan")"
                    process_role="baseline_app"
                    ;;
                update_prepared)
                    expected_phase="prepared"
                    expected_app_version="$(jq -r '.baseline.version' "$plan")"
                    expected_cdhash="$(jq -r '.baseline.app_cdhash' "$plan")"
                    process_role="baseline_app"
                    ;;
                update_swapped|before_ready_finalization)
                    expected_phase="swapped"
                    expected_app_version="$(jq -r '.target.version' "$plan")"
                    expected_cdhash="$(jq -r '.target.app_cdhash' "$plan")"
                    if [[ "$stage" == "update_swapped" ]]; then
                        process_role="update_helper"
                    else
                        process_role="target_app"
                    fi
                    ;;
            esac
            jq -e \
                --arg phase "$expected_phase" \
                --arg baseline "$(jq -r '.baseline.version' "$plan")" \
                --arg target "$(jq -r '.target.version' "$plan")" \
                --arg target_sha "$(jq -r '.target.dmg_sha256' "$plan")" '
              type == "object" and
              (keys | sort) == (["from_version","install_root","phase","schema_version","sha256","token","version"] | sort) and
              .schema_version == 1 and
              (.token | type == "string" and length <= 96 and test("^[A-Za-z0-9-]+$")) and
              .from_version == $baseline and
              .version == $target and
              .sha256 == $target_sha and
              (.install_root == "system_applications" or .install_root == "user_applications") and
              .phase == $phase
            ' "$journal" >/dev/null
            app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")"
            if [[ "$app_version" != "$expected_app_version" ]]; then
                echo "Installed app version does not match the exact M22 stage" >&2
                exit 67
            fi
            signature="$(codesign --display --verbose=4 "$app_path" 2>&1)"
            installed_cdhash="$(sed -n 's/^CDHash=//p' <<<"$signature" | head -n 1 | tr '[:upper:]' '[:lower:]')"
            if [[ "$installed_cdhash" != "$expected_cdhash" ]]; then
                echo "Installed app CDHash does not match the exact M22 candidate" >&2
                exit 67
            fi
            journal_token="$(jq -r '.token' "$journal")"
            case "$process_role" in
                baseline_app|target_app)
                    if [[ "$command_line" != "$binary" ]]; then
                        echo "M22 stage requires the exact plain app process role" >&2
                        exit 67
                    fi
                    ;;
                update_helper)
                    if [[ "$command_line" != "$binary --wrenflow-update-helper "* ]]; then
                        echo "Swapped stage requires the exact update-helper process" >&2
                        exit 67
                    fi
                    helper_arguments="${command_line#"$binary --wrenflow-update-helper "}"
                    read -r helper_parent helper_token helper_extra <<<"$helper_arguments"
                    if [[ ! "$helper_parent" =~ ^[1-9][0-9]*$ || \
                          "$helper_token" != "$journal_token" || -n "${helper_extra:-}" ]]; then
                        echo "Update-helper arguments do not match the retained journal" >&2
                        exit 67
                    fi
                    ;;
            esac
            process_state="$(ps -p "$pid" -o state= | tr -d '[:space:]')"
            if [[ "$process_state" != *T* ]]; then
                echo "M22 PID must be externally SIGSTOPed before evidence capture" >&2
                exit 67
            fi
            /usr/bin/install -m 600 "$journal" "$journal_evidence"
            journal_sha="$(shasum -a 256 "$journal_evidence" | awk '{print $1}')"
            plan_sha="$(shasum -a 256 "$plan" | awk '{print $1}')"
            /bin/kill -KILL "$pid"
            jq -S -n \
                --arg stage "$stage" \
                --arg plan_sha "$plan_sha" \
                --arg journal_sha "$journal_sha" \
                --arg journal_phase "$expected_phase" \
                --arg app_version "$app_version" \
                --arg process_role "$process_role" '
              {
                schema_version: 1,
                stage: $stage,
                signal: "SIGKILL",
                candidate_plan_sha256: $plan_sha,
                journal_sha256: $journal_sha,
                journal_phase: $journal_phase,
                app_version: $app_version,
                process_role: $process_role,
                pre_signal_state: "stopped",
                recovery_result: "pending_next_launch"
              }
            ' >"$output"
            ;;
        *)
            source_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
            /bin/kill -KILL "$pid"
            jq -S -n \
                --arg stage "$stage" \
                --arg source_commit "$source_commit" '
              {
                schema_version: 1,
                stage: $stage,
                signal: "SIGKILL",
                source_commit: $source_commit,
                recovery_result: "pending_next_launch"
              }
            ' >"$output"
            ;;
    esac
}

mode="${1:-automated}"
shift || true
case "$mode" in
    automated) automated_preflight "${1:-}" ;;
    candidate-plan) candidate_plan "${1:-}" ;;
    verify-evidence)
        [[ $# -eq 3 ]] || { usage; exit 64; }
        authenticate_candidate_plan "$2"
        mise exec -- python3 "$EVIDENCE_VERIFIER" verify "$1" "$2" "$3"
        ;;
    verify-post-promotion)
        [[ $# -eq 2 ]] || { usage; exit 64; }
        authenticate_candidate_plan "$1"
        mise exec -- python3 "$EVIDENCE_VERIFIER" verify-post-promotion "$1" "$2"
        ;;
    capture-hooks)
        [[ $# -eq 2 ]] || { usage; exit 64; }
        capture_hooks "$1" "$2"
        ;;
    kill-stage)
        [[ $# -eq 3 ]] || { usage; exit 64; }
        kill_stage "$1" "$2" "$3"
        ;;
    *) usage; exit 64 ;;
esac

#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CYCLES=20
DISPOSABLE_CONFIRMATION="me.gulya.wrenflow-gpui-v1-delete"

usage() {
    cat >&2 <<'USAGE'
Usage:
  gpui-endurance-preflight.sh automated [absolute-output-directory]
  gpui-endurance-preflight.sh candidate-plan <absolute-output-directory>
  gpui-endurance-preflight.sh capture-hooks <checkpoint> <absolute-output-json>
  gpui-endurance-preflight.sh kill-stage <stage> <pid> <absolute-output-json>

Candidate modes require WRENFLOW_CONFIRM_DISPOSABLE_ACCOUNT and an exact
WRENFLOW_TEST_APP. candidate-plan also requires WRENFLOW_TEST_DMG,
WRENFLOW_RELEASE_EVIDENCE and WRENFLOW_RELEASE_CHECKSUMS.
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

require_regular_input() {
    local input="$1"
    local label="$2"
    if [[ "$input" != /* || ! -f "$input" || -L "$input" ]]; then
        echo "$label must be an absolute, regular, non-symlink file" >&2
        exit 65
    fi
}

require_disposable_candidate_app() {
    local app_path="${WRENFLOW_TEST_APP:-}"
    if [[ "${WRENFLOW_CONFIRM_DISPOSABLE_ACCOUNT:-}" != "$DISPOSABLE_CONFIRMATION" ]]; then
        echo "Refusing candidate mutation outside an explicitly confirmed disposable account" >&2
        exit 67
    fi
    if [[ "$app_path" != /* || "$(basename "$app_path")" != "Wrenflow.app" || \
          ! -d "$app_path" || -L "$app_path" ]]; then
        echo "WRENFLOW_TEST_APP must be an exact absolute non-symlink Wrenflow.app" >&2
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
    output="$(require_output_directory "${1:-$REPO_DIR/build/gpui-endurance-preflight}")"
    log="$output/runtime-twenty-cycles.log"
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
    ) 2>&1 | tee "$log"

    local test_name
    for test_name in \
        "data_paths::tests::twenty_current_line_relaunches_preserve_only_gpui_v1_state" \
        "recovery::tests::twenty_interrupted_launches_clean_only_bounded_temporary_state" \
        "update::tests::twenty_channel_download_and_transaction_fault_cycles_fail_closed"; do
        rg -F "test $test_name ... ok" "$log" >/dev/null
    done

    jq -S -n \
        --arg source_commit "$source_commit" \
        --arg tree_state "$tree_state" \
        --argjson cycles "$CYCLES" \
        '{
          schema_version: 1,
          scope: "gpui-v1_disposable_runtime_preflight",
          source: {commit: $source_commit, tree_state: $tree_state},
          cycles: $cycles,
          automated: {
            current_line_relaunch: "passed",
            interrupted_recording_model_settings_update_cleanup: "passed",
            stable_beta_selection: "passed",
            partial_download_removal: "passed",
            staging_prepared_swapped_classification: "passed"
          },
          candidate: "blocked_pending_immutable_notarized_artifact",
          manual_candidate_rows: {
            M13: "pending",
            M14: "pending",
            M15: "pending",
            M16: "pending",
            M21: "pending_instruments_budget",
            M22: "pending"
          }
        }' >"$output/automated-preflight.json"

    echo "Automated disposable-root preflight passed; signed candidate rows remain pending"
    echo "$output/automated-preflight.json"
}

candidate_plan() {
    local output app_path dmg_path evidence checksums metadata_dir dmg_sha evidence_sha
    output="$(require_output_directory "${1:-}")"
    app_path="$(require_disposable_candidate_app)"
    dmg_path="${WRENFLOW_TEST_DMG:-}"
    evidence="${WRENFLOW_RELEASE_EVIDENCE:-}"
    checksums="${WRENFLOW_RELEASE_CHECKSUMS:-}"
    require_regular_input "$dmg_path" "WRENFLOW_TEST_DMG"
    require_regular_input "$evidence" "WRENFLOW_RELEASE_EVIDENCE"
    require_regular_input "$checksums" "WRENFLOW_RELEASE_CHECKSUMS"
    if [[ "$(basename "$dmg_path")" != "Wrenflow.dmg" || \
          "$(basename "$evidence")" != "release-evidence.json" || \
          "$(basename "$checksums")" != "SHA256SUMS" ]]; then
        echo "Candidate inputs must retain their exact published filenames" >&2
        exit 65
    fi
    metadata_dir="$(cd "$(dirname "$checksums")" && pwd)"
    if [[ "$(dirname "$dmg_path")" != "$metadata_dir" || \
          "$(dirname "$evidence")" != "$metadata_dir" ]]; then
        echo "Published DMG, evidence and checksum set must share one immutable directory" >&2
        exit 65
    fi
    (
        cd "$metadata_dir"
        shasum -a 256 -c SHA256SUMS
    )
    dmg_sha="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
    evidence_sha="$(jq -er '
        select(.schema_version == 1) |
        select(.source.repository == "IlyaGulya/wrenflow") |
        select(.source.commit | test("^[0-9a-f]{40}$")) |
        select(.notarization.status == "Accepted") |
        select(.identity.bundle_id == "me.gulya.wrenflow") |
        select(.identity.team_id == "T4LV8K9BGV") |
        .artifact.sha256 | select(test("^[0-9a-f]{64}$"))
    ' "$evidence")"
    if [[ "$dmg_sha" != "$evidence_sha" ]]; then
        echo "Candidate DMG does not match release-evidence.json" >&2
        exit 66
    fi
    "$REPO_DIR/scripts/verify-release-artifact.sh" \
        "$app_path" "$dmg_path" --require-notarized

    jq -S -n \
        --argjson release "$(jq -c '.release' "$evidence")" \
        --argjson source "$(jq -c '.source' "$evidence")" \
        --arg dmg_sha256 "$dmg_sha" \
        --argjson cycles "$CYCLES" \
        '{
          schema_version: 1,
          source: $source,
          release: $release,
          artifact: {name: "Wrenflow.dmg", sha256: $dmg_sha256},
          verification: "exact_notarized_candidate_passed",
          disposable_account_confirmed: true,
          cycles: $cycles,
          rows: {M13:"pending",M14:"pending",M15:"pending",M16:"pending",M21:"pending",M22:"pending"}
        }' >"$output/candidate-plan.json"
    echo "Candidate authenticity passed; no M13-M22 runtime row has been claimed"
}

capture_hooks() {
    local checkpoint="$1"
    local output="$2"
    local app_path binary process_count audio_node_count idle_sleep_assertion
    case "$checkpoint" in
        before|after_sleep_wake|after_lock_unlock|after_device_change|after_fault_recovery) ;;
        *) echo "Unknown privacy-safe hook checkpoint: $checkpoint" >&2; exit 64 ;;
    esac
    require_new_output_file "$output"
    app_path="$(require_disposable_candidate_app)"
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
    case "$stage" in
        recording|model_download|settings_write|update_staging|update_prepared|update_swapped) ;;
        *) echo "Unknown fault-injection stage: $stage" >&2; exit 64 ;;
    esac
    if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "Fault-injection PID must be explicit and numeric" >&2
        exit 64
    fi
    require_new_output_file "$output"
    app_path="$(require_disposable_candidate_app)"
    binary="$app_path/Contents/MacOS/wrenflow"
    command_line="$(ps -p "$pid" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "$command_line" != "$binary" && "$command_line" != "$binary "* ]]; then
        echo "PID does not belong to the exact candidate app" >&2
        exit 67
    fi
    source_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
    /bin/kill -KILL "$pid"
    jq -S -n \
        --arg stage "$stage" \
        --arg source_commit "$source_commit" \
        '{
          schema_version: 1,
          stage: $stage,
          signal: "SIGKILL",
          source_commit: $source_commit,
          recovery_result: "pending_next_launch"
        }' >"$output"
}

mode="${1:-automated}"
shift || true
case "$mode" in
    automated) automated_preflight "${1:-}" ;;
    candidate-plan) candidate_plan "${1:-}" ;;
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

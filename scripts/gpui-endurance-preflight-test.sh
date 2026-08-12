#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-endurance-harness-test.XXXXXX")"
trap 'rm -rf -- "$FIXTURE"' EXIT

OUTPUT="$FIXTURE/output"
"$REPO_DIR/scripts/gpui-endurance-preflight.sh" automated "$OUTPUT"
jq -e '
    . as $root |
    .schema_version == 1 and
    .contract == "wrenflow.gpui.endurance.update-evidence.v1" and
    .cycles == 20 and
    (.source.commit | test("^[0-9a-f]{40}$")) and
    (.source.update_source_sha256 | test("^[0-9a-f]{64}$")) and
    (.source.verifier_source_sha256 | test("^[0-9a-f]{64}$")) and
    (.source.policy_sha256 | test("^[0-9a-f]{64}$")) and
    .automated_update_fixtures.status == "passed" and
    .automated_update_fixtures.log.file == "runtime-twenty-cycles.log" and
    (.automated_update_fixtures.log.sha256 | test("^[0-9a-f]{64}$")) and
    ([.automated_update_fixtures.cases[].id] == [
      "stable_beta_channel_selection",
      "offline",
      "rate_limit",
      "malformed_metadata",
      "duplicate_release",
      "partial_transfer",
      "transaction_recovery_cycles"
    ]) and
    all(.automated_update_fixtures.cases[];
      .status == "passed" and
      .source_sha256 == $root.source.update_source_sha256 and
      .log_sha256 == $root.automated_update_fixtures.log.sha256) and
    .other_automated.current_line_relaunch.status == "passed" and
    .other_automated.current_line_relaunch.id == "current_line_relaunch" and
    .other_automated.current_line_relaunch.test == "data_paths::tests::twenty_current_line_relaunches_preserve_only_gpui_v1_state" and
    .other_automated.current_line_relaunch.log_sha256 == .automated_update_fixtures.log.sha256 and
    (.other_automated.current_line_relaunch.source_sha256 | test("^[0-9a-f]{64}$")) and
    .other_automated.interrupted_write_cleanup.status == "passed" and
    .other_automated.interrupted_write_cleanup.id == "interrupted_write_cleanup" and
    .other_automated.interrupted_write_cleanup.test == "recovery::tests::twenty_interrupted_launches_clean_only_bounded_temporary_state" and
    .other_automated.interrupted_write_cleanup.log_sha256 == .automated_update_fixtures.log.sha256 and
    (.other_automated.interrupted_write_cleanup.source_sha256 | test("^[0-9a-f]{64}$")) and
    .candidate == "blocked_pending_immutable_notarized_artifacts" and
    .manual_candidate_rows.M13 == "pending_signed_manual" and
    .manual_candidate_rows.M21 == "pending_instruments_budget" and
    .manual_candidate_rows.M22 == "pending_signed_manual"
' "$OUTPUT/automated-preflight.json" >/dev/null
[[ "$(shasum -a 256 "$OUTPUT/runtime-twenty-cycles.log" | awk '{print $1}')" == \
    "$(jq -r '.automated_update_fixtures.log.sha256' "$OUTPUT/automated-preflight.json")" ]]

if "$REPO_DIR/scripts/gpui-endurance-preflight.sh" automated "$OUTPUT" \
    >"$FIXTURE/overwrite.stdout" 2>"$FIXTURE/overwrite.stderr"; then
    echo "automated preflight overwrote retained evidence" >&2
    exit 1
fi
rg -F "Evidence file must be a new absolute path" "$FIXTURE/overwrite.stderr" >/dev/null

mise exec -- python3 "$REPO_DIR/scripts/gpui-endurance-evidence.py" source >/dev/null
mise exec -- python3 "$REPO_DIR/scripts/gpui-endurance-evidence.py" test-fixtures >/dev/null

expect_missing_payload_rejected() {
    local label="$1"
    local missing_variable="$2"
    local candidate_output="$3"
    shift 3
    if "$@" /bin/bash "$REPO_DIR/scripts/gpui-endurance-preflight.sh" \
        candidate-plan "$candidate_output" \
        >"$FIXTURE/$label.stdout" 2>"$FIXTURE/$label.stderr"; then
        echo "candidate-plan accepted missing exact payload input: $missing_variable" >&2
        exit 1
    fi
    rg -F "$missing_variable" "$FIXTURE/$label.stderr" >/dev/null
    [[ ! -e "$candidate_output" ]]
}

expect_missing_payload_rejected \
    candidate-missing-both WRENFLOW_BASELINE_PAYLOAD "$FIXTURE/candidate-missing-both" \
    env -u WRENFLOW_BASELINE_PAYLOAD -u WRENFLOW_TARGET_PAYLOAD
expect_missing_payload_rejected \
    candidate-missing-baseline WRENFLOW_BASELINE_PAYLOAD "$FIXTURE/candidate-missing-baseline" \
    env -u WRENFLOW_BASELINE_PAYLOAD \
    WRENFLOW_TARGET_PAYLOAD="$FIXTURE/nonexistent-target-payload"
expect_missing_payload_rejected \
    candidate-missing-target WRENFLOW_TARGET_PAYLOAD "$FIXTURE/candidate-missing-target" \
    env -u WRENFLOW_TARGET_PAYLOAD \
    WRENFLOW_BASELINE_PAYLOAD="$FIXTURE/nonexistent-baseline-payload"

AUTH_PLAN="$REPO_DIR/scripts/fixtures/endurance/candidate-plan-pass.json"
AUTH_TEMP="$FIXTURE/auth-temp"
mkdir "$AUTH_TEMP"
if env -u WRENFLOW_BASELINE_PAYLOAD \
    WRENFLOW_TARGET_PAYLOAD="$FIXTURE/nonexistent-target-payload" \
    TMPDIR="$AUTH_TEMP" \
    /bin/bash "$REPO_DIR/scripts/gpui-endurance-preflight.sh" verify-evidence \
    "$FIXTURE/nonexistent-automated.json" "$AUTH_PLAN" "$FIXTURE/nonexistent-manifest.json" \
    >"$FIXTURE/auth-missing-baseline.stdout" \
    2>"$FIXTURE/auth-missing-baseline.stderr"; then
    echo "verify-evidence accepted missing WRENFLOW_BASELINE_PAYLOAD" >&2
    exit 1
fi
rg -F "WRENFLOW_BASELINE_PAYLOAD" "$FIXTURE/auth-missing-baseline.stderr" >/dev/null
[[ -z "$(find "$AUTH_TEMP" -mindepth 1 -print -quit)" ]]

if env -u WRENFLOW_TARGET_PAYLOAD \
    WRENFLOW_BASELINE_PAYLOAD="$FIXTURE/nonexistent-baseline-payload" \
    TMPDIR="$AUTH_TEMP" \
    /bin/bash "$REPO_DIR/scripts/gpui-endurance-preflight.sh" verify-post-promotion \
    "$AUTH_PLAN" "$FIXTURE/nonexistent-observation.json" \
    >"$FIXTURE/auth-missing-target.stdout" \
    2>"$FIXTURE/auth-missing-target.stderr"; then
    echo "verify-post-promotion accepted missing WRENFLOW_TARGET_PAYLOAD" >&2
    exit 1
fi
rg -F "WRENFLOW_TARGET_PAYLOAD" "$FIXTURE/auth-missing-target.stderr" >/dev/null
[[ -z "$(find "$AUTH_TEMP" -mindepth 1 -print -quit)" ]]

if "$REPO_DIR/scripts/gpui-endurance-preflight.sh" kill-stage hostile "$$" \
    "$FIXTURE/kill.json" >"$FIXTURE/kill.stdout" 2>"$FIXTURE/kill.stderr"; then
    echo "kill-stage accepted a non-allowlisted stage" >&2
    exit 1
fi
rg -F "Unknown fault-injection stage" "$FIXTURE/kill.stderr" >/dev/null

ALIAS="$FIXTURE/aliased-evidence.json"
if WRENFLOW_JOURNAL_EVIDENCE="$ALIAS" \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh" kill-stage update_staging 999999 "$ALIAS" \
    >"$FIXTURE/alias.stdout" 2>"$FIXTURE/alias.stderr"; then
    echo "kill-stage accepted aliased journal/SIGKILL output" >&2
    exit 1
fi
rg -F "must be distinct new files" "$FIXTURE/alias.stderr" >/dev/null
[[ ! -e "$ALIAS" ]]

rg -F 'WRENFLOW_ENDURANCE_DISPOSABLE_ROOT' \
    "$REPO_DIR/core/wrenflow-runtime/src/data_paths.rs" \
    "$REPO_DIR/core/wrenflow-runtime/src/recovery.rs" \
    "$REPO_DIR/core/wrenflow-runtime/src/update.rs" >/dev/null
rg -F 'blocked_pending_immutable_notarized_artifacts' \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh" >/dev/null
rg -F 'scripts/verify-release-artifact.sh' \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh" >/dev/null
for required_contract in \
    'WRENFLOW_BASELINE_PAYLOAD' \
    'WRENFLOW_TARGET_PAYLOAD' \
    'WRENFLOW_M13_M22_PLAN' \
    'WRENFLOW_UPDATE_JOURNAL' \
    'WRENFLOW_JOURNAL_EVIDENCE' \
    'before_ready_finalization' \
    'update_helper' \
    'pre_signal_state' \
    'externally SIGSTOPed' \
    'authenticate_candidate_plan' \
    'hdiutil attach -readonly -nobrowse' \
    'candidate_plan_sha256' \
    'journal_sha256'; do
    rg -F "$required_contract" "$REPO_DIR/scripts/gpui-endurance-preflight.sh" >/dev/null
done
if rg -n 'WRENFLOW_(BASELINE|TARGET)_APP|WRENFLOW_(BASELINE|TARGET)_DMG' \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh"; then
    echo "candidate identity must be derived from the mounted payload DMGs" >&2
    exit 1
fi
if rg -n 'mise run (build|run)|open -[an]?|open "?\$' \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh"; then
    echo "endurance harness must not rebuild, install or launch a candidate implicitly" >&2
    exit 1
fi

echo "GPUI endurance preflight harness source and failure behavior passed"

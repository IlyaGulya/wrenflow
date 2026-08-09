#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-endurance-harness-test.XXXXXX")"
trap 'rm -rf -- "$FIXTURE"' EXIT

OUTPUT="$FIXTURE/output"
"$REPO_DIR/scripts/gpui-endurance-preflight.sh" automated "$OUTPUT"
jq -e '
    .schema_version == 1 and
    .cycles == 20 and
    .automated.current_line_relaunch == "passed" and
    .automated.interrupted_recording_model_settings_update_cleanup == "passed" and
    .automated.stable_beta_selection == "passed" and
    .candidate == "blocked_pending_immutable_notarized_artifact" and
    .manual_candidate_rows.M13 == "pending" and
    .manual_candidate_rows.M21 == "pending_instruments_budget" and
    .manual_candidate_rows.M22 == "pending"
' "$OUTPUT/automated-preflight.json" >/dev/null

if "$REPO_DIR/scripts/gpui-endurance-preflight.sh" candidate-plan "$FIXTURE/candidate" \
    >"$FIXTURE/candidate.stdout" 2>"$FIXTURE/candidate.stderr"; then
    echo "candidate-plan accepted missing disposable-account/candidate inputs" >&2
    exit 1
fi
rg -F "explicitly confirmed disposable account" "$FIXTURE/candidate.stderr" >/dev/null

if "$REPO_DIR/scripts/gpui-endurance-preflight.sh" kill-stage hostile "$$" \
    "$FIXTURE/kill.json" >"$FIXTURE/kill.stdout" 2>"$FIXTURE/kill.stderr"; then
    echo "kill-stage accepted a non-allowlisted stage" >&2
    exit 1
fi
rg -F "Unknown fault-injection stage" "$FIXTURE/kill.stderr" >/dev/null

rg -F 'WRENFLOW_ENDURANCE_DISPOSABLE_ROOT' \
    "$REPO_DIR/core/wrenflow-runtime/src/data_paths.rs" \
    "$REPO_DIR/core/wrenflow-runtime/src/recovery.rs" \
    "$REPO_DIR/core/wrenflow-runtime/src/update.rs" >/dev/null
rg -F 'blocked_pending_immutable_notarized_artifact' \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh" >/dev/null
rg -F 'scripts/verify-release-artifact.sh' \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh" >/dev/null
if rg -n 'mise run (build|run)|open -[an]?|open "?\$' \
    "$REPO_DIR/scripts/gpui-endurance-preflight.sh"; then
    echo "endurance harness must not rebuild, install or launch a candidate implicitly" >&2
    exit 1
fi

echo "GPUI endurance preflight harness source and failure behavior passed"

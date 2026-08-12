#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$REPO_DIR/scripts/gpui-endurance-evidence.py"
HARNESS="$REPO_DIR/scripts/gpui-endurance-preflight.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-first-release-lifecycle.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

mise exec -- python3 "$TOOL" source >"$TEST_ROOT/source.out"
rg -F "First-release lifecycle source contract passed" "$TEST_ROOT/source.out" >/dev/null
"$HARNESS" source >/dev/null

if env -u WRENFLOW_TARGET_PAYLOAD "$HARNESS" candidate-plan "$TEST_ROOT/missing.json" \
    >"$TEST_ROOT/missing.out" 2>"$TEST_ROOT/missing.err"; then
    echo "candidate-plan accepted missing exact stable payload" >&2
    exit 1
fi
rg -F "WRENFLOW_TARGET_PAYLOAD" "$TEST_ROOT/missing.err" >/dev/null
[[ ! -e "$TEST_ROOT/missing.json" ]]

SOURCE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DMG="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
BETA_SOURCE="d3e01e0ec085121f3bd3e78038836a16608b98a0"
BETA_DMG="d7a04beb4513026dda7f72847ab2c53a5c1a82861b49192c7c6ae6937b35e1a5"
BETA_EXECUTABLE="3a2d786a31ac6491a88d3a3f9fa8b9d66f4991f5f5d32e507c0db3caf6f573af"
jq -S -n --arg source "$SOURCE" --arg dmg "$DMG" '
  {
    schema_version:1,
    contract:"wrenflow.gpui.first-release-lifecycle.v1",
    verification:"exact_signed_notarized_private_stable_draft",
    candidate:{
      tag:"v0.4.0",version:"0.4.0",build_number:"1",source_commit:$source,
      dmg_sha256:$dmg,team_id:"T4LV8K9BGV",bundle_id:"me.gulya.wrenflow"
    }
  }
' >"$TEST_ROOT/plan.json"
mise exec -- python3 "$TOOL" validate-plan "$TEST_ROOT/plan.json" >/dev/null

EVIDENCE="$TEST_ROOT/evidence"
mkdir "$EVIDENCE"
printf 'owner lifecycle pass\n' >"$EVIDENCE/lifecycle-result.txt"
printf 'sleep wake and audio device recovered\n' >"$EVIDENCE/lifecycle-log.txt"
printf 'owner disposable-state pass\n' >"$EVIDENCE/state-result.txt"
printf 'current-format corrupt state failed closed and explicit disposable reset passed\n' \
    >"$EVIDENCE/disposable-state-log.txt"
mise exec -- python3 \
    "$REPO_DIR/scripts/fixtures/performance/generate-hybrid-verifier-fixture.py" \
    "$REPO_DIR/support/performance/budgets-v1.json" \
    "$EVIDENCE/constrained-evidence.json" "$TEST_ROOT/unused-physical.json"
mise exec -- python3 - \
    "$BETA_SOURCE" "$BETA_DMG" "$BETA_EXECUTABLE" \
    "$EVIDENCE/constrained-evidence.json" <<'PY'
import hashlib
import json
import pathlib
import sys

source, dmg, executable, output = sys.argv[1], sys.argv[2], sys.argv[3], pathlib.Path(sys.argv[4])
value = json.loads(output.read_text(encoding="utf-8"))
value["source"]["commit"] = source
value["candidate"]["bundle_version"] = "0.4.0-beta.64"
value["candidate"]["bundle_build"] = "305"
value["candidate"]["executable_sha256"] = executable
value["candidate_id"] = f"{source}-{dmg}"
value.pop("evidence_sha256", None)
encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
value["evidence_sha256"] = hashlib.sha256(encoded).hexdigest()
output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
mise exec -- python3 "$REPO_DIR/scripts/perf/gpui-performance.py" verify \
    --profile release \
    --result "$EVIDENCE/constrained-evidence.json" \
    --budgets "$REPO_DIR/support/performance/budgets-v1.json" \
    --report "$EVIDENCE/constrained-verification.json" >/dev/null

descriptor() {
    local kind="$1"
    local file="$2"
    jq -n --arg kind "$kind" --arg path "$file" \
        --arg sha "$(shasum -a 256 "$EVIDENCE/$file" | awk '{print $1}')" \
        '{kind:$kind,relative_path:$path,sha256:$sha}'
}

jq -S -n \
    --slurpfile plan "$TEST_ROOT/plan.json" \
    --argjson l01_result "$(descriptor result-sheet lifecycle-result.txt)" \
    --argjson l01_log "$(descriptor lifecycle-log lifecycle-log.txt)" \
    --argjson l02_result "$(descriptor result-sheet state-result.txt)" \
    --argjson l02_log "$(descriptor disposable-state-log disposable-state-log.txt)" \
    --argjson l03_result "$(descriptor performance-result constrained-evidence.json)" \
    --argjson l03_report "$(descriptor performance-report constrained-verification.json)" '
  {
    schema_version:1,
    contract:"wrenflow.gpui.first-release-lifecycle.v1",
    candidate:$plan[0].candidate,
    owner:"Ilya Gulya",
    executed_at:"2026-08-12T12:00:00+06:00",
    tcc_mutated:false,
    rows:{
      L01:{
        title:"Owner sleep, wake and audio-device lifecycle smoke",
        result:"pass",notes:"Owner observed one exact process recover.",
        evidence:[$l01_result,$l01_log]
      },
      L02:{
        title:"Disposable current-format corruption and explicit reset smoke",
        result:"pass",notes:"Only a disposable data root was used.",
        evidence:[$l02_result,$l02_log]
      },
      L03:{
        title:"Frozen beta.64 sealed automated performance baseline reuse",
        result:"pass",notes:"Release verifier recomputed the frozen beta.64 baseline at 24 of 24 metrics.",
        evidence:[$l03_result,$l03_report]
      }
    },
    decision:"passed_first_release_lifecycle"
  }
' >"$TEST_ROOT/manifest.json"

"$HARNESS" verify-evidence "$TEST_ROOT/plan.json" "$TEST_ROOT/manifest.json" "$EVIDENCE" \
    >"$TEST_ROOT/pass.out"
rg -F "passed for v0.4.0" "$TEST_ROOT/pass.out" >/dev/null

expect_failure() {
    local name="$1"
    local filter="$2"
    local expected="$3"
    jq "$filter" "$TEST_ROOT/manifest.json" >"$TEST_ROOT/$name.json"
    if "$HARNESS" verify-evidence "$TEST_ROOT/plan.json" "$TEST_ROOT/$name.json" "$EVIDENCE" \
        >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err"; then
        echo "lifecycle verifier accepted $name" >&2
        exit 1
    fi
    rg -F "$expected" "$TEST_ROOT/$name.err" >/dev/null
}

expect_failure pending '.rows.L01.result="pending"' "not an exact passing policy row"
expect_failure tcc-reset '.tcc_mutated=true' "without TCC mutation"
expect_failure missing-row 'del(.rows.L02)' "ordered exactly L01,L02,L03"
expect_failure legacy-row '.rows.M13=.rows.L01' "ordered exactly L01,L02,L03"
expect_failure report-count '.rows.L03.evidence[1].sha256=("0"*64)' "evidence hash mismatch"
expect_failure extra-field '.rows.L01.legacy_migration="passed"' "unknown ['legacy_migration']"

cp "$EVIDENCE/constrained-evidence.json" "$TEST_ROOT/constrained-evidence.original.json"
expect_invalid_performance() {
    local name="$1"
    local filter="$2"
    local expected="${3:-did not recompute as an exact passing release result}"
    jq "$filter | del(.evidence_sha256)" "$TEST_ROOT/constrained-evidence.original.json" \
        >"$EVIDENCE/constrained-evidence.json"
    mise exec -- python3 - "$EVIDENCE/constrained-evidence.json" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
value["evidence_sha256"] = hashlib.sha256(encoded).hexdigest()
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    jq --arg sha "$(shasum -a 256 "$EVIDENCE/constrained-evidence.json" | awk '{print $1}')" \
        '.rows.L03.evidence[0].sha256=$sha' "$TEST_ROOT/manifest.json" \
        >"$TEST_ROOT/$name.json"
    if "$HARNESS" verify-evidence "$TEST_ROOT/plan.json" "$TEST_ROOT/$name.json" "$EVIDENCE" \
        >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err"; then
        echo "lifecycle verifier accepted $name performance evidence" >&2
        exit 1
    fi
    rg -F "$expected" "$TEST_ROOT/$name.err" >/dev/null
}
expect_invalid_performance missing-performance-metrics 'del(.metrics)'
expect_invalid_performance tampered-performance-metric '.metrics["launch.cold.p95_ms"].value=9999'
expect_invalid_performance wrong-performance-candidate-id \
    '.candidate_id=("f"*40 + "-" + "e"*64)' \
    'candidate_id differs from the frozen beta.64 DMG'
cp "$TEST_ROOT/constrained-evidence.original.json" "$EVIDENCE/constrained-evidence.json"

cp "$TEST_ROOT/manifest.json" "$TEST_ROOT/symlink-manifest.json"
ln -s constrained-evidence.json "$EVIDENCE/result-link.json"
jq --arg sha "$(shasum -a 256 "$EVIDENCE/constrained-evidence.json" | awk '{print $1}')" '
  .rows.L03.evidence[0].relative_path="result-link.json" |
  .rows.L03.evidence[0].sha256=$sha
' "$TEST_ROOT/manifest.json" >"$TEST_ROOT/symlink-manifest.json"
if "$HARNESS" verify-evidence "$TEST_ROOT/plan.json" "$TEST_ROOT/symlink-manifest.json" "$EVIDENCE" \
    >"$TEST_ROOT/symlink.out" 2>"$TEST_ROOT/symlink.err"; then
    echo "lifecycle verifier accepted symlinked evidence" >&2
    exit 1
fi
rg -F "must not traverse a symlink" "$TEST_ROOT/symlink.err" >/dev/null

rg -F 'legacy_migration": "excluded"' "$REPO_DIR/support/acceptance/endurance-v1-policy.json" >/dev/null
rg -F 'updater_transaction_fault_injection' "$REPO_DIR/support/acceptance/endurance-v1-policy.json" >/dev/null
if rg -n 'tccutil|kill-stage|WRENFLOW_BASELINE_PAYLOAD|WRENFLOW_M13_M22_PLAN' "$HARNESS"; then
    echo "first-release lifecycle harness retained destructive or legacy/update execution" >&2
    exit 1
fi

echo "First-release lifecycle evidence tests passed"

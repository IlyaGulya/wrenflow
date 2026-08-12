#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERIFIER="$REPO_DIR/scripts/gpui-endurance-evidence.py"
CONTRACT="wrenflow.gpui.first-release-lifecycle.v1"

usage() {
    cat >&2 <<'USAGE'
Usage:
  gpui-endurance-preflight.sh source
  gpui-endurance-preflight.sh candidate-plan <absolute-new-plan.json>
  gpui-endurance-preflight.sh verify-evidence <absolute-plan.json> <absolute-manifest.json> <absolute-evidence-root>

candidate-plan requires WRENFLOW_TARGET_PAYLOAD to name one exact signed,
notarized, private stable nine-asset payload. No command launches Wrenflow,
changes TCC, or mutates application/user data.
USAGE
}

regular_input() {
    local path="$1"
    local label="$2"
    if [[ "$path" != /* || ! -f "$path" || -L "$path" ]]; then
        echo "$label must be an absolute regular non-symlink file" >&2
        exit 64
    fi
}

candidate_plan() {
    local output="$1"
    local payload="${WRENFLOW_TARGET_PAYLOAD:-}"
    local parent temporary candidate
    if [[ -z "$payload" || "$payload" != /* || ! -d "$payload" || -L "$payload" ]]; then
        echo "WRENFLOW_TARGET_PAYLOAD must name an absolute exact payload directory" >&2
        exit 64
    fi
    if [[ "$output" != /* || -e "$output" || -L "$output" ]]; then
        echo "Candidate plan output must be a new absolute non-symlink path" >&2
        exit 64
    fi
    parent="$(dirname "$output")"
    if [[ ! -d "$parent" || -L "$parent" ]]; then
        echo "Candidate plan parent must be an existing non-symlink directory" >&2
        exit 64
    fi
    temporary="$(mktemp "$parent/.first-release-plan.XXXXXX")"
    trap 'rm -f -- "${temporary:-}"' EXIT
    candidate="$(mise exec -- python3 "$REPO_DIR/scripts/gpui-human-acceptance.py" \
        verify-candidate --candidate-dir "$payload")"
    if [[ "$(jq -r '.version | contains("-")' <<<"$candidate")" != "false" ]]; then
        echo "First-release lifecycle requires the exact private stable draft, not a prerelease" >&2
        exit 65
    fi
    jq -S -n --arg contract "$CONTRACT" --argjson candidate "$candidate" '
      {
        schema_version: 1,
        contract: $contract,
        verification: "exact_signed_notarized_private_stable_draft",
        candidate: ($candidate | {
          tag,version,build_number,source_commit,dmg_sha256,team_id,bundle_id
        })
      }
    ' >"$temporary"
    mise exec -- python3 "$VERIFIER" validate-plan "$temporary" >/dev/null
    /usr/bin/install -m 600 "$temporary" "$output"
    rm -f -- "$temporary"
    trap - EXIT
    echo "First-release lifecycle candidate plan created: $output"
}

case "${1:-}" in
    source)
        [[ $# -eq 1 ]] || { usage; exit 64; }
        mise exec -- python3 "$VERIFIER" source
        ;;
    candidate-plan)
        [[ $# -eq 2 ]] || { usage; exit 64; }
        candidate_plan "$2"
        ;;
    verify-evidence)
        [[ $# -eq 4 ]] || { usage; exit 64; }
        regular_input "$2" "candidate plan"
        regular_input "$3" "lifecycle manifest"
        mise exec -- python3 "$VERIFIER" verify "$2" "$3" "$4"
        ;;
    *)
        usage
        exit 64
        ;;
esac

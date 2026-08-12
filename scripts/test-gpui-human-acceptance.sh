#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$REPO_DIR/scripts/gpui-human-acceptance.py"
FIXTURES="$REPO_DIR/scripts/fixtures/acceptance"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-human-acceptance-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

CANDIDATE="$TEST_ROOT/candidate"
EVIDENCE="$TEST_ROOT/evidence"
mkdir -p "$CANDIDATE" "$EVIDENCE"

SOURCE_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TAG="v0.4.0-beta.1"
VERSION="0.4.0-beta.1"
ARTIFACT_URL="https://github.com/IlyaGulya/wrenflow/releases/download/$TAG/Wrenflow.dmg"

printf 'immutable candidate fixture\n' >"$CANDIDATE/Wrenflow.dmg"
printf '{"bomFormat":"CycloneDX","specVersion":"1.6"}\n' >"$CANDIDATE/Wrenflow.cdx.json"
printf 'fixture license inventory\n' >"$CANDIDATE/RustThirdPartyLicenses.txt"
printf '{"schema_version":1,"fixture":"pins"}\n' >"$CANDIDATE/pins.json"
printf '{"schema_version":1,"exceptions":[]}\n' >"$CANDIDATE/exceptions.json"
DMG_SHA="$(shasum -a 256 "$CANDIDATE/Wrenflow.dmg" | awk '{print $1}')"
PINS_SHA="$(shasum -a 256 "$CANDIDATE/pins.json" | awk '{print $1}')"
jq -S -n \
    --arg source "$SOURCE_COMMIT" \
    --arg pins_sha "$PINS_SHA" '
  {
    predicateType:"https://slsa.dev/provenance/v1",
    buildDefinition:{
      buildType:"https://github.com/ilyagulya/wrenflow/build-types/macos-gpui-v1",
      externalParameters:{target:"aarch64-apple-darwin",locked:true},
      internalParameters:{sourceDateEpoch:1},
      resolvedDependencies:[
        {uri:"git+https://github.com/ilyagulya/wrenflow",digest:{gitCommit:$source}},
        {uri:"file:Cargo.lock",digest:{sha256:("e" * 64)}},
        {uri:"file:native/wrenflow-gpui/Cargo.lock",digest:{sha256:("f" * 64)}},
        {uri:"file:supply-chain/pins.json",digest:{sha256:$pins_sha}}
      ]
    },
    runDetails:{
      builder:{id:"mise://wrenflow/release"},
      metadata:{invocationId:$source}
    }
  }
' >"$CANDIDATE/provenance.json"
jq -S -n \
    --arg source "$SOURCE_COMMIT" \
    --arg tag "$TAG" \
    --arg version "$VERSION" \
    --arg dmg_sha "$DMG_SHA" '
  {
    schema_version:1,
    source:{repository:"IlyaGulya/wrenflow",commit:$source},
    workflow:{run_id:"1",attempt:"1",url:"https://github.com/IlyaGulya/wrenflow/actions/runs/1/attempts/1"},
    release:{tag:$tag,version:$version,build_number:"1"},
    notarization:{submission_id:"00000000-0000-0000-0000-000000000000",status:"Accepted"},
    identity:{bundle_id:"me.gulya.wrenflow",team_id:"T4LV8K9BGV"},
    artifact:{name:"Wrenflow.dmg",sha256:$dmg_sha}
  }
' >"$CANDIDATE/release-evidence.json"
jq -S -n \
    --arg source "$SOURCE_COMMIT" \
    --arg dmg_sha "$DMG_SHA" \
    --arg pins_sha "$PINS_SHA" '
  {
    _type:"https://in-toto.io/Statement/v1",
    subject:[
      {name:"Wrenflow.app/Contents/MacOS/wrenflow",digest:{sha256:("b" * 64)}},
      {name:"Wrenflow.app/Contents/Frameworks/libWrenflowShell.dylib",digest:{sha256:("c" * 64)}},
      {name:"Wrenflow.app/Contents/MacOS/libonnxruntime.dylib",digest:{sha256:("d" * 64)}},
      {name:"Wrenflow.dmg",digest:{sha256:$dmg_sha}}
    ],
    predicateType:"https://slsa.dev/provenance/v1",
    predicate:{
      buildDefinition:{
        buildType:"https://github.com/ilyagulya/wrenflow/build-types/macos-gpui-v1",
        externalParameters:{target:"aarch64-apple-darwin",locked:true},
        internalParameters:{sourceDateEpoch:1},
        resolvedDependencies:[
          {uri:"git+https://github.com/ilyagulya/wrenflow",digest:{gitCommit:$source}},
          {uri:"file:Cargo.lock",digest:{sha256:("e" * 64)}},
          {uri:"file:native/wrenflow-gpui/Cargo.lock",digest:{sha256:("f" * 64)}},
          {uri:"file:supply-chain/pins.json",digest:{sha256:$pins_sha}}
        ]
      },
      runDetails:{
        builder:{id:"mise://wrenflow/release"},
        metadata:{
          invocationId:$source,
          workflowRun:"https://github.com/IlyaGulya/wrenflow/actions/runs/1/attempts/1",
          notarySubmissionId:"00000000-0000-0000-0000-000000000000"
        }
      }
    }
  }
' >"$CANDIDATE/artifact-provenance.json"
(
    cd "$CANDIDATE"
    shasum -a 256 Wrenflow.dmg Wrenflow.cdx.json RustThirdPartyLicenses.txt \
        pins.json exceptions.json provenance.json artifact-provenance.json \
        release-evidence.json >SHA256SUMS
)

mise exec -- python3 "$TOOL" verify-candidate \
    --candidate-dir "$CANDIDATE" >"$TEST_ROOT/candidate.out"
rg -F '"tag":"v0.4.0-beta.1"' "$TEST_ROOT/candidate.out" >/dev/null

DUPLICATE_PAYLOAD="$TEST_ROOT/candidate-duplicate-release-key"
cp -R "$CANDIDATE" "$DUPLICATE_PAYLOAD"
mise exec -- python3 - "$DUPLICATE_PAYLOAD/release-evidence.json" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
needle = '  "schema_version": 1,'
if needle not in content:
    raise SystemExit("release-evidence fixture shape drifted")
path.write_text(content.replace(needle, f"{needle}\n{needle}", 1), encoding="utf-8")
PY
(
    cd "$DUPLICATE_PAYLOAD"
    shasum -a 256 Wrenflow.dmg Wrenflow.cdx.json RustThirdPartyLicenses.txt \
        pins.json exceptions.json provenance.json artifact-provenance.json \
        release-evidence.json >SHA256SUMS
)
if mise exec -- python3 "$TOOL" verify-candidate \
    --candidate-dir "$DUPLICATE_PAYLOAD" \
    >"$TEST_ROOT/candidate-duplicate.out" \
    2>"$TEST_ROOT/candidate-duplicate.err"; then
    echo "Candidate verifier accepted duplicate release-evidence key" >&2
    exit 1
fi
rg -F "duplicate JSON key: schema_version" \
    "$TEST_ROOT/candidate-duplicate.err" >/dev/null

jq -S -n '
  {
    tester:{name:"Ilya Gulya",role:"release owner"},
    machine:{model:"MacBookPro18,4",chip:"Apple M1 Max",memory_gib:64},
    macos:{version:"26.5.1",build:"25F90"},
    displays:[{
      name:"Built-in Retina",
      pixel_resolution:"3024x1964",
      logical_resolution:"1512x982",
      scale:2
    }]
  }
' >"$TEST_ROOT/context.json"

for kind in \
    accessibility-summary artifact-verification automated-gate display-metadata \
    permission-status result-sheet screen-recording screenshots; do
    printf '%s retained fixture\n' "$kind" >"$EVIDENCE/$kind.txt"
done

PENDING="$TEST_ROOT/pending.json"
mise exec -- python3 "$TOOL" init \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --context "$TEST_ROOT/context.json" \
    --artifact-url "$ARTIFACT_URL" \
    --output "$PENDING"

mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$PENDING" \
    --allow-pending >"$TEST_ROOT/pending.out"
rg -F "structurally valid but incomplete" "$TEST_ROOT/pending.out" >/dev/null

if mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$PENDING" \
    >"$TEST_ROOT/pending-final.out" 2>"$TEST_ROOT/pending-final.err"; then
    echo "Final verifier accepted pending human rows" >&2
    exit 1
fi
rg -F "final acceptance requires every row to pass" "$TEST_ROOT/pending-final.err" >/dev/null

FINAL="$TEST_ROOT/final.json"
mise exec -- python3 - "$PENDING" "$FINAL" "$EVIDENCE" \
    "$REPO_DIR/support/acceptance/macos-human-v1-policy.json" <<'PY'
import hashlib
import json
import pathlib
import sys

source, destination, evidence_root, policy_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(source.read_text())
policy = json.loads(policy_path.read_text())

def descriptor(kind):
    relative = f"{kind}.txt"
    path = evidence_root / relative
    return {
        "kind": kind,
        "relative_path": relative,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }

for row in manifest["rows"]:
    row_policy = policy["rows"][row["id"]]
    row["result"] = "pass"
    row["executed_at"] = "2026-08-11T12:00:00+06:00"
    row["notes"] = "Release owner completed the retained first-release smoke."
    row["evidence"] = [descriptor(group[0]) for group in row_policy["required_evidence_groups"]]
    if row_policy["automation"] == "supporting_required":
        row["automated_evidence"] = [descriptor("automated-gate")]
destination.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$FINAL" >"$TEST_ROOT/final.out"
rg -F "final owner smoke passed" "$TEST_ROOT/final.out" >/dev/null

HASHED="$(mise exec -- python3 "$TOOL" hash-evidence \
    --evidence-root "$EVIDENCE" \
    --kind result-sheet \
    --relative-path result-sheet.txt)"
jq -e '.kind == "result-sheet" and (.sha256 | test("^[0-9a-f]{64}$"))' \
    <<<"$HASHED" >/dev/null

expect_negative_fixture() {
    local fixture="$1"
    local expected="$2"
    local mutated="$TEST_ROOT/${fixture%.jq}.json"
    jq -f "$FIXTURES/$fixture" "$FINAL" >"$mutated"
    if mise exec -- python3 "$TOOL" verify \
        --candidate-dir "$CANDIDATE" \
        --evidence-root "$EVIDENCE" \
        --manifest "$mutated" \
        >"$mutated.out" 2>"$mutated.err"; then
        echo "Verifier accepted negative fixture $fixture" >&2
        exit 1
    fi
    rg -F "$expected" "$mutated.err" >/dev/null
}

expect_negative_fixture wrong-candidate-binding.jq "candidate binding"
expect_negative_fixture automated-human-substitution.jq "cannot replace owner-operated acceptance"
expect_negative_fixture missing-row.jq "must appear exactly once"
expect_negative_fixture evidence-hash-mismatch.jq "hash mismatch"
expect_negative_fixture evidence-path-escape.jq "unsafe path component"
expect_negative_fixture unknown-row-field.jq "unknown keys ['unexpected']"

ln -s result-sheet.txt "$EVIDENCE/result-sheet-link.txt"
SYMLINK_EVIDENCE="$TEST_ROOT/evidence-symlink.json"
jq '.rows[0].evidence[0].relative_path = "result-sheet-link.txt"' \
    "$FINAL" >"$SYMLINK_EVIDENCE"
if mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$SYMLINK_EVIDENCE" \
    >"$TEST_ROOT/evidence-symlink.out" 2>"$TEST_ROOT/evidence-symlink.err"; then
    echo "Verifier accepted symlinked evidence" >&2
    exit 1
fi
rg -F "must not traverse a symlink" "$TEST_ROOT/evidence-symlink.err" >/dev/null

if mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$FIXTURES/duplicate-object-key.json" \
    >"$TEST_ROOT/duplicate-object-key.out" \
    2>"$TEST_ROOT/duplicate-object-key.err"; then
    echo "Verifier accepted a duplicate JSON object key" >&2
    exit 1
fi
rg -F "duplicate JSON key: schema_id" "$TEST_ROOT/duplicate-object-key.err" >/dev/null

NONFINITE="$TEST_ROOT/nonfinite.json"
sed 's/"memory_gib": 64/"memory_gib": NaN/' "$FINAL" >"$NONFINITE"
if mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$NONFINITE" \
    >"$TEST_ROOT/nonfinite.out" 2>"$TEST_ROOT/nonfinite.err"; then
    echo "Verifier accepted a non-finite JSON number" >&2
    exit 1
fi
rg -F "contains non-finite JSON number NaN" "$TEST_ROOT/nonfinite.err" >/dev/null

OVERFLOW="$TEST_ROOT/exponent-overflow.json"
sed 's/"scale": 2/"scale": 1e400/' "$FINAL" >"$OVERFLOW"
if mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$OVERFLOW" \
    >"$TEST_ROOT/exponent-overflow.out" 2>"$TEST_ROOT/exponent-overflow.err"; then
    echo "Verifier accepted an exponent-overflow JSON number" >&2
    exit 1
fi
rg -F "contains non-finite JSON number 1e400" "$TEST_ROOT/exponent-overflow.err" >/dev/null

GENERIC_HUMAN="$TEST_ROOT/wrong-owner.json"
jq '(.rows[].tester.name) = "Acceptance Tester"' "$FINAL" >"$GENERIC_HUMAN"
if mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$GENERIC_HUMAN" \
    >"$TEST_ROOT/generic-human.out" 2>"$TEST_ROOT/generic-human.err"; then
    echo "Verifier accepted a non-owner operator" >&2
    exit 1
fi
rg -F "tester must be the exact release owner" \
    "$TEST_ROOT/generic-human.err" >/dev/null

expect_candidate_negative() {
    local candidate="$1"
    local expected="$2"
    local label="$3"
    if mise exec -- python3 "$TOOL" verify \
        --candidate-dir "$candidate" \
        --evidence-root "$EVIDENCE" \
        --manifest "$FINAL" \
        >"$TEST_ROOT/$label.out" 2>"$TEST_ROOT/$label.err"; then
        echo "Verifier accepted negative candidate $label" >&2
        exit 1
    fi
    rg -F "$expected" "$TEST_ROOT/$label.err" >/dev/null
}

candidate_with_version() {
    local destination="$1"
    local version="$2"
    cp -R "$CANDIDATE" "$destination"
    jq --arg version "$version" \
        '.release.version = $version | .release.tag = ("v" + $version)' \
        "$destination/release-evidence.json" \
        >"$destination/release-evidence.next.json"
    mv "$destination/release-evidence.next.json" "$destination/release-evidence.json"
    (
        cd "$destination"
        shasum -a 256 Wrenflow.dmg Wrenflow.cdx.json RustThirdPartyLicenses.txt \
            pins.json exceptions.json provenance.json artifact-provenance.json \
            release-evidence.json >SHA256SUMS
    )
}

LEADING_ZERO_VERSION="$TEST_ROOT/candidate-leading-zero-version"
candidate_with_version "$LEADING_ZERO_VERSION" "01.4.0"
expect_candidate_negative "$LEADING_ZERO_VERSION" \
    "release tag/version is invalid" "leading-zero-version"

EMPTY_PRERELEASE_VERSION="$TEST_ROOT/candidate-empty-prerelease-version"
candidate_with_version "$EMPTY_PRERELEASE_VERSION" "0.4.0-alpha..1"
expect_candidate_negative "$EMPTY_PRERELEASE_VERSION" \
    "release tag/version is invalid" "empty-prerelease-version"

MISSING_PAYLOAD="$TEST_ROOT/candidate-missing-payload"
cp -R "$CANDIDATE" "$MISSING_PAYLOAD"
rm "$MISSING_PAYLOAD/RustThirdPartyLicenses.txt"
expect_candidate_negative "$MISSING_PAYLOAD" \
    "missing files ['RustThirdPartyLicenses.txt']" "missing-payload"

EXTRA_PAYLOAD="$TEST_ROOT/candidate-extra-payload"
cp -R "$CANDIDATE" "$EXTRA_PAYLOAD"
printf 'not a published release asset\n' >"$EXTRA_PAYLOAD/unexpected.txt"
expect_candidate_negative "$EXTRA_PAYLOAD" \
    "extra files ['unexpected.txt']" "extra-payload"

MISSING_CHECKSUM="$TEST_ROOT/candidate-missing-checksum"
cp -R "$CANDIDATE" "$MISSING_CHECKSUM"
awk '$2 != "RustThirdPartyLicenses.txt"' "$MISSING_CHECKSUM/SHA256SUMS" \
    >"$MISSING_CHECKSUM/SHA256SUMS.new"
mv "$MISSING_CHECKSUM/SHA256SUMS.new" "$MISSING_CHECKSUM/SHA256SUMS"
expect_candidate_negative "$MISSING_CHECKSUM" \
    "missing entries ['RustThirdPartyLicenses.txt']" "missing-checksum"

EXTRA_CHECKSUM="$TEST_ROOT/candidate-extra-checksum"
cp -R "$CANDIDATE" "$EXTRA_CHECKSUM"
printf '%064d  unexpected.txt\n' 0 >>"$EXTRA_CHECKSUM/SHA256SUMS"
expect_candidate_negative "$EXTRA_CHECKSUM" \
    "unknown entries ['unexpected.txt']" "extra-checksum"

CHECKSUM_DRIFT="$TEST_ROOT/candidate-checksum-drift"
cp -R "$CANDIDATE" "$CHECKSUM_DRIFT"
sed '1s/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
    "$CHECKSUM_DRIFT/SHA256SUMS" >"$CHECKSUM_DRIFT/SHA256SUMS.new"
mv "$CHECKSUM_DRIFT/SHA256SUMS.new" "$CHECKSUM_DRIFT/SHA256SUMS"
expect_candidate_negative "$CHECKSUM_DRIFT" \
    "candidate artifact Wrenflow.dmg does not match SHA256SUMS" "checksum-drift"

PROVENANCE_DRIFT="$TEST_ROOT/candidate-provenance-drift"
cp -R "$CANDIDATE" "$PROVENANCE_DRIFT"
jq '.predicate.runDetails.metadata.workflowRun =
    "https://github.com/IlyaGulya/wrenflow/actions/runs/2/attempts/1"' \
    "$PROVENANCE_DRIFT/artifact-provenance.json" \
    >"$PROVENANCE_DRIFT/artifact-provenance.json.new"
mv "$PROVENANCE_DRIFT/artifact-provenance.json.new" \
    "$PROVENANCE_DRIFT/artifact-provenance.json"
(
    cd "$PROVENANCE_DRIFT"
    shasum -a 256 Wrenflow.dmg Wrenflow.cdx.json RustThirdPartyLicenses.txt \
        pins.json exceptions.json provenance.json artifact-provenance.json \
        release-evidence.json >SHA256SUMS
)
expect_candidate_negative "$PROVENANCE_DRIFT" \
    "artifact provenance workflow does not match release evidence" "provenance-drift"

SCHEMA_DRIFT="$TEST_ROOT/schema-drift.json"
jq '.title = "Drifted acceptance manifest contract"' \
    "$REPO_DIR/support/acceptance/macos-human-v1.schema.json" >"$SCHEMA_DRIFT"
if WRENFLOW_HUMAN_ACCEPTANCE_SCHEMA_PATH="$SCHEMA_DRIFT" \
    mise exec -- python3 "$TOOL" verify \
        --candidate-dir "$CANDIDATE" \
        --evidence-root "$EVIDENCE" \
        --manifest "$FINAL" \
        >"$TEST_ROOT/schema-drift.out" 2>"$TEST_ROOT/schema-drift.err"; then
    echo "Verifier accepted a drifted manifest schema" >&2
    exit 1
fi
rg -F "JSON schema drifted from the verifier's exact v1 contract" \
    "$TEST_ROOT/schema-drift.err" >/dev/null

cp "$CANDIDATE/Wrenflow.dmg" "$TEST_ROOT/Wrenflow.dmg.original"
printf 'changed candidate bytes\n' >"$CANDIDATE/Wrenflow.dmg"
if mise exec -- python3 "$TOOL" verify \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --manifest "$FINAL" \
    >"$TEST_ROOT/candidate-drift.out" 2>"$TEST_ROOT/candidate-drift.err"; then
    echo "Verifier accepted changed candidate bytes" >&2
    exit 1
fi
rg -F "does not match SHA256SUMS" "$TEST_ROOT/candidate-drift.err" >/dev/null
mv "$TEST_ROOT/Wrenflow.dmg.original" "$CANDIDATE/Wrenflow.dmg"

if mise exec -- python3 "$TOOL" init \
    --candidate-dir "$CANDIDATE" \
    --evidence-root "$EVIDENCE" \
    --context "$TEST_ROOT/context.json" \
    --artifact-url "$ARTIFACT_URL" \
    --output "$PENDING" \
    >"$TEST_ROOT/overwrite.out" 2>"$TEST_ROOT/overwrite.err"; then
    echo "Initializer overwrote an existing manifest" >&2
    exit 1
fi
rg -F "output must be a new" "$TEST_ROOT/overwrite.err" >/dev/null

echo "GPUI human acceptance manifest tests passed"

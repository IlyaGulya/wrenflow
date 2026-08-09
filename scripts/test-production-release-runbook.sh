#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-release-runbook-test.XXXXXX")"
trap 'rm -rf -- "$FIXTURE"' EXIT

"$REPO_DIR/scripts/verify-release-promotion.sh" source

make_payload() {
    local directory="$1"
    local version="$2"
    local source_commit="$3"
    local dmg_contents="$4"
    local dmg_sha
    mkdir -p "$directory"
    printf '%s' "$dmg_contents" >"$directory/Wrenflow.dmg"
    dmg_sha="$(shasum -a 256 "$directory/Wrenflow.dmg" | awk '{print $1}')"
    for file in Wrenflow.cdx.json RustThirdPartyLicenses.txt pins.json exceptions.json \
        provenance.json; do
        printf '%s\n' "$file fixture" >"$directory/$file"
    done
    jq -S -n --arg dmg_sha "$dmg_sha" '
      {
        _type:"https://in-toto.io/Statement/v1",
        predicateType:"https://slsa.dev/provenance/v1",
        subject:[{name:"Wrenflow.dmg",digest:{sha256:$dmg_sha}}],
        predicate:{runDetails:{metadata:{
          workflowRun:"https://github.com/IlyaGulya/wrenflow/actions/runs/1",
          notarySubmissionId:"00000000-0000-0000-0000-000000000000"
        }}}
      }
    ' >"$directory/artifact-provenance.json"
    jq -S -n \
        --arg version "$version" \
        --arg source_commit "$source_commit" \
        --arg dmg_sha "$dmg_sha" '
      {
        schema_version: 1,
        source: {repository:"IlyaGulya/wrenflow",commit:$source_commit},
        release: {tag:("v" + $version),version:$version,build_number:"1"},
        notarization: {submission_id:"00000000-0000-0000-0000-000000000000",status:"Accepted"},
        identity: {bundle_id:"me.gulya.wrenflow",team_id:"T4LV8K9BGV"},
        artifact: {name:"Wrenflow.dmg",sha256:$dmg_sha}
      }
    ' >"$directory/release-evidence.json"
    (
        cd "$directory"
        shasum -a 256 Wrenflow.dmg Wrenflow.cdx.json RustThirdPartyLicenses.txt \
            pins.json exceptions.json provenance.json artifact-provenance.json \
            release-evidence.json >SHA256SUMS
    )
}

CANDIDATE="$FIXTURE/candidate"
IDENTICAL="$FIXTURE/identical"
SUCCESSOR="$FIXTURE/successor"
SOURCE_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SOURCE_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
make_payload "$CANDIDATE" "0.4.0" "$SOURCE_A" "identical-candidate"
make_payload "$IDENTICAL" "0.4.0" "$SOURCE_A" "identical-candidate"
make_payload "$SUCCESSOR" "0.4.0" "$SOURCE_B" "revalidated-successor"

jq -S -n '
  {
    tagName:"v0.4.0",
    isDraft:true,
    isPrerelease:false,
    assets: [
      "RustThirdPartyLicenses.txt",
      "SHA256SUMS",
      "Wrenflow.cdx.json",
      "Wrenflow.dmg",
      "artifact-provenance.json",
      "exceptions.json",
      "pins.json",
      "provenance.json",
      "release-evidence.json"
    ] | map({name:.})
  }
' >"$FIXTURE/release.json"
CANDIDATE_SHA="$(jq -r '.artifact.sha256' "$CANDIDATE/release-evidence.json")"
"$REPO_DIR/scripts/verify-release-promotion.sh" staged \
    "$FIXTURE/release.json" "$CANDIDATE" v0.4.0 "$CANDIDATE_SHA" "$SOURCE_A" \
    >"$FIXTURE/staged.out"
rg -F "Staged stable payload metadata passed" "$FIXTURE/staged.out" >/dev/null

for mutation in public prerelease extra_asset; do
    case "$mutation" in
        public) jq '.isDraft = false' "$FIXTURE/release.json" ;;
        prerelease) jq '.isPrerelease = true' "$FIXTURE/release.json" ;;
        extra_asset) jq '.assets += [{"name":"unexpected.bin"}]' "$FIXTURE/release.json" ;;
    esac >"$FIXTURE/release-$mutation.json"
    if "$REPO_DIR/scripts/verify-release-promotion.sh" staged \
        "$FIXTURE/release-$mutation.json" "$CANDIDATE" v0.4.0 \
        "$CANDIDATE_SHA" "$SOURCE_A" \
        >"$FIXTURE/$mutation.out" 2>"$FIXTURE/$mutation.err"; then
        echo "Staged verifier accepted release mutation: $mutation" >&2
        exit 1
    fi
done

if "$REPO_DIR/scripts/verify-release-promotion.sh" staged \
    "$FIXTURE/release.json" "$CANDIDATE" v0.4.0 \
    "$(printf 'f%.0s' {1..64})" "$SOURCE_A" \
    >"$FIXTURE/wrong-sha.out" 2>"$FIXTURE/wrong-sha.err"; then
    echo "Staged verifier accepted the wrong approved digest" >&2
    exit 1
fi
if "$REPO_DIR/scripts/verify-release-promotion.sh" staged \
    "$FIXTURE/release.json" "$CANDIDATE" v0.4.0 \
    "$CANDIDATE_SHA" "$SOURCE_B" \
    >"$FIXTURE/wrong-source.out" 2>"$FIXTURE/wrong-source.err"; then
    echo "Staged verifier accepted source/tag evidence drift" >&2
    exit 1
fi
if "$REPO_DIR/scripts/verify-release-promotion.sh" staged \
    "$FIXTURE/release.json" "$CANDIDATE" v0.4.0-beta.1 \
    "$CANDIDATE_SHA" "$SOURCE_A" \
    >"$FIXTURE/prerelease-tag.out" 2>"$FIXTURE/prerelease-tag.err"; then
    echo "Staged stable verifier accepted a prerelease tag" >&2
    exit 1
fi

"$REPO_DIR/scripts/verify-release-promotion.sh" promotion "$CANDIDATE" "$IDENTICAL" \
    >"$FIXTURE/identical.out"
rg -F "Byte-identical promotion verified" "$FIXTURE/identical.out" >/dev/null

if "$REPO_DIR/scripts/verify-release-promotion.sh" promotion "$CANDIDATE" "$SUCCESSOR" \
    >"$FIXTURE/missing.out" 2>"$FIXTURE/missing.err"; then
    echo "Changed stable bytes passed without successor revalidation" >&2
    exit 1
fi
rg -F "Changed stable bytes require" "$FIXTURE/missing.err" >/dev/null

SUCCESSOR_SHA="$(jq -r '.artifact.sha256' "$SUCCESSOR/release-evidence.json")"
jq -S -n \
    --arg candidate_sha "$CANDIDATE_SHA" \
    --arg stable_sha "$SUCCESSOR_SHA" \
    --arg stable_source "$SOURCE_B" '
  {
    schema_version: 1,
    decision: "approved",
    candidate_dmg_sha256: $candidate_sha,
    stable_dmg_sha256: $stable_sha,
    stable_source_commit: $stable_source,
    owner: "Ilya Gulya",
    approved_at: "2026-08-09T12:00:00Z",
    gates: {
      "wrenflow-duh.9.9":"passed",
      "wrenflow-duh.9.10":"passed",
      "wrenflow-duh.9.11":"passed"
    }
  }
' >"$FIXTURE/revalidation.json"
"$REPO_DIR/scripts/verify-release-promotion.sh" promotion \
    "$CANDIDATE" "$SUCCESSOR" "$FIXTURE/revalidation.json" \
    >"$FIXTURE/successor.out"
rg -F "Fully revalidated successor promotion verified" \
    "$FIXTURE/successor.out" >/dev/null

BAD_REVALIDATION="$FIXTURE/bad-revalidation.json"
jq '.gates["wrenflow-duh.9.10"] = "pending"' \
    "$FIXTURE/revalidation.json" >"$BAD_REVALIDATION"
if "$REPO_DIR/scripts/verify-release-promotion.sh" promotion \
    "$CANDIDATE" "$SUCCESSOR" "$BAD_REVALIDATION" \
    >"$FIXTURE/bad.out" 2>"$FIXTURE/bad.err"; then
    echo "Successor promotion accepted a pending external gate" >&2
    exit 1
fi

echo "Production release runbook and promotion behavior passed"

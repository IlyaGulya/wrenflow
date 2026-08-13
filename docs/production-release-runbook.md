# First public GPUI release runbook

This is a clean-break first release. There are no existing users and no stable
production deployment. The release makes **No legacy compatibility claim**:
legacy/pre-GPUI migration, downgrade, rollback, and update from a beta or other
current-line build are unsupported and are not release gates.

## No default telemetry

Wrenflow ships with no default telemetry. Owner evidence must not retain audio,
transcripts, vocabulary, credentials, full local paths, device identifiers, or
unredacted support bundles. There is no tester cohort or denominator.

## Blocking gates

The owner records a go/no-go only after all of these are true:

1. `wrenflow-duh.9.5`: the sealed automated performance baseline passed exactly
   24/24 release metrics on the frozen beta.64 product bytes. This
   acceptance-contract-only change touches no production runtime/UI file or
   numeric budget, so the stable draft does not repeat the 30-minute sampler.
   Exhaustive physical traces remain post-launch P2.
2. `wrenflow-duh.9.8`: release-please produced the exact signed, notarized,
   private stable draft with all nine authenticated assets.
3. `wrenflow-duh.9.9`: S01 owner first-install/core workflow smoke passed.
4. `wrenflow-duh.9.10`: S02 owner accessibility/appearance/display spot smoke
   passed.
5. `wrenflow-duh.9.11`: L01-L03 clean-install lifecycle evidence passed.
6. Security, privacy, supply-chain, signing, notarization, Gatekeeper, and
   support-bundle secret checks have no blocking finding.

Fresh permission-state transitions are proven by automated state tests. The
owner smoke never resets TCC or claims a fresh-account observation it did not
perform.

## Single-owner go/no-go

Ilya Gulya is the release owner. The decision record contains the exact stable
tag, source commit, version/build, DMG SHA-256, Accepted Apple submission UUID,
workflow and artifact URLs, the completed tracker gates above, timestamp, and
an explicit `GO` or `NO-GO` rationale. External reviewers, GitHub deployment
environments, production accounts, and synthetic cohorts are not required.

`NO-GO` leaves the draft private. A changed candidate requires a new draft and
new evidence; waivers do not make changed bytes eligible.

## Exact-byte promotion

Release-please creates the stable release metadata as a private, tagless draft
whose `target_commitish` is the exact release source commit. Its reusable Build
derives the immutable positive numeric release ID from release-please's official
`upload_url`. It must match that ID and commit, require the draft to be empty
and tagless through `GET /releases/{release_id}`, and attach
the nine authenticated assets without publishing it. For this first stable
draft only, the stable workflow does not rerun the 30-minute sampler. It uses
`actions:read` to fetch exact artifact `9146492644` from Build `31603344709`,
requires archive SHA-256
`fc0ec7df15c1e91480ebd198986700ecd093e4a6b21de632df89c3f106ffb7de`,
checks the retained result/report hashes and beta.64 DMG/executable identity,
and recomputes 24/24 with the current trusted release verifier. It also proves
with Git history that stable source `7e0e698191d003fe507b0729265cafceaf640c1e`
differs from frozen product source
`d3e01e0ec085121f3bd3e78038836a16608b98a0` only by the closed
acceptance/release scope and version-only manifest/lock updates. Any missing or
expired artifact, changed source, dependency, build/runtime file, numeric
threshold, or minimum sample count fails closed. Normal beta pushes retain the
live 20-cold plus constrained performance workflow. Both the automatic call
and recovery pin the verifier checkout to reviewed commit
`e233cc6db6b37307e9774db228ab11ecc4d0673c`; neither the old release source nor
a later default-branch head may supply verifier bytes.
All private-release REST tooling and the promotion metadata verifier are pinned
independently to reviewed commit
`a81827311a8aa5745a88e1f4a081746ce820a6f5`; neither the stable source commit,
workflow caller SHA, nor a later default-branch head may supply those bytes.

If that initial reusable call is interrupted before staging, recover the same
untouched draft explicitly:

```bash
mise exec -- gh workflow run build.yml \
  --repo IlyaGulya/wrenflow \
  -f release_tag=v0.4.0 \
  -f release_id='<positive numeric private draft ID>' \
  -f release_tool_source_commit=a81827311a8aa5745a88e1f4a081746ce820a6f5 \
  -f release_source_commit='<40-character draft target commit>' \
  -f verifier_source_commit=e233cc6db6b37307e9774db228ab11ecc4d0673c \
  -f confirmation=STAGE_EXISTING_PRIVATE_DRAFT
```

If all nine assets were attached but the private asset re-download verifier was
interrupted or skipped, do not rebuild, re-upload, or recreate the draft. Run
the read-only verification mode against the exact existing release object:

```bash
mise exec -- gh workflow run build.yml \
  --repo IlyaGulya/wrenflow \
  -f release_tag=v0.4.0 \
  -f release_id='<positive numeric private draft ID>' \
  -f release_tool_source_commit=a81827311a8aa5745a88e1f4a081746ce820a6f5 \
  -f release_source_commit='<40-character draft target commit>' \
  -f verifier_source_commit=e233cc6db6b37307e9774db228ab11ecc4d0673c \
  -f confirmation=VERIFY_EXISTING_PRIVATE_DRAFT
```

This mode skips compatibility, build, frozen-baseline, and upload jobs. It
downloads the closed nine-asset set by immutable asset IDs, checks hashes and
source/provenance binding, mounts the DMG, and revalidates Developer ID,
notarization, and Gatekeeper without mutating the draft.

The first `v0.4.0` staging run recorded the workflow event SHA in
`release-evidence.json` even though its signed bytes and SLSA provenance were
built from the exact stable source. That specific private payload may be
replaced only by the reviewed repair transaction:

```bash
mise exec -- gh workflow run build.yml \
  --repo IlyaGulya/wrenflow \
  -f release_tag=v0.4.0 \
  -f release_id=369445618 \
  -f release_tool_source_commit=a81827311a8aa5745a88e1f4a081746ce820a6f5 \
  -f release_source_commit=7e0e698191d003fe507b0729265cafceaf640c1e \
  -f verifier_source_commit=e233cc6db6b37307e9774db228ab11ecc4d0673c \
  -f invalid_payload_fingerprint=086ec8d47f3582eb73b8c90eb8836676afbfaffd649bf14ea19a20ef3f65c558 \
  -f confirmation=REPLACE_INVALID_PRIVATE_DRAFT_PAYLOAD
```

Before deleting anything, the workflow re-downloads and verifies all existing
assets and proves they equal signed payload artifact `9163585962` from run
`31652943641` (artifact digest
`sha256:44fc4874372b68c564b70b3a89230215a68a4f9bc8585d5ee4d113d667b7ebdf`).
It also requires the literal draft fingerprint and all nine reviewed asset
IDs/digests. It then deletes only those immutable IDs, requires an empty private
draft, uploads the complete newly built nine-file payload, and re-downloads it
by its new IDs. Any deletion or upload error stops while the release is still
private. A partial state is never retried automatically: recovery requires a
newly reviewed exact manifest and fingerprint. The repair evidence artifact
records both asset manifests and the recoverable original Actions artifact.

The owner later invokes **Promote Verified Stable Draft** with the immutable
private draft release ID, canonical stable tag, exact approved lowercase DMG
SHA-256, `PROMOTE_VERIFIED_STABLE`, and the same reviewed private-release
tooling commit.

The workflow:

1. reads only the exact `/releases/{release_id}` object, derives and checks out
   its exact source commit from the tagless private draft;
2. requires that draft to be private, non-prerelease, tagless, and contain
   exactly nine assets;
3. downloads every private asset by its immutable asset ID and authenticates
   every byte, provenance subject, source commit,
   Developer ID identity, Accepted notarization, and Gatekeeper result;
4. fingerprints the draft twice to reject concurrent mutation;
5. publishes that exact release object with `PATCH /releases/{release_id}`
   without rebuilding or uploading, creating the stable tag at the approved
   source in that publication operation;
6. verifies the new public tag, then redownloads every public asset and proves
   identical hashes and signature.

Run the local exact-byte decision check when reviewing retained payloads:

```bash
mise exec -- scripts/verify-release-promotion.sh promotion \
  /absolute/approved-private-draft \
  /absolute/public-redownload
```

Any changed asset fails. There is no "fully revalidated successor" shortcut.

## Clean-break first release copy

Release notes state that this is Wrenflow's first public GPUI release, installs
as a clean application, and does not support legacy data migration, downgrade,
rollback, or beta-to-stable update compatibility. They link `docs/privacy.md`,
`SECURITY.md`, and `docs/macos-support.md`.

## Immediate public verification

After publication, immediately retain proof that:

- the release is public, non-prerelease, and selected as `latest`;
- `latest` resolves to the exact approved stable tag;
- the public asset set is exactly the nine-file allowlist;
- the redownloaded DMG SHA-256 equals the approved private draft;
- the public redownload passes signature, notarization, Gatekeeper, checksum,
  and provenance verification.

Record the exact release and asset URLs in the owner decision and close
`wrenflow-duh.9.12` only when these checks pass. There is no fabricated 48-hour
production watch.

Validate this contract with `mise run verify-release-runbook` and
`mise run test-release-runbook`.

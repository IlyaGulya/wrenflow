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

The stable artifact is created by release-please as a private draft. The owner
invokes **Promote Verified Stable Draft** with the canonical stable tag, exact
approved lowercase DMG SHA-256, and `PROMOTE_VERIFIED_STABLE`.

The workflow:

1. checks out the immutable stable tag;
2. requires a private, non-prerelease draft with exactly nine assets;
3. downloads and authenticates every asset, provenance subject, source commit,
   Developer ID identity, Accepted notarization, and Gatekeeper result;
4. fingerprints the draft twice to reject concurrent mutation;
5. publishes that draft without rebuilding or uploading;
6. redownloads every public asset and verifies identical hashes and signature.

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

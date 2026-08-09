# Release supply-chain contract

`mise run supply-chain-audit` scans both locked Cargo graphs with
`cargo-deny 0.20.2`. Unknown registries/git sources, unapproved licenses and
advisories fail the gate. Exact product pins for GPUI 0.2.2,
gpui-component/assets 0.5.1, parakeet-rs 0.3.4 and ONNX Runtime 1.24.2 must not
float.

`supply-chain/pins.json` is the machine-readable external-material contract.
ORT is verified at the archive boundary before extraction and again at the
dylib/license/notice boundary. Models use immutable Hugging Face commit URLs,
pinned sizes and streaming SHA-256 verification before an atomic install marker
is published. A changed asset invalidates that marker and triggers full
verification.

`mise run supply-chain-metadata` uses pinned `cargo-cyclonedx 0.5.9` and
`cargo-about 0.9.1`. `SOURCE_DATE_EPOCH` comes from the source commit,
CycloneDX random serials are disabled, absolute workspace paths are sanitized,
and a second generation must byte-match. The app bundle contains:

- `SupplyChain/Wrenflow.cdx.json` — complete production Rust graph;
- explicit Swift shell and ONNX Runtime components, with the compiled artifact
  digests finalized in `artifact-provenance.json`;
- `release-evidence.json` — the immutable source commit/tag/version/build,
  GitHub workflow run/attempt, Accepted Apple notarization submission ID,
  Developer ID identity contract and final DMG SHA-256;
- `RustThirdPartyLicenses.txt` — crate/version/license inventory and harvested
  full attribution/license texts;
- external pins, exceptions, provenance inputs and `SHA256SUMS`;
- exact ONNX Runtime license and upstream third-party notices.

The release workflow finalizes an in-toto/SLSA-shaped subject list for the app
binary, Swift shell, ORT dylib and DMG. The artifact verifier checks the SBOM,
notices, checksums, signatures, hardened runtime, entitlements, dylib/rpaths,
notarization staple and Gatekeeper result before publication.
Publication refuses to replace an existing candidate asset, binds beta tags to
the exact built commit, then re-downloads the published payload on macOS. The
downloaded checksum set, release evidence, mounted app, notarization staple,
DMG Gatekeeper assessment and extracted-app execution assessment must all pass.

## Approved time-bounded exceptions

The canonical records are `supply-chain/exceptions.json`; the test gate rejects
missing owners, release impact or expired dates.

- `paste` through tokenizers/parakeet and six exact-GPUI transitive crates have
  unmaintained advisories but no reported vulnerability. Owner: Ilya Gulya;
  expiry: 2026-12-31. A vulnerability or unsound advisory blocks release.
- The pinned community Whisper ONNX conversion does not repeat license metadata.
  It is approved only as a byte-pinned conversion of the pinned MIT-licensed
  OpenAI base model. Owner: Ilya Gulya; expiry: 2026-10-31. Any revision/source
  change blocks release pending a new license review.

## Updating a pin

1. Review the upstream release, source commit, advisories and license changes.
2. Update code and `supply-chain/pins.json` together; never edit only one copy.
3. Obtain hashes from the immutable upstream object, then reproduce them from a
   clean download.
4. Run `mise run test-supply-chain`, `mise run test`, `mise run lint` and a
   signed release artifact verification.
5. Record the reviewer and evidence on the release issue.

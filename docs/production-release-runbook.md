# GPUI beta and stable production release runbook

Status: preflight. Do not execute promotion until `wrenflow-duh.9.9`,
`wrenflow-duh.9.10` and every pre-promotion `wrenflow-duh.9.11` row pass against one
immutable notarized candidate (or a fully revalidated successor). `.9.11`
remains open solely for the explicitly named M13 live stable-feed condition
until the immediate post-promotion observation passes; no other open row is an
allowed promotion condition. Do not call this runbook complete before then.
The numeric source of truth is
[`support/release-runbook-policy.json`](../support/release-runbook-policy.json).

## Owners and contacts

One person may hold several roles, but every role has an explicit handoff and
must sign its own row in the retained release record.

| Role | Owner | Contact and duty |
| --- | --- | --- |
| Release manager | Ilya Gulya | `ilya@gulya.me`; freezes the denominator, chairs go/no-go and authorizes promotion |
| Build and notarization | Ilya Gulya | `ilya@gulya.me`; records CI run, source SHA, Apple submission and published hashes |
| Validation | Ilya Gulya | `ilya@gulya.me`; owns `.9.9`–`.9.11` evidence and variance disposition |
| Security and privacy | Ilya Gulya | `ilya@gulya.me`, subject `Wrenflow security`; may stop release independently |
| Support | Ilya Gulya | `ilya@gulya.me`, subject `Wrenflow support`; cohort consent, feedback and user copy |
| Incident recovery | Ilya Gulya | `ilya@gulya.me`; rehearses withdrawal/successor/reinstall communication |

## Entry gate

The release manager creates a private release record and copies, without
editing, the exact nine-file `.9.8` payload from the release-please stable draft:
`Wrenflow.dmg`, `Wrenflow.cdx.json`, `RustThirdPartyLicenses.txt`, `pins.json`,
`exceptions.json`, `provenance.json`, `artifact-provenance.json`,
`release-evidence.json` and `SHA256SUMS`.
The signed workflow payload is retained for 21 days and the draft release
retains the staged assets until an explicit decision. Record the authenticated
draft download, source commit, release tag/version/build, workflow run/attempt,
Apple submission ID, Team `T4LV8K9BGV`, bundle `me.gulya.wrenflow` and DMG
SHA-256.

The entry decision is NO-GO unless all `.9.1`–`.9.8` issues are closed, every
time-bounded supply-chain exception is still valid, re-downloaded bytes pass
the checksum/notary/Gatekeeper verifier, and no P0/P1 release blocker is open.
No artifact is rebuilt for a tester.

## Cohort, consent and denominator

### No default telemetry

Wrenflow analytics, remote crash reporting and automatic diagnostic upload
remain disabled. The beta is manual and explicit opt-in. Invitations state the
scope, destructive clean-break behavior, data collected, retention and contact
before consent. Declining or withdrawing has no product consequence.

Invite at most 20 people and target 10 enrollments. Before the first download,
freeze a list of anonymous, release-local cohort codes. Do not store names,
device identifiers or product content in the measurement sheet. Delete the
code-to-contact map no later than 30 days after stable release.

### Frozen denominator

The installed denominator is every consenting cohort code that reports a
checksum-matched first launch. It cannot be reduced because a participant is
silent or unsuccessful. Go/no-go requires at least 8 exact-candidate
installers, manual outcome forms from at least 80% of installers, at least 20
current-line update attempts, and 20 transcription attempts per installer.
Recruitment changes after freeze are a new cohort revision, never an edit to
the old denominator.

The observation window is at least 7 complete days after the last qualifying
installation and at most 14 days total. Extend only by recording a new end
date before inspecting a threshold; never extend selectively to erase a bad
result.

Allowed evidence is a release-local cohort code, exact artifact hash, supported
macOS/hardware class, closed yes/no/count outcomes, timings required by the
approved performance budget, and an explicitly exported/reviewed structured
support bundle. Never collect audio, transcripts, vocabulary, device identity,
full paths or credentials.

## Beta execution and triage

1. Send the immutable candidate link, DMG SHA-256, consent text, clean-break
   copy, support contact and observation deadline to the frozen cohort.
2. Each tester independently re-downloads and checksum-verifies the candidate;
   no local rebuild is accepted.
3. Execute the assigned `.9.9` clean-machine/TCC/core rows, `.9.10` human
   accessibility rows, and `.9.11` update/endurance/fault rows. Every row cites
   the same DMG SHA-256 and retained evidence.
4. Support acknowledges reports within one business day. Security/privacy
   reports use the private security contact, never a public issue. Triage maps
   every finding to severity, owner, affected hash and pass/fix/revalidate or
   explicit nonblocking rationale.
5. A code, packaging, dependency, entitlement or release-metadata change makes
   a successor artifact. Never overwrite the beta tag/assets. Publish a higher
   SemVer beta and rerun every affected gate; security/privacy/signature/update
   changes force full `.9.9`–`.9.11` revalidation.

### M13/M22 update evidence boundary

M13 and M22 use the separate closed policy at
`support/acceptance/endurance-v1-policy.json`. Start with a lower signed GPUI
baseline and the exact target, each retaining its published checksum set,
release source SHA, Apple submission UUID, DMG SHA-256 and app CDHash. The
candidate-plan verifier rejects an equal/newer baseline, a mixed major line or
any identity mismatch. It re-verifies the exact nine-file payload, mounts each
DMG read-only and derives the app identity from that mounted DMG; an independently
supplied extracted app is not accepted.

Offline, rate-limit, malformed metadata, duplicate release and partial-transfer
cases are automated Rust unit/fixture evidence. Their record is bound to the
exact source commit, `update.rs` SHA-256, test IDs and test-log SHA-256. The
current-line relaunch and interrupted-cleanup rows are likewise bound to their
exact `data_paths.rs`/`recovery.rs` SHA-256 values, test IDs and the same retained
log; every claimed test must appear as passing in that log. These
cases do not count as manual M13. The policy/verifier SHA-256 values are also
retained, and the source commit must equal the target release source.

Pre-promotion signed/manual M13 retains the authenticated exact-target draft
DMG, its installed signed identity, and the actual public beta-selector result
from the lower baseline. Beta records the release it really selects (or
up-to-date), but it must not select the exact private stable target. Such a
selection contradicts the draft/private premise and is an immediate STOP. The
exact-target stable feed cannot be observed while that target is a private draft. Therefore the
pre-promotion result is explicitly conditional, and exact-target stable-feed
discovery/download is a mandatory immediate post-promotion observation.
Signed/manual M22 consists of one real SIGKILL run at each of Staging, Prepared,
Swapped and before ready-finalization. Every M22 stage retains the pre-kill
journal, SIGKILL record, post-launch recovery evidence and installed-identity
evidence with recomputed SHA-256 values. Each exact PID is externally SIGSTOPed;
the verifier distinguishes the plain baseline app, exact update helper and plain
target app roles. A hidden application argument or alternate test behavior
invalidates the run.

The release record retains the passing output of:

```bash
export WRENFLOW_BASELINE_PAYLOAD=/absolute/baseline-payload
export WRENFLOW_TARGET_PAYLOAD=/absolute/target-payload
mise exec -- scripts/gpui-endurance-preflight.sh verify-evidence \
  /absolute/evidence/automated-preflight.json \
  /absolute/evidence/candidate-plan.json \
  /absolute/evidence/m13-m22-manifest.json
```

Unknown fields, missing stages, duplicate retained filenames, source drift or
a missing/exact-owner timestamp decision are NO-GO. Immediately after promotion,
retain and pass:

```bash
mise exec -- scripts/gpui-endurance-preflight.sh verify-post-promotion \
  /absolute/evidence/candidate-plan.json \
  /absolute/evidence/m13-post-promotion-stable.json
```

Until this passes, promotion is conditional, `.9.11` remains open and cohort
rollout is frozen. Failure invokes immediate STOP and a higher current-line
successor; the pre-promotion M13 record cannot waive it.

## Numeric go/no-go

Calculate percentages from the frozen denominators, preserve raw integer
numerator/denominator, and round only for display. GO requires all conditions:

- 0 open release blockers; 0 security/privacy/data-loss events; 0 secret
  findings in support bundles;
- 0 signature, notarization or Gatekeeper failures; 0 unlaunchable update
  recoveries; 0 crash loops;
- 0 stuck hotkey/overlay or duplicate-process events;
- 100% install-and-launch success;
- at least 95% current-GPUI-line update success across at least 20 attempts;
- at least 95% TCC onboarding and core workflow success;
- at least 99% successful transcriptions across the required 20 per installer;
- `.9.5` resource/latency budgets pass, `.9.9` and `.9.10` are closed, every
  pre-promotion `.9.11` row passes, only the named post-promotion M13 condition
  remains, all response coverage/window requirements pass, and every variance
  has an owner/rationale.

Any security/privacy/data-loss, signature/notary/Gatekeeper, unlaunchable
update or crash-loop event is an immediate stop; percentages cannot waive it.
At the meeting, each owner reads and signs their evidence row. Missing evidence,
an expired exception or a silent denominator is NO-GO.

## Stop and recovery drill

Before inviting the cohort, execute a tabletop drill using a fake higher beta
tag and no user data:

1. Validation reports an update that leaves the app unlaunchable. The release
   manager freezes invitations and declares STOP; support timestamps the
   acknowledgement and uses the security path if integrity/privacy is involved.
2. Build owner confirms the affected tag, source SHA and DMG SHA without
   deleting or replacing retained bytes. The public prerelease may be marked
   withdrawn/draft to stop new discovery, but its evidence remains retained.
3. Incident owner prepares a higher current-line fixed candidate. There is no
   downgrade or rollback. Users receive truthful steps to export reviewed
   diagnostics, reinstall the verified current line, and use explicit
   current-data reset only when necessary.
4. A second person follows the communication from scratch and verifies the
   hash, install path, support/security contact and recovery steps. Record
   elapsed detection, acknowledgement and communication times plus pass/fail.
5. Resume only after the fixed higher beta passes the full gate scope dictated
   above and a new cohort revision/deadline is frozen.

## Promotion identity rule

### Byte-identical promotion

Byte-identical means the candidate and stable `Wrenflow.dmg` SHA-256 are equal,
and their embedded version, source commit and release evidence also agree. Run:

```bash
mise exec -- scripts/verify-release-promotion.sh promotion \
  /absolute/candidate-payload /absolute/stable-payload
```

Changing a tag, title or changelog must not replace asset bytes. If the
candidate contains a beta SemVer but stable requires a final SemVer, identical
promotion is impossible because the signed bundle version changes.

### Fully revalidated successor

For a public beta-to-stable path, release-please changes the final version, so
that beta DMG is not eligible for byte-identical stable promotion. The stable
draft is instead the final-version `.9.8` candidate: the build signs,
notarizes, uploads and re-download-verifies it once while the GitHub release
remains private draft. The exact stable draft hash/source then passes `.9.9`,
`.9.10` and every pre-promotion `.9.11` row before manual promotion. The sole
named `.9.11` condition remains the immediate post-promotion M13 stable-feed
observation; it cannot truthfully pass while the exact target is private.

If a staged stable candidate changes for any reason, it is a successor. Its
exact hash/source must pass the affected gates (all three for code, packaging,
identity, update or privacy changes), then be bound into an owner-approved
`successor-revalidation.json` decision record checked by:

```bash
mise exec -- scripts/verify-release-promotion.sh promotion \
  /absolute/candidate-payload /absolute/stable-payload \
  /absolute/successor-revalidation.json
```

The stable architecture is now staged and byte-preserving: release-please uses
`draft: true`; Build uploads exact notarized assets only to that empty draft;
`.github/workflows/promote-stable.yml` accepts the stable tag, approved DMG
SHA-256 and explicit confirmation, re-downloads every asset twice, checks the
tag/evidence/provenance/notary/Gatekeeper contract, then only flips the existing
draft to public/latest. It never rebuilds or uploads an asset. Public beta
prereleases remain a separate path and can never become latest stable.

The promotion job targets the `stable-production` GitHub Environment. If the
repository configures required reviewers, GitHub provides an additional manual
approval hold. The workflow does not assume reviewers are configured: record
the actual environment policy at go/no-go, and always require the manual
dispatch, exact expected SHA and confirmation. Promotion evidence is retained
for 30 days.

## Clean-break release copy

Use this meaning verbatim in the release PR, GitHub release and support reply
(editorial punctuation may change, scope may not):

> Wrenflow now uses its native GPUI application line. This is a clean break:
> pre-GPUI settings, history and models are not imported or changed, so first
> GPUI launch starts fresh setup. Updates within the current GPUI line preserve
> current-format preferences, history, recordings and models. There is no
> downgrade or rollback. If recovery is required, export the reviewed local
> diagnostics, reinstall the current signed release, or explicitly reset only
> current GPUI data. Audio and transcripts stay local; Wrenflow has no default
> telemetry or automatic diagnostic upload.

Also link `docs/privacy.md`, `SECURITY.md`, `docs/macos-support.md`, current-line
update/recovery instructions and the support email. Verify the GitHub latest
stable link resolves to the approved stable tag and never to a beta.

## release-please stable procedure

1. Review the release-please PR changelog, final SemVer, root and GPUI Cargo
   versions, clean-break copy and support/privacy/security links. Do not merge
   while a blocking issue, exception, cohort row or promotion-boundary gap is
   open.
2. Merge the reviewed release PR only to create the final tag and draft. Wait
   for `build-staged-stable-release`: it builds from that exact tag, uploads to
   the empty draft without `--clobber`, and re-download-verifies the retained
   final-version payload. This draft is `.9.8`; it is not public/latest.
3. Run `.9.9`, `.9.10` and every pre-promotion `.9.11` row against those exact
   draft bytes. The retained GO record must name the sole conditional item:
   post-promotion exact-target stable-feed observation. Then manually dispatch
   `Promote Verified Stable Draft` with the exact tag, DMG SHA-256 and
   `PROMOTE_VERIFIED_STABLE`. If `stable-production` has required reviewers,
   record their approval; do not claim it when not configured.
4. The promotion workflow verifies the untouched draft/tag/assets a second
   time and only changes draft/latest metadata. Verify the stable
   tag resolves to `release-evidence.source.commit`, assets were not replaced,
   `releases/latest` resolves to that non-prerelease tag, SHA-256 matches the
   retained decision, then immediately run the closed M13 post-promotion
   verifier proving the in-app stable channel selects and downloads it. Keep
   rollout frozen until it passes; on failure declare STOP and prepare a
   successor.
5. Observe for 48 hours. Keep the frozen denominator and stop conditions live;
   monitor only opt-in/manual support evidence. A blocker invokes the rehearsed
   higher-current-line successor/reinstall communication, never rollback.
6. Close `.9.11` only after the post-promotion M13 observation passes. At 48
   hours record latest-link/update checks, open findings, support counts,
   artifact availability and final decision. Delete release-local participant
   mappings at the documented 30-day deadline, retaining only aggregate closed
   outcomes and non-sensitive release evidence.

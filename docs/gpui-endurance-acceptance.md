# GPUI current-line endurance and fault acceptance

This is the execution contract for M13–M16 and M21–M22. The automated
preflight is reproducible source evidence; it is not a substitute for testing
the exact immutable, notarized candidate on a disposable macOS account.

## Automated disposable-root preflight

Run:

```bash
mise run test-endurance-preflight
mise run endurance-preflight
```

The harness creates a private temporary root and runs 20 cycles for each of
these closed contracts:

- current `gpui-v1` preferences, history, recordings and models survive
  relaunch;
- a killed recording publish, model download, settings atomic write and update
  download leave only allowlisted temporary files, which the next launch
  removes without deleting complete data or SQLite recovery files;
- stable/beta selection, offline, rate-limit, malformed metadata, duplicate
  release and dropped-partial-transfer cases execute as named Rust unit/fixture
  tests; and
- Staging, Prepared and Swapped journals select only bounded cleanup, verified
  candidate finalization or explicit current-line recovery.

`build/gpui-endurance-preflight/automated-preflight.json` deliberately records
all signed/manual rows as pending. Each update case records its exact test ID,
`core/wrenflow-runtime/src/update.rs` SHA-256, test-log SHA-256, policy SHA-256
and verifier SHA-256 plus the source commit. The final manifest requires that
commit to equal the exact target release source. A dirty source run records
`tree_state: "dirty"`; the final verifier also recomputes the retained log,
requires every named passing test, requires all three sources to be tracked at
HEAD, and rejects any dirty or untracked checkout state.

The negative network/metadata cases end here. They are automated evidence and
must never be represented as signed/manual M13 feed operations.

## Immutable baseline/target preflight

Choose one lower signed GPUI baseline and the exact target. For each, download
the exact nine-file published payload into a separate new directory:
`Wrenflow.dmg`, `Wrenflow.cdx.json`, `RustThirdPartyLicenses.txt`, `pins.json`,
`exceptions.json`, `provenance.json`, `artifact-provenance.json`,
`release-evidence.json` and `SHA256SUMS`. Do not extract or substitute an app.
Set:

```bash
export WRENFLOW_BASELINE_PAYLOAD=/absolute/baseline-payload
export WRENFLOW_TARGET_PAYLOAD=/absolute/target-payload
mise exec -- scripts/gpui-endurance-preflight.sh candidate-plan /absolute/evidence/run
```

This rejects missing or extra payload/checksum entries, verifies both checksum
sets and provenance bindings, mounts each exact DMG read-only, and derives the
version/build/CDHash from the sole root `Wrenflow.app` inside that DMG. It also
verifies release source SHA, Accepted Apple submission record, production
bundle/team identity, signatures, hardened runtime, support contract, stapled
ticket and Gatekeeper assessment. The plan fails unless baseline and target are
distinct signed GPUI artifacts on the same major line, the baseline version is
lower, and the target is a final stable SemVer without a prerelease component.
It launches neither app and leaves M13/M22 pending.

## Candidate execution matrix

Retain the candidate plan, DMG SHA-256, release evidence, privacy-safe
diagnostic export, Instruments traces and one result record per row. Never use
real user data or the primary macOS account.

| Row | Candidate operation | Required result |
| --- | --- | --- |
| M13 | Before promotion, retain the authenticated exact-target DMG, its signed installed identity, and the actual public beta-selector result from the lower baseline; after promotion, run the mandatory stable-feed observation | The private draft is never falsely claimed as public-feed evidence; beta records its actual different public release or up-to-date result and must not select the exact private target; the post-promotion stable record selects and downloads the exact target |
| M14 | Sleep/wake in idle, recording and model work; lock/unlock; remove/add the selected audio device | One process, no stuck hotkey/overlay, truthful cancellation/recovery, audio/event-tap recovery |
| M15 | SIGKILL during recording publish, model `.part`, settings temporary write and update download | Next launch removes only strict temporary state, retains complete current-format data and reports recovery |
| M16 | Relaunch valid and corrupt current-format roots; then exercise explicit current-data reset/reinstall | Valid current data remains intact; corrupt state produces bounded recovery; TCC/login-item behavior is recorded, not reset implicitly |
| M21 | 60 s idle, 60 s recording, 20 full transcriptions at 50-entry history under Instruments | Meets the approved `.9.5` CPU, allocation, wakeup, main-thread and memory budgets with no monotonic growth |
| M22 | From the same verified baseline/target pair, SIGKILL once at update Staging, Prepared, Swapped and immediately before ready-finalization | Every stage retains its exact pre-kill journal, SIGKILL record, recovery record and installed-identity record; the expected signed baseline or target is launchable |

Before and after sleep, lock and device-change steps, capture only bounded
numeric host state (no device names, paths or PIDs):

```bash
mise exec -- scripts/gpui-endurance-preflight.sh capture-hooks before /absolute/evidence/hooks-before.json
mise exec -- scripts/gpui-endurance-preflight.sh capture-hooks after_sleep_wake /absolute/evidence/hooks-sleep.json
mise exec -- scripts/gpui-endurance-preflight.sh capture-hooks after_lock_unlock /absolute/evidence/hooks-lock.json
mise exec -- scripts/gpui-endurance-preflight.sh capture-hooks after_device_change /absolute/evidence/hooks-device.json
```

At an explicitly prepared mutable stage, record a real power-loss-equivalent
termination with an exact PID. The command verifies that the PID belongs to the
signed app before sending SIGKILL. Update stages additionally require the
verified pair plan and exact journal; the script copies the journal to a new
retained file before the signal and binds both hashes into the SIGKILL record:

```bash
export WRENFLOW_TEST_APP=/Applications/Wrenflow.app
export WRENFLOW_CONFIRM_DISPOSABLE_ACCOUNT=me.gulya.wrenflow-gpui-v1-delete
mise exec -- scripts/gpui-endurance-preflight.sh kill-stage recording 12345 /absolute/evidence/kill-recording.json

export WRENFLOW_M13_M22_PLAN=/absolute/evidence/run/candidate-plan.json
export WRENFLOW_UPDATE_JOURNAL=/absolute/current-data/updates/update-transaction.json
export WRENFLOW_JOURNAL_EVIDENCE=/absolute/evidence/m22-prepared-journal.json
mise exec -- scripts/gpui-endurance-preflight.sh kill-stage update_prepared 12346 /absolute/evidence/m22-prepared-sigkill.json
```

For every M22 update stage, first observe the exact journal and externally
SIGSTOP the exact PID. `update_staging` and `update_prepared` require the plain
baseline process, `update_swapped` requires the update helper with the journal's
exact token, and `before_ready_finalization` requires the newly launched plain
target process while the Swapped journal still exists. The command rejects a
running PID, a mismatched role/CDHash/token, and aliased journal/SIGKILL output
paths before sending SIGKILL.

The kill record remains `recovery_result: "pending_next_launch"`. Only the
subsequent signed launch, state-integrity comparison and diagnostic export may
turn the corresponding human result into pass/fail evidence.

## Pre-promotion M13/M22 evidence manifest

Create a new manifest beside all files it names, following the closed shape in
`scripts/fixtures/endurance/manifest-pass.json`. The checked-in policy is
`support/acceptance/endurance-v1-policy.json`. Every referenced filename must
be a basename-only regular file and every SHA-256 is recomputed. Unknown or
duplicate keys, duplicate evidence filenames, missing/extra cases or stages,
an unordered candidate pair, source/hash drift, non-passing rows and
out-of-contract semantics fail closed.

```bash
export WRENFLOW_BASELINE_PAYLOAD=/absolute/baseline-payload
export WRENFLOW_TARGET_PAYLOAD=/absolute/target-payload
mise exec -- scripts/gpui-endurance-preflight.sh verify-evidence \
  /absolute/evidence/automated-preflight.json \
  /absolute/evidence/run/candidate-plan.json \
  /absolute/evidence/m13-m22-manifest.json
```

This verifies pre-promotion M13 evidence and all M22 stages. Its M13 result is
deliberately `conditional_pass_pending_post_promotion_stable`: a private draft
cannot appear in the production feed. It must not be relabeled as a completed
live stable-feed row. If the beta selector reports that exact private target as
selected, the draft/private premise is false and the release is an immediate
STOP rather than an acceptable pre-promotion result.

Immediately after exact-byte promotion, retain a new closed observation beside
its discovery JSON and downloaded DMG, then run:

```bash
mise exec -- scripts/gpui-endurance-preflight.sh verify-post-promotion \
  /absolute/evidence/run/candidate-plan.json \
  /absolute/evidence/m13-post-promotion-stable.json
```

The observation must show the real stable feed selecting the exact target and
the downloaded bytes matching its DMG SHA-256. A failure is an immediate STOP
and successor/reinstall path; it cannot be waived by the pre-promotion result.
Only both verifier results plus their exact `Ilya Gulya` owner/timestamps close
M13. Current-line cleanup, current-data reset and reinstall remain the supported
recovery actions.

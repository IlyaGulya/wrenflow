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
  relaunch while populated pre-GPUI roots remain byte-for-byte untouched;
- a killed recording publish, model download, settings atomic write and update
  download leave only allowlisted temporary files, which the next launch
  removes without deleting complete data or SQLite recovery files;
- stable and beta metadata select different expected releases on every cycle;
- dropped partial downloads are never published; and
- Staging, Prepared and Swapped journals select only bounded cleanup,
  verified-candidate finalization or explicit recovery. They never guess,
  downgrade or roll back.

`build/gpui-endurance-preflight/automated-preflight.json` deliberately records
all signed/manual rows as pending. A dirty source run also records `tree_state:
"dirty"`; it cannot become candidate evidence by renaming the file.

## Immutable candidate preflight

Download `Wrenflow.dmg`, `release-evidence.json`, `SHA256SUMS` and every file
named by the checksum set into one new directory. Extract the exact app without
rebuilding it. On a disposable macOS account only, set:

```bash
export WRENFLOW_CONFIRM_DISPOSABLE_ACCOUNT=me.gulya.wrenflow-gpui-v1-delete
export WRENFLOW_TEST_APP=/absolute/path/to/Wrenflow.app
export WRENFLOW_TEST_DMG=/absolute/published-set/Wrenflow.dmg
export WRENFLOW_RELEASE_EVIDENCE=/absolute/published-set/release-evidence.json
export WRENFLOW_RELEASE_CHECKSUMS=/absolute/published-set/SHA256SUMS
mise exec -- scripts/gpui-endurance-preflight.sh candidate-plan /absolute/evidence/run
```

This verifies the full published checksum set, release source SHA, accepted
Apple notarization evidence, production bundle/team identity, DMG hash,
signatures, hardened runtime, support contract, stapled ticket and Gatekeeper
assessment. It does not launch the app and leaves every M13–M22 row pending.

## Candidate execution matrix

Retain the candidate plan, DMG SHA-256, release evidence, privacy-safe
diagnostic export, Instruments traces and one result record per row. Never use
real user data or the primary macOS account.

| Row | Candidate operation | Required result |
| --- | --- | --- |
| M13 | Check stable and beta separately; inject offline, rate limit, malformed/duplicate metadata and dropped partial transfer | Only the channel's exact authenticated notarized asset is offered; no response URL is opened; failures remain typed and actionable |
| M14 | Sleep/wake in idle, recording and model work; lock/unlock; remove/add the selected audio device | One process, no stuck hotkey/overlay, truthful cancellation/recovery, audio/event-tap recovery |
| M15 | SIGKILL during recording publish, model `.part`, settings temporary write and update download | Next launch removes only strict temporary state, retains complete current-format data and reports recovery |
| M16 | Launch over populated legacy roots and an existing current `gpui-v1`; then exercise explicit reset/reinstall | No legacy read/import/mutation; no repeated onboarding for valid current data; TCC/login-item behavior is recorded, not reset implicitly |
| M21 | 60 s idle, 60 s recording, 20 full transcriptions at 50-entry history under Instruments | Meets the approved `.9.5` CPU, allocation, wakeup, main-thread and memory budgets with no monotonic growth |
| M22 | SIGKILL at update Staging, Prepared, Swapped and before ready-finalization | Leaves a launchable signed current-line app; exact staging is removed, verified installed candidate is finalized, or reset/reinstall is required |

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
signed candidate before sending SIGKILL:

```bash
mise exec -- scripts/gpui-endurance-preflight.sh kill-stage recording 12345 /absolute/evidence/kill-recording.json
mise exec -- scripts/gpui-endurance-preflight.sh kill-stage update_prepared 12346 /absolute/evidence/kill-update-prepared.json
```

The kill record remains `recovery_result: "pending_next_launch"`. Only the
subsequent signed launch, state-integrity comparison and diagnostic export may
turn the corresponding human result into pass/fail evidence.

Pre-GPUI import, legacy schema upgrade, downgrade and rollback are explicitly
out of scope. The supported recovery choices are current-line cleanup,
current-data reset and reinstall.

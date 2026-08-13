# First-public-release owner smoke evidence

This is a two-row, owner-operated acceptance contract for the first public GPUI
release. There are no external testers, installed production cohort, or legacy
release population. It does not claim a fresh-account matrix that does not
exist.

The immutable candidate is still bound to all nine release assets, the exact
source commit, DMG SHA-256, Developer ID team, bundle identifier, Accepted
notarization submission, workflow URL, immutable release ID and DMG asset ID.
Before publication it accepts only the tagless browser URL found in the closed
authenticated `/releases/{release_id}` object emitted by
`private-release-api.py inspect-owner`; after promotion `transition-public`
requires the same release ID, all nine immutable asset IDs and bytes, and
replaces the private DMG URL with the canonical tag URL. The retained manifest
binds the release ID and DMG asset ID directly. The verifier never launches the app
or changes macOS settings.

## Rows

| Row | Tracker | Required owner observation |
| --- | --- | --- |
| S01 | `wrenflow-duh.9.9` | Clean DMG install and Gatekeeper first open; existing microphone/accessibility grants inspected without reset; physical hotkey, local transcription, controlled paste, Settings, model and History smoke |
| S02 | `wrenflow-duh.9.10` | Keyboard traversal plus VoiceOver, Light/Dark, one available display/scale and window-size spot checks |

Both rows are operated by release owner Ilya Gulya on the available physical
Mac. This is not a tester cohort. A row passes only with its retained result
sheet, candidate binding, screenshots or recording, required supporting
evidence, and the automated state-test record.

## TCC boundary

No acceptance step resets, edits, or fabricates TCC state. Existing grants may
be inspected and used. If a permission is not granted, the owner records the
blocked observation; the row does not pass by accepting a prompt or changing
Privacy settings during the evidence run. Fresh grant, denial, revocation, and
recovery state transitions are covered by the signed shell/runtime automated
tests and are attached as supporting evidence. They are not represented as a
fresh-user manual observation.

## Evidence workflow

Prepare an absolute non-symlink directory containing the exact nine assets, the
mode-0600 authenticated private release metadata, and an absolute retained
evidence directory. Create a context file whose operator
is exactly:

```json
{"tester":{"name":"Ilya Gulya","role":"release owner"}}
```

along with the physical machine, macOS, and display fields required by
`support/acceptance/macos-human-v1.schema.json`.

Create a pending manifest:

```bash
mise run human-acceptance -- init \
  --candidate-dir /absolute/private-draft-payload \
  --release-metadata /absolute/private-release-metadata.json \
  --evidence-root /absolute/owner-smoke \
  --context /absolute/owner-smoke/context.json \
  --output /absolute/owner-smoke/owner-smoke-v1.json
```

Create a unique app copy from the verified DMG; do not overwrite `/Applications`.
Create one new disposable root and retain the printed session outside it:

```bash
SESSION="$(mise run owner-smoke -- prepare-root /absolute/new-owner-data)"
mise run owner-smoke -- launch \
  /absolute/unique/Wrenflow.app /absolute/new-owner-data "$SESSION"
```

The launch helper verifies the Developer ID team and bundle ID and uses
LaunchServices only. Reuse the exact same root and session for S01, S02, L01 and
L02 restarts. The app otherwise runs its ordinary microphone, hotkey, local
model, paste, Settings and History paths. There is no synthetic input, TCC/reset
operation, or production-data fallback. A wrong/half gate, symlink, permissive,
foreign nonempty root, or changed session exits before runtime paths resolve.

Hash retained files with `hash-evidence`, fill only observations that actually
occurred, then verify:

```bash
mise run human-acceptance -- verify \
  --candidate-dir /absolute/private-draft-payload \
  --release-metadata /absolute/private-release-metadata.json \
  --evidence-root /absolute/owner-smoke \
  --manifest /absolute/owner-smoke/owner-smoke-v1.json
```

`--allow-pending` is structural review only. It never satisfies release
acceptance. Unknown fields, missing rows, altered candidate identity, evidence
hash drift, symlinks, automated-only substitution, or a non-owner operator fail
closed.

After exact-byte promotion, capture the authenticated public release object and
run `transition-public`; the command preserves every candidate byte/id while
requiring the canonical `releases/download/vX.Y.Z/Wrenflow.dmg` URL.

Run the contract tests with `mise run test-human-acceptance`.

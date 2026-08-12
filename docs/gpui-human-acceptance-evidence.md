# First-public-release owner smoke evidence

This is a two-row, owner-operated acceptance contract for the first public GPUI
release. There are no external testers, installed production cohort, or legacy
release population. It does not claim a fresh-account matrix that does not
exist.

The immutable candidate is still bound to all nine release assets, the exact
source commit, DMG SHA-256, Developer ID team, bundle identifier, Accepted
notarization submission, and workflow URL. The verifier never launches the app
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

Prepare an absolute non-symlink directory containing the exact nine assets and
an absolute retained evidence directory. Create a context file whose operator
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
  --evidence-root /absolute/owner-smoke \
  --context /absolute/owner-smoke/context.json \
  --artifact-url https://github.com/IlyaGulya/wrenflow/releases/download/vX.Y.Z/Wrenflow.dmg \
  --output /absolute/owner-smoke/owner-smoke-v1.json
```

Hash retained files with `hash-evidence`, fill only observations that actually
occurred, then verify:

```bash
mise run human-acceptance -- verify \
  --candidate-dir /absolute/private-draft-payload \
  --evidence-root /absolute/owner-smoke \
  --manifest /absolute/owner-smoke/owner-smoke-v1.json
```

`--allow-pending` is structural review only. It never satisfies release
acceptance. Unknown fields, missing rows, altered candidate identity, evidence
hash drift, symlinks, automated-only substitution, or a non-owner operator fail
closed.

Run the contract tests with `mise run test-human-acceptance`.

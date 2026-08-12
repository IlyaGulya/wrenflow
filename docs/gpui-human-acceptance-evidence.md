# GPUI M01-M12 and M17-M20 evidence contract

This contract makes the clean-account and accessibility matrix reproducible.
It does not execute an acceptance row. The tooling never launches Wrenflow,
opens System Settings, changes TCC, changes display or accessibility
preferences, creates users, operates login items, or edits evidence files.

The normative versioned sources of truth are:

- `support/acceptance/macos-human-v1-policy.json` for row ownership,
  classification and retained-evidence requirements;
- `scripts/gpui-human-acceptance.py` for strict payload and evidence
  verification.

`support/acceptance/macos-human-v1.schema.json` is the reviewable JSON Schema
mirror of the verifier's closed manifest shape. The verifier pins its exact
canonical JSON content and fails if the mirror drifts; the Python checks remain
normative, including constraints that JSON Schema cannot express conveniently.

M13 and M22 use the separate evidence verifier described in
`docs/gpui-endurance-acceptance.md`; M14-M16 and M21 follow the existing
endurance procedure in that document.

## Safety boundary

Every M01-M12 and M17-M20 final result is `named_human_required`. Automated
checks are either required or optional supporting evidence and can never
replace the tester, execution timestamp, machine/macOS/display context, or
retained human evidence. `--allow-pending` validates only an in-progress
manifest and is forbidden as a release gate.

The verifier checks that tester name and role are explicit, non-placeholder
fields and rejects normalized generic test identities. It does not authenticate a person's legal identity, verify a signature,
or prove who operated the machine. The release owner remains responsible for
the truthful attribution and retained manual evidence.

Run candidate steps only after `wrenflow-duh.9.8` publishes the immutable
Developer ID, Accepted-notarized payload and the product owner authorizes the
disposable-account/manual procedure owned by `wrenflow-duh.9.9` and
`wrenflow-duh.9.10`.

## Candidate payload

Place the exact downloaded release payload in a new non-symlink directory. It
must contain exactly these nine regular, non-symlink files and no others:

- `Wrenflow.dmg`;
- `Wrenflow.cdx.json`;
- `RustThirdPartyLicenses.txt`;
- `pins.json`;
- `exceptions.json`;
- `provenance.json`;
- `artifact-provenance.json`; and
- `release-evidence.json`; and
- `SHA256SUMS`.

`SHA256SUMS` must contain exactly one closed-format entry for each of the other
eight files. The initializer recomputes all eight hashes and also records the
checksum file's hash. It rejects missing or extra payload files, missing or
extra checksum entries, duplicate names, symlinks and digest drift.

The initializer cross-checks the release metadata contract: the DMG digest,
canonical tag/version/build and recorded canonical tag-asset URL; source commit; workflow run
and attempt; Team `T4LV8K9BGV`; bundle `me.gulya.wrenflow`; recorded Accepted
Apple submission; and the in-toto/SLSA subject, source dependency, pins,
workflow and notary bindings. This proves that the retained payload bytes and
their release metadata agree with one another. It does not independently query
GitHub or Apple, inspect the app inside the DMG, or prove current code-signing,
stapling or Gatekeeper behavior.

M01 is the live candidate check for those platform properties. Its retained
`artifact-verification` and visual evidence must come from mounting the exact
DMG and performing the authorized signature, notarization/stapling, Gatekeeper,
installation and first-open procedure on macOS. Payload metadata binding is
supporting input to M01, not a substitute for that observation.

## Initialize a pending manifest

Create an execution-context JSON file outside the repository. It names the
person who will actually execute the rows and the exact environment. Example:

```json
{
  "tester": {
    "name": "Ilya Gulya",
    "role": "release acceptance owner"
  },
  "machine": {
    "model": "MacBookPro18,4",
    "chip": "Apple M1 Max",
    "memory_gib": 64
  },
  "macos": {
    "version": "26.5.1",
    "build": "25F90"
  },
  "displays": [
    {
      "name": "Built-in Retina",
      "pixel_resolution": "3024x1964",
      "logical_resolution": "1512x982",
      "scale": 2
    }
  ]
}
```

Initialize a new manifest; the output path must not already exist:

```bash
mise run human-acceptance -- init \
  --candidate-dir /absolute/candidate-payload \
  --evidence-root /absolute/retained-evidence \
  --context /absolute/execution-context.json \
  --artifact-url https://github.com/IlyaGulya/wrenflow/releases/download/v0.4.0-beta.1/Wrenflow.dmg \
  --output /absolute/retained-evidence/macos-human-acceptance-v1.json
```

The generated rows are deliberately `pending`. Every row repeats the exact
candidate binding and execution context, preventing evidence from another
candidate, tester or host from being mixed into the release decision.

## Retain and bind evidence

Perform the authorized manual procedure without using this verifier to drive
the system. Keep privacy-reviewed evidence below the declared evidence root.
Do not retain audio, transcripts, vocabulary, credentials, device identifiers
or unrestricted paths.

Use the read-only helper to create an evidence descriptor:

```bash
mise run human-acceptance -- hash-evidence \
  --evidence-root /absolute/retained-evidence \
  --kind screen-recording \
  --relative-path M18/voiceover-run.mp4
```

Copy the emitted object into the row's `evidence` array. Supporting automated
artifacts go only in `automated_evidence` and must use kind
`automated-gate`. Set `executed_at` to an ISO-8601 timestamp with timezone and
set `result` to `pass`, `fail` or `blocked`. A failed or blocked row requires a
truthful note. A pass requires every evidence group declared by the policy;
alternatives such as a screen recording or screenshots are explicit in that
policy.

Evidence paths are relative to the fixed root. The verifier rejects absolute
paths, `..`, symlinks, missing/empty files, duplicate paths and SHA-256 drift.

## Verify

An in-progress structural check is:

```bash
mise run human-acceptance -- verify \
  --candidate-dir /absolute/candidate-payload \
  --evidence-root /absolute/retained-evidence \
  --manifest /absolute/retained-evidence/macos-human-acceptance-v1.json \
  --allow-pending
```

The final release gate omits `--allow-pending`:

```bash
mise run human-acceptance -- verify \
  --candidate-dir /absolute/candidate-payload \
  --evidence-root /absolute/retained-evidence \
  --manifest /absolute/retained-evidence/macos-human-acceptance-v1.json
```

Final verification fails unless all sixteen rows pass, every row binds to the
exact nine-file candidate payload, every tester/context field is
non-placeholder, all required human and automated evidence is retained, and
every file hash still matches. A successful verification proves the retained
manifest's structural completeness, payload/metadata binding and evidence-file
integrity. The named human and release owner remain responsible for the
underlying observations and attribution.

Run deterministic behavior tests with:

```bash
mise run test-human-acceptance
```

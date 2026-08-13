# First-public-release lifecycle acceptance

This contract covers only lifecycle risks that matter for a clean first
public installation. There are no legacy Wrenflow users or deployed stable
builds to migrate, downgrade, roll back, or update from.

## Blocking rows

| Row | Required evidence |
| --- | --- |
| L01 | On the exact private stable draft, the owner exercises sleep/wake and removal/reselection of an available audio device; one exact candidate process recovers without a stuck hotkey or overlay |
| L02 | On the exact session-bound owner-smoke disposable root used by S01/S02/L01, current-format corruption fails closed and the explicit current-data reset path restores a clean relaunch; no user data or TCC state is touched |
| L03 | Reuse the frozen beta.64 constrained result from Build 31603344709: exact source `d3e01e0ec085121f3bd3e78038836a16608b98a0`, DMG SHA-256 `d7a04beb4513026dda7f72847ab2c53a5c1a82861b49192c7c6ae6937b35e1a5`, and executable SHA-256 `3a2d786a31ac6491a88d3a3f9fa8b9d66f4991f5f5d32e507c0db3caf6f573af`; the release verifier must recompute exactly 24/24 |

L01 and L02 use the signed/notarized private stable draft. L03 is the immutable
automated performance baseline, not a claim that beta.64 is the stable release.
The acceptance-only changes made after that baseline do not change production
runtime/UI code or numeric budgets, so the 30-minute run is not repeated. The
stable draft is independently rebuilt, signed, notarized, Gatekeeper-verified,
and exercised by the owner core/lifecycle smoke. Every retained file is hashed
and path-contained; all three rows must pass.

## Explicit exclusions

Legacy/pre-GPUI migration, downgrade/rollback, beta-to-stable update behavior,
current-line update compatibility, and updater transaction SIGKILL injection
are not first-release blockers. The exhaustive physical Instruments suite and
updater fault injection are tracked as nonblocking post-launch P2 work. They
must not be silently relabeled as passing lifecycle evidence.

No command in this harness launches Wrenflow, resets TCC, or mutates app/user
data. Candidate execution is performed separately by the owner.

## Evidence commands

Authenticate one exact stable draft payload and create a mode-0600 plan:

```bash
WRENFLOW_TARGET_PAYLOAD=/absolute/private-stable-payload \
WRENFLOW_TARGET_RELEASE_METADATA=/absolute/private-release-metadata.json \
  mise exec -- scripts/gpui-endurance-preflight.sh candidate-plan \
  /absolute/evidence/candidate-plan.json
```

Every signed L01/L02 launch uses `mise run owner-smoke -- launch` with the same
unique app copy, disposable root and retained 32-hex session created for S01.
It remains an ordinary UI/runtime launch through LaunchServices; no synthetic
interaction or direct Mach-O execution is accepted.

After the owner has produced the closed L01-L03 manifest and retained files:

```bash
mise exec -- scripts/gpui-endurance-preflight.sh verify-evidence \
  /absolute/evidence/candidate-plan.json \
  /absolute/evidence/lifecycle-manifest.json \
  /absolute/evidence
```

Run source and negative tests with `mise run test-endurance-preflight`.

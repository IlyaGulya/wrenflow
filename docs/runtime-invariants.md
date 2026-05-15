# Runtime Invariants

This document captures the product/runtime rules that must remain true even as
the app architecture evolves.

## Sources Of Truth

- Rust owns durable product state.
- Flutter renders snapshots and sends user intent commands.
- Shell adapters expose platform capabilities and imperative OS actions.

The main Rust-owned snapshots/FSMs are:

- `SettingsSnapshot`
- `LocalModelsSnapshot`
- `PermissionsSnapshot`
- `AppSessionSnapshot`
- `RuntimeCapabilitiesSnapshot`

## Onboarding And Session

- `has_completed_setup = true` must never route the app back into onboarding.
- A completed setup session may stay in `Initializing` only while waiting for
  the first real permission snapshot.
- If setup is incomplete and both required permissions are already granted,
  onboarding must start at `Hotkey`, not at a permission step.
- Permission recovery is only valid after setup has completed.

## Local Models

- `selected model` and `active model` are different concepts.
- Changing the selected model only changes preference.
- A selected model must not be treated as ready unless it is also the active
  model and the runtime state is `Ready`.
- The UI must distinguish:
  - not downloaded
  - installed but inactive
  - downloading/loading/warming
  - active and ready
  - failed
- Model install status must not be inferred from directory existence alone.

## Recording And Transcription

- Recording must not start unless the product has a valid transcription path.
- If there is no active ready model, the app must fail before recording starts.
- Runtime/model unavailability must surface a user-facing action message, not a
  generic low-level error.
- The hotkey path must not rely on a later transcription failure to detect an
  invalid model state.

## Capability Separation

- `ShellCapabilitiesSnapshot` answers: "what can the shell integration do?"
- `RuntimeCapabilitiesSnapshot` answers: "what can the product backend do?"
- Startup-critical flows must not depend on delayed derived capability state if
  they can directly consult the underlying adapter/backend support.

## UX Rules

- Model actions must be visible on the selected model card itself.
- The app must not require users to infer a hidden two-step flow such as
  "select above, activate below".
- Error copy should tell the user what to do next:
  - download a model
  - activate the selected model
  - choose another model

## Regression Tests To Preserve

- completed setup + granted permissions => not onboarding
- incomplete setup + granted permissions => onboarding starts at `Hotkey`
- selected but inactive model => hotkey fails before recording starts
- missing model download => user gets a download guidance message

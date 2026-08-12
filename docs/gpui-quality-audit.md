# GPUI quality preflight audit

Status: implementation audit and post-fix verification for `wrenflow-duh.8`,
2026-08-09. The original preflight findings are retained below so the release
decision has an auditable before/after record. `.7` and the reproducible
code-hardening scope `.8` are closed. The former M01-M22 proposal is removed;
the blocking release contract is now
the truthful S01/S02 owner smoke plus L01-L03 clean-install lifecycle evidence.

## Scope and method

This audit treats Wrenflow as a native macOS menu-bar speech-to-text utility:
the settings/onboarding window is a task surface, while recording,
transcribing, errors and recovery also appear through native shell panels. It
reviews measurable source and runtime behavior only. `PRODUCT.md` and
`DESIGN.md` capture product and visual direction; subjective taste is not used
as a substitute for the measurable acceptance matrix below.

Evidence was gathered from the production GPUI crate, AppKit/Swift shell,
runtime FSM, build scripts, mise tasks and release workflow. Contrast values
were calculated from the shipped HSL tokens using sRGB relative luminance.
Existing automated gates provide useful functional evidence. Final full
`mise run check`, `mise run test` and `mise run lint` are green; the app result
is 70 tests (53 library, 17 shell/application), domain is 49 and runtime is 61
(53 library plus 8 runtime-contract tests).
The final signed Developer ID accessibility self-test opened the bundle through
LaunchServices and reported `nodes=6 generation=2` after visible-tree/modal and
scroll clipping; Rust and native node counts matched. This audit does not claim
fresh-account TCC, exhaustive Instruments, or an external tester cohort. The
owner spot checks remain explicit, narrow release rows.

Scoring rubric: **0** = absent/unusable, **1** = major release gaps, **2** =
partially adequate, **3** = solid with minor gaps, **4** = validated and
release-ready.

## Health score

| Dimension | Score | Evidence-based assessment |
| --- | ---: | --- |
| Accessibility | **3/4** | A real AppKit AX proxy tree now consumes stable GPUI semantics and exact prepaint geometry, round-trips typed actions, tracks focus, and publishes announcements. Keyboard/modal/focus/contrast defects are fixed and automated. S02 retains an owner VoiceOver spot check. |
| Performance | **4/4** | The frozen beta.64 constrained result on source `d3e01e0ec085121f3bd3e78038836a16608b98a0` passed all 24 release metrics. This acceptance-only scope changes no runtime/UI file or numeric budget; exhaustive physical traces remain post-launch P2 attribution. |
| Resizing and text scaling | **3/4** | A 640 px compact navigation breakpoint, bounded fluid content/dialog widths, wrapping, flexible control heights and rem-based typography are implemented. S02 retains available-host size/display spot checks. |
| Theming and contrast | **3/4** | Executable WCAG tests cover both palettes and production now supports app-local System/Light/Dark. Only System follows live macOS appearance; S02 retains owner Light/Dark spot checks. |
| Anti-patterns | **3/4** | The UI uses a restrained token set, system font and familiar macOS settings/navigation patterns. The main caveat is repetitive card treatment for nearly every block/row. |
| **Total** | **16/20 — Solid, owner smoke pending** | The code-level P0s and automated performance gate are fixed. Remaining score is held back by the explicit owner smoke, not by nonexistent external users. |

## Post-fix disposition

| Finding | Status and current evidence |
| --- | --- |
| A11Y-01 | **Implemented and signed-smoke-tested; manual VoiceOver validation pending.** `AppScreens::accessibility_snapshot` and `perform_accessibility_action` publish/consume the stable schema ([screens/mod.rs:445-520](../native/wrenflow-gpui/src/screens/mod.rs)); `MeasuredElement` reports real GPUI prepaint bounds without altering layout ([accessibility.rs:131-195](../native/wrenflow-gpui/src/ui/accessibility.rs)). Swift owns real `NSAccessibilityElement` proxies, focus/value/press actions and notifications ([WrenflowAccessibilityBridge.swift:94-208](../native/wrenflow-gpui/macos/WrenflowAccessibilityBridge.swift)). The signed self-test passed with six currently visible nodes and matching Rust/native counts. |
| REL-01 | **Fixed.** Publish now explicitly requires signing/notarization credentials and verifies the exact artifact with `--require-notarized` before upload ([build.yml:120-133](../.github/workflows/build.yml), [build.yml:208-212](../.github/workflows/build.yml)). |
| PERF-01 | **Fixed in code; Instruments pending.** Audio level delivery is latest-value sampled and the 50-source regression proves one presentation frame ([model.rs:226-269](../native/wrenflow-gpui/src/app/model.rs), [model.rs:432-445](../native/wrenflow-gpui/src/app/model.rs)). |
| A11Y-02 | **Fixed in code; manual traversal pending.** The dialog disables background controls, focuses Cancel next frame, handles Escape and restores the invoking control ([screens/mod.rs:694-719](../native/wrenflow-gpui/src/screens/mod.rs), [screens/mod.rs:1425-1513](../native/wrenflow-gpui/src/screens/mod.rs)). |
| A11Y-03 | **Fixed for GPUI; native overlay retest pending.** Both palettes have executable 4.5:1 text and 3:1 non-text assertions ([theme.rs:227-249](../native/wrenflow-gpui/src/ui/theme.rs)); controls render a contrasting inner border plus outer focus outline. |
| LAYOUT-01 | **Fixed in code; S02 spot check pending.** Fluid max widths, compact navigation, wrapping, flexible heights and rem typography are tokenized ([theme.rs:15-40](../native/wrenflow-gpui/src/ui/theme.rs), [screens/mod.rs:887-929](../native/wrenflow-gpui/src/screens/mod.rs)). |
| INPUT-01 | **Fixed and unit-tested.** Capture requires explicit listening; Tab navigates, Escape cancels, unsupported keys are ignored and state is announced ([screens/mod.rs:102-155](../native/wrenflow-gpui/src/screens/mod.rs), [screens/mod.rs:1550-1576](../native/wrenflow-gpui/src/screens/mod.rs)). |
| FSM-01 | **Fixed.** The dead `Pasting`/dismiss contract was removed; success emits ordered transcript/paste events and returns immediately to `Idle`. `basic_flow` and immediate-restart coverage are green in the 47-test domain result. |
| A11Y-04 | **Fixed and unit-tested.** Button labels and switch values update in place, retaining their entities/focus handles ([controls.rs:77-84](../native/wrenflow-gpui/src/ui/controls.rs), [controls.rs:234-240](../native/wrenflow-gpui/src/ui/controls.rs), [controls.rs:625-701](../native/wrenflow-gpui/src/ui/controls.rs)). |
| A11Y-05 | **Implemented for the semantic notice path; manual native-overlay validation pending.** Serial priority announcements are bridged to AppKit and transient errors retain a persistent settings recovery path. Real VoiceOver behavior remains an external validation item. |
| THEME-01, DISPLAY-01, MOTION-01 | **Implemented and regression-tested; S02 owner spot checks pending.** App-local System/Light/Dark is live, only System follows macOS changes, native overlays resolve the active display without `NSScreen.main`, and injected contrast/motion/transparency preferences exercise deterministic behavior. |
| IA-01 | **Deferred P3.** Card hierarchy remains consistent but dense; no speculative visual redesign was made without product/design direction. |

The detailed findings below describe the pre-fix evidence and impact. The table
above is authoritative for current disposition.

### Anti-pattern verdict first

The implementation does **not** show the usual generated-UI excesses: there
are no gradients, glass effects, oversized marketing type, decorative charts,
bouncy interactions or arbitrary font stacks. The visual structure is coherent
for a utility app. The one repeated pattern worth distilling is the use of a
bordered `Card` for almost every preference, model and history row
([settings.rs:13-58](../native/wrenflow-gpui/src/screens/settings.rs),
[history.rs:31-34](../native/wrenflow-gpui/src/screens/history.rs)); it adds
container density where native grouped rows could provide clearer hierarchy.

## Findings

### P0 — Blocking

#### A11Y-01: VoiceOver has no accessibility tree or actionable controls

The UI module explicitly records that GPUI 0.2.2/gpui-component 0.5.1 exposes no
accessibility tree, roles or `NSAccessibility` bridge and calls VoiceOver parity
a release blocker ([ui/README.md:17-40](../native/wrenflow-gpui/src/ui/README.md)).
`ControlSemantics` is only a Rust snapshot ([semantics.rs:1-24](../native/wrenflow-gpui/src/ui/semantics.rs)); there is no `NSAccessibility` implementation in the AppKit shell. Keyboard support in
`AccessibleButton`/`AccessibleSwitch` is a positive fallback, not a VoiceOver
equivalent ([controls.rs:20-26](../native/wrenflow-gpui/src/ui/controls.rs),
[controls.rs:107-168](../native/wrenflow-gpui/src/ui/controls.rs)). Native
recording/transcribing/error panels likewise expose no explicit live-region or
announcement behavior.

Impact: a VoiceOver user cannot discover labels, roles, values, progress,
navigation, dialogs or status transitions in the primary product surface.

Acceptance evidence: an AppKit accessibility bridge (or supported upstream
tree) must publish stable roles, labels, values, enabled/checked state, frames
and actions; focus changes, dialogs, progress and transient status must be
announced. Verify with Accessibility Inspector and VoiceOver across every row
in the manual matrix, including when the settings window is hidden.

#### REL-01: release publishing fails open when notarization credentials are absent

CI computes `HAS_NOTARIZE` from a secret
([build.yml:24-29](../.github/workflows/build.yml)), conditionally skips the
notary submission/staple when it is false
([build.yml:162-175](../.github/workflows/build.yml)), but still uploads stable
and beta DMGs ([build.yml:185-205](../.github/workflows/build.yml)). Local
`mise run release` verifies only code signing
([mise.toml:34-37](../mise.toml)); bundle assembly likewise stops at
`codesign --verify` ([build-app.sh:62-75](../native/wrenflow-gpui/scripts/build-app.sh)).

Impact: the official pipeline can publish a hardened-signed but unnotarized
artifact, making clean-account Gatekeeper behavior dependent on CI secret
configuration instead of a release invariant.

Acceptance evidence: release/beta publication must fail closed without signing
and notarization inputs. Before upload, verify the app and DMG signatures,
notary success, stapled ticket and `spctl --assess` on a downloaded artifact.

### P1 — Major

#### PERF-01: 50 Hz audio levels rebuild and render the whole application presentation

Audio capture publishes levels at approximately 50 Hz
([audio_capture.rs:481-488](../core/wrenflow-core/src/audio_capture.rs)).
`AppModel` subscribes to every change
([model.rs:235-249](../native/wrenflow-gpui/src/app/model.rs)); each distinct
level rebuilds the complete `AppPresentation` and notifies observers
([reducer.rs:122-129](../native/wrenflow-gpui/src/app/reducer.rs),
[model.rs:198-202](../native/wrenflow-gpui/src/app/model.rs)). The root observes
that entity and clones the complete presentation during render
([screens/mod.rs:251-264](../native/wrenflow-gpui/src/screens/mod.rs),
[screens/mod.rs:830-835](../native/wrenflow-gpui/src/screens/mod.rs)). Rebuilding
history clones every retained transcript/metadata record
([presentation.rs:476-505](../native/wrenflow-gpui/src/app/presentation.rs)); the
runtime caps the collection at 50
([history.rs:124-136](../core/wrenflow-runtime/src/history.rs)). A separate
subscription already sends the same levels directly to the native overlay
([main.rs:455-460](../native/wrenflow-gpui/src/main.rs)).

Impact: recording can allocate and invalidate the complete settings tree at a
high-frequency sensor rate even though only a tiny overlay waveform changes.
The risk grows with long history transcripts and is not covered by current unit
tests.

Acceptance evidence: keep audio-level state outside the full presentation or
scope observation to the one visible consumer. Record Instruments allocations,
main-thread time, frame pacing and memory for idle, 60 seconds of recording and
20 full transcription cycles; demonstrate no full history/screen projection per
level and no monotonic memory growth.

#### A11Y-02: dialog overlay does not establish modal keyboard semantics

`DialogSurface` is a visual `div` with no focus handle, focus trap, initial
focus, Escape action or restoration target
([controls.rs:506-568](../native/wrenflow-gpui/src/ui/controls.rs)). The clear
history overlay is appended over the still-mounted page
([screens/mod.rs:797-826](../native/wrenflow-gpui/src/screens/mod.rs)); its
background buttons remain tab stops.

Impact: keyboard focus can remain behind a destructive confirmation, escape the
dialog, or be lost when it closes. VoiceOver modal grouping will also be wrong
until A11Y-01 is fixed.

Acceptance evidence: opening focuses the least-destructive/default control,
Tab/Shift-Tab remain inside, Escape cancels, Enter follows an explicit default,
background actions are inert, and closing restores focus to “Clear all”.

#### A11Y-03: light primary/status text and focused primary outline lack contrast

The light accent is `hsl(199 82% 45%)` with white foreground
([theme.rs:65-81](../native/wrenflow-gpui/src/ui/theme.rs)); primary buttons use
that pair ([controls.rs:117-122](../native/wrenflow-gpui/src/ui/controls.rs)) and
14 px body-sized labels. The calculated ratio is **3.35:1**, below 4.5:1 for
normal text. Success text renders the accent directly on the light background
([screens/mod.rs:620-647](../native/wrenflow-gpui/src/screens/mod.rs)) at
**3.20:1**. The focused primary border changes from accent to a very similar
focus color ([controls.rs:139-160](../native/wrenflow-gpui/src/ui/controls.rs));
the focused/unfocused boundary contrast is approximately **1.10:1** in light
and **1.17:1** in dark mode. The native error toast uses 13 pt white text on
`rgb(0.95, 0.3, 0.3)`
([WrenflowOverlayController.swift:74-80](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift),
[WrenflowOverlayController.swift:325-349](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift)) at **3.54:1**.

Impact: primary labels/status and focus location are hard to perceive for
low-vision and keyboard users.

Acceptance evidence: token-level contrast tests must enforce at least 4.5:1 for
normal text and 3:1 for focus/non-text indicators against adjacent colors in
both appearances, disabled states included.

#### LAYOUT-01: fixed geometry has no supported compact or larger-text behavior

Production opens at 760×620 with no declared content minimum
([main.rs:101-113](../native/wrenflow-gpui/src/main.rs)). Centered flows force a
680 px inner width and only vertical scrolling
([screens/mod.rs:480-515](../native/wrenflow-gpui/src/screens/mod.rs)); application
screens reserve a fixed 220 px sidebar
([theme.rs:130-139](../native/wrenflow-gpui/src/ui/theme.rs),
[settings.rs:257-272](../native/wrenflow-gpui/src/ui/settings.rs)). Typography is
fixed at 12/14/20/28 px, with a fixed 20 px body line height
([theme.rs:120-127](../native/wrenflow-gpui/src/ui/theme.rs)); buttons are 32 px
high ([controls.rs:147-167](../native/wrenflow-gpui/src/ui/controls.rs)).

Impact: narrow user-resized windows and effective larger-text/display scaling
can clip content or controls; fixed line height can collide with enlarged text.
There is no documented smallest supported size or test.

Acceptance evidence: define a minimum window size, a compact sidebar/content
layout, wrap/truncation policy and scalable typography/line-height tokens. Test
every screen at the minimum, default and wide sizes plus 125%, 150% and 200%
effective text/display scaling without horizontal clipping or unreachable
controls.

#### INPUT-01: custom hotkey capture consumes navigation/cancel keys as product shortcuts

`HotkeyCapture` maps any recognized key received while focused to a global
target, because `capture` does not require `listening == true`
([screens/mod.rs:81-100](../native/wrenflow-gpui/src/screens/mod.rs)); its mapping
explicitly includes Tab and Escape
([screens/mod.rs:185-218](../native/wrenflow-gpui/src/screens/mod.rs)). There is
no listening-state Escape cancellation, key filter, or timeout. Focus can
therefore turn the user’s next Tab/Escape into the saved push-to-talk key.

Impact: keyboard users can lose expected navigation/cancel behavior and bind a
shortcut that is difficult to recover from.

Acceptance evidence: use an explicit capture mode with announced state; Escape
cancels, Tab preserves navigation unless intentionally accepted through another
gesture, unsupported/reserved keys explain why they were rejected, and focus
returns predictably after save/cancel.

#### FSM-01: successful transcription has contradictory `Pasting` lifecycle

The domain type retains `Pasting`, labels it “Copied to clipboard!”, and exposes
a three-second dismiss transition
([pipeline.rs:23-58](../core/wrenflow-domain/src/pipeline.rs),
[pipeline.rs:269-276](../core/wrenflow-domain/src/pipeline.rs)). The success
implementation instead calls the paste listener and transitions directly to
`Idle` ([pipeline.rs:279-305](../core/wrenflow-domain/src/pipeline.rs)), while
`basic_flow` still expects `Pasting`
([pipeline.rs:384-422](../core/wrenflow-domain/src/pipeline.rs)). No runtime caller
of `on_dismiss_timeout` exists. The `.8` register records the current result as
46/47 domain tests passing.

Impact: the intended success feedback/restart policy is undefined, the domain
gate is red, and UI/overlay parity cannot be accepted against contradictory
behavior.

Acceptance evidence: choose and document one FSM contract. If `Pasting` is a
visible transient state, enter it, schedule/cancel dismissal and specify hotkey
restart behavior; if success is intentionally immediate `Idle`, remove the dead
state/timer contract and update presentation/tests. All domain/runtime/UI tests
must agree.

#### A11Y-04: focus-bearing entities are replaced during normal state changes

Button entities are recreated whenever a label changes
([screens/mod.rs:354-382](../native/wrenflow-gpui/src/screens/mod.rs)); switch
entities are recreated whenever checked state changes
([screens/mod.rs:385-417](../native/wrenflow-gpui/src/screens/mod.rs)). Their
`FocusHandle`s live inside those entities
([controls.rs:46-66](../native/wrenflow-gpui/src/ui/controls.rs),
[controls.rs:179-200](../native/wrenflow-gpui/src/ui/controls.rs)). History's
focused “Show details” entity is specifically replaced by “Hide details” after
activation ([history.rs:99-112](../native/wrenflow-gpui/src/screens/history.rs)).

Impact: activating a switch or receiving an async label/status update can drop
keyboard focus and will also invalidate future accessibility proxy identity.

Acceptance evidence: update label/value in stable entities, preserve focus
through async state changes, and add interaction tests that activate each
switch/button then assert focus remains/restores correctly.

#### A11Y-05: native overlay status and recovery are not announced or keyboard-operable

Recording/transcribing/error transitions only mutate/show native panels
([WrenflowOverlayController.swift:29-54](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift)); no accessibility announcement is posted. Actionable errors use a
`.nonactivatingPanel` and auto-dismiss after six seconds
([WrenflowOverlayController.swift:54-98](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift),
[WrenflowOverlayController.swift:112-127](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift)).

Impact: a user who cannot see the transient overlay receives no recording,
transcribing or failure feedback and cannot reliably reach its recovery action
without a pointer before it disappears.

Acceptance evidence: post appropriate status announcements, expose the error
and action to keyboard/VoiceOver, and retain a persistent recovery path after
the transient panel closes.

### P2 — Moderate

#### THEME-01: app-local appearance is implemented; S02 spot check remains

Production derives the live semantic palette from the GPUI window appearance.
The app-local preference has three closed values: System clears the AppKit
override and follows macOS live, while Light and Dark pin only Wrenflow and do
not mutate System Settings. Both token sets and the rule that explicit overrides
ignore system changes are executable regressions. Swift publishes injected
Increase Contrast, Differentiate Without Color, Reduce Motion and Reduce
Transparency observations through the typed boundary.

Remaining acceptance evidence: run the signed S02 appearance spot check and
record the live titlebar/content/native-panel result for each combination.

#### DISPLAY-01: native overlays resolve and track the active display

Recording, transcribing and actionable-error overlays resolve mouse display,
then key/main window display, then the first available screen. They store the
display identity, observe screen-parameter and active-Space changes, and keep
placement inside the target screen's safe area. Production contains no
`NSScreen.main` fallback; the source regression enforces that boundary.

Remaining acceptance evidence: run the signed S02 check on available displays,
Spaces, full-screen, notch/no-notch, resolution changes and unplug during
recording.

#### MOTION-01: native status motion follows accessibility preferences

Reduce Motion bypasses frame/alpha transitions and continuous phase animation;
Reduce Transparency and non-color differentiation are also injected into the
native/UI presentation contract. Pure tests verify geometry remains stable and
non-color cues become stronger under the injected accessibility preferences.

Remaining acceptance evidence: run the signed owner S02 spot check and confirm each
native status remains understandable with motion and transparency reduced.

### P3 — Minor

#### IA-01: pervasive cards reduce information hierarchy

General settings wraps each preference in a separate card
([settings.rs:13-58](../native/wrenflow-gpui/src/screens/settings.rs)); history
maps every entry to a card
([history.rs:31-34](../native/wrenflow-gpui/src/screens/history.rs)). Models use
the same planning vocabulary. This is consistent, but the repeated bordered
containers make headings, rows and actions visually similar.

Acceptance evidence: after release blockers are fixed, compare a native grouped
list/section treatment with the current card stack at default and narrow widths;
retain cards only where they convey a distinct object or state.

## Positive systemic evidence

- Critical buttons and switches have real tab stops, disabled handling, visible
  focus tokens and Space/Enter bindings
  ([controls.rs:20-26](../native/wrenflow-gpui/src/ui/controls.rs),
  [controls.rs:94-168](../native/wrenflow-gpui/src/ui/controls.rs),
  [controls.rs:233-305](../native/wrenflow-gpui/src/ui/controls.rs)).
- Screens consume immutable presentation data and dispatch typed `AppAction`s;
  runtime/AppKit ownership stays outside the screen tree
  ([screens/mod.rs:1-4](../native/wrenflow-gpui/src/screens/mod.rs),
  [screens/mod.rs:318-351](../native/wrenflow-gpui/src/screens/mod.rs)).
- Loading, empty, error, pending and destructive-confirmation paths are
  explicitly projected and unit-tested rather than hidden in ad-hoc view state.
- History retention is bounded at 50 records in memory/storage, limiting the
  unvirtualized-list worst case
  ([history.rs:124-136](../core/wrenflow-runtime/src/history.rs)).
- Bundle construction enables hardened runtime, signs nested binaries before
  the app, validates the plist and runs strict signature verification
  ([build-app.sh:55-75](../native/wrenflow-gpui/scripts/build-app.sh)).

## Superseded pre-release matrix

The former M01-M22 table was never executed and is not a current release
contract. It has been removed rather than left as pending or implied evidence.
The current closed contracts are S01/S02 in
`docs/gpui-human-acceptance-evidence.md` and L01-L03 in
`docs/gpui-endurance-acceptance.md`. No new-account/TCC reset, legacy migration,
updater fault matrix, external tester cohort, or exhaustive Instruments run is
required for the first public release.

The obsolete row list has been deleted rather than left as a wall of permanently
pending pseudo-requirements. Git history preserves it for audit. The two P2
follow-ups retain the useful physical-attribution and updater-fault ideas.

## `.8` acceptance checklist

### Release prerequisites

- [x] `wrenflow-duh.7` is closed and final Flutter/Rinf packaging removal is
  verified; production reads only the current `gpui-v1` format and leaves
  pre-GPUI roots untouched.
- [x] A11Y-01 and REL-01 are fixed in code and the signed AX smoke test passes;
  human/credential validation is tracked separately and is not claimed here.
- [x] FSM-01 has one documented implementation and all domain/runtime/UI tests
  agree.

### Automated gates

- [x] `mise run check`, `mise run lint` and `mise run test` are green from a
  clean checkout with the locked workspaces and required ORT dylib.
- [x] Domain `pipeline::tests::basic_flow` passes under the chosen immediate
  `Idle` contract; the final domain result is 48/48.
- [x] Token tests cover normal text, primary/status colors, focus indicators,
  inactive controls and both appearances using explicit 4.5:1/3:1 thresholds.
- [ ] Manual larger-text, native-overlay and disabled-state appearance evidence
  remains part of the external matrix.
- [x] GPUI interaction tests cover Space/Enter, hotkey capture/cancel/rejection,
  stable focus after state updates, modal background exclusion/clipping and
  disabled controls. Signed/manual traversal still covers complete tab cycling.
- [x] Accessibility bridge tests validate camel-case schema, reject zero-sized
  geometry, decode typed actions and compare native/Rust node counts in the
  signed app.
- [ ] Manual Accessibility Inspector/VoiceOver action execution remains
  external evidence; semantic Rust snapshots alone are not treated as proof.
- [x] Audio-level updates are latest-value sampled and the 50-source regression
  proves a single latest presentation frame without rebuilding full history.
- [ ] Instruments idle/recording/endurance baselines remain external evidence.
- [x] CI refuses stable and beta publication without Developer ID signing,
  successful notarization and stapling.
- [ ] The downloaded Apple-notarized candidate still requires credentialed
  submission and clean-machine `stapler`/`spctl` evidence.

The superseding P0 release-validation issue `wrenflow-duh.9` owns every
unchecked automated or manual evidence row above/below. These boxes are
intentionally not marked done by source inspection or by an ad-hoc local
bundle.

### Owner acceptance

- [ ] S01 records the exact private draft's clean install/Gatekeeper and core
  microphone, hotkey, paste, Settings, model and History smoke on the available
  physical host without resetting TCC.
- [ ] S02 records keyboard, VoiceOver, appearance, display/scale and window-size
  spot checks on that exact candidate.
- [ ] L01-L03 record sleep/wake/audio-device behavior, disposable current-data
  corruption/reset, and the frozen beta.64 sealed 24/24 performance baseline.
- [ ] Post-launch exhaustive physical traces and updater fault injection remain
  explicitly nonblocking P2 work.

### Exit criteria

- [ ] Every P1 is fixed or explicitly waived by the product owner with bounded
  impact and follow-up issue; no accessibility, trust or data-loss risk may be
  waived for release.
- [ ] P2/P3 follow-ups have owners and acceptance tests.
- [ ] The release candidate tested manually is byte-identical to the published
  artifact and its notarization evidence is retained.
- [x] The code-hardening scope closed after remaining owner observations were
  moved into the truthful S01/S02/L01-L03 P0 release contract.
- [ ] The GPUI production release is not release-ready until every blocking P0
  validation issue passes against the byte-identical candidate.

## Fix-slice disposition

1. **Completed — accessibility bridge:** stable semantic IDs/frames, AppKit
   `NSAccessibilityElement` proxies, actions/value changes/live announcements
   and a signed AX-tree smoke test; manual VoiceOver stays external.
2. **Completed — keyboard/focus hardening:** modal focus manager, Escape/default
   actions and restoration, stable control entities and an explicit cancelable
   hotkey capture state with reserved-key policy.
3. **Completed in code — contrast and app-local appearance:** System/Light/Dark,
   live System observation and injected accessibility-display regressions are
   green; execute the S02 owner appearance spot check before release.
4. **Completed in code — render-path optimization:** 50 Hz overlay delivery is
   direct and presentation frames are sampled; profile allocations/main-thread/
   frame pacing under maximum history in release validation.
5. **Completed in code — adaptive layout:** compact navigation, fluid geometry,
   rem typography and wrapping are implemented; execute the size/scale matrix.
6. **Completed — pipeline FSM contract:** immediate `Idle` after ordered paste
   events is documented and covered by restart/domain tests.
7. **Completed in CI — release fail-closed:** signing/notary credentials,
   Accepted status, staple and exact-artifact checks are required; submit and
   assess the actual candidate in release validation.
8. **Completed in code — overlay environment policy:** active-display and
   Space/topology tracking, safe-area placement and Reduce Motion behavior are
   implemented; execute the S02 owner display/appearance spot check on real hardware.
9. **Deferred P3 — hierarchy distillation:** replace repetitive card stacks
   only with product/design direction and narrow/text-scale evidence.

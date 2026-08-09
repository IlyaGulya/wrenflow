# GPUI quality preflight audit

Status: implementation audit and post-fix verification for `wrenflow-duh.8`,
2026-08-09. The original preflight findings are retained below so the release
decision has an auditable before/after record. `.7` and the reproducible
code-hardening scope `.8` are closed. Unchecked clean-account/manual rows remain
blocking P0 work in `wrenflow-duh.9`, not proof that those scenarios passed.

## Scope and method

This audit treats Wrenflow as a native macOS menu-bar speech-to-text utility:
the settings/onboarding window is a task surface, while recording,
transcribing, errors and recovery also appear through native shell panels. It
reviews measurable source and runtime behavior only. `PRODUCT.md` and
`DESIGN.md` do not exist, so brand personality and subjective visual direction
are deliberately out of scope.

Evidence was gathered from the production GPUI crate, AppKit/Swift shell,
runtime FSM, build scripts, mise tasks and release workflow. Contrast values
were calculated from the shipped HSL tokens using sRGB relative luminance.
Existing automated gates provide useful functional evidence. Final full
`mise run check`, `mise run test` and `mise run lint` are green; the app result
is 45 tests (35 library, 10 shell/application), domain is 48 and runtime is 14.
The final signed Developer ID accessibility self-test opened the bundle through
LaunchServices and reported `nodes=6 generation=2` after visible-tree/modal and
scroll clipping; Rust and native node counts matched. This audit still has not
executed the clean-account VoiceOver, TCC, Apple notary, Instruments or
multi-display matrix below. A code path is therefore not awarded 4/4 merely
because it exists.

Scoring rubric: **0** = absent/unusable, **1** = major release gaps, **2** =
partially adequate, **3** = solid with minor gaps, **4** = validated and
release-ready.

## Health score

| Dimension | Score | Evidence-based assessment |
| --- | ---: | --- |
| Accessibility | **3/4** | A real AppKit AX proxy tree now consumes stable GPUI semantics and exact prepaint geometry, round-trips typed actions, tracks focus, and publishes announcements. Keyboard/modal/focus/contrast defects are fixed and automated. Signed-app VoiceOver/Inspector traversal is still required for 4/4. |
| Performance | **3/4** | Audio updates are latest-value sampled to 33 ms frames and rebuild only the transcription-test projection; the native overlay retains its direct feed. No Instruments/endurance baseline exists, so 4/4 is not claimed. |
| Resizing and text scaling | **3/4** | A 640 px compact navigation breakpoint, bounded fluid content/dialog widths, wrapping, flexible control heights and rem-based typography are implemented. The manual size/125–200% matrix remains unexecuted. |
| Theming and contrast | **2/4** | Executable WCAG tests now cover both palettes: light primary text is 4.73:1, accent status text is 4.52:1, inactive tracks exceed 3:1, and two-tone focus indicators exceed 3:1. Production still forces light appearance and native appearance preferences remain separate work. |
| Anti-patterns | **3/4** | The UI uses a restrained token set, system font and familiar macOS settings/navigation patterns. The main caveat is repetitive card treatment for nearly every block/row. |
| **Total** | **14/20 — Solid, manual hardening pending** | The code-level P0s are fixed. Remaining score is held back by unexecuted signed-app/manual evidence and open environment-policy findings, not by the retired Flutter surface. |

## Post-fix disposition

| Finding | Status and current evidence |
| --- | --- |
| A11Y-01 | **Implemented and signed-smoke-tested; manual VoiceOver validation pending.** `AppScreens::accessibility_snapshot` and `perform_accessibility_action` publish/consume the stable schema ([screens/mod.rs:445-520](../native/wrenflow-gpui/src/screens/mod.rs)); `MeasuredElement` reports real GPUI prepaint bounds without altering layout ([accessibility.rs:131-195](../native/wrenflow-gpui/src/ui/accessibility.rs)). Swift owns real `NSAccessibilityElement` proxies, focus/value/press actions and notifications ([WrenflowAccessibilityBridge.swift:94-208](../native/wrenflow-gpui/macos/WrenflowAccessibilityBridge.swift)). The signed self-test passed with six currently visible nodes and matching Rust/native counts. |
| REL-01 | **Fixed.** Publish now explicitly requires signing/notarization credentials and verifies the exact artifact with `--require-notarized` before upload ([build.yml:120-133](../.github/workflows/build.yml), [build.yml:208-212](../.github/workflows/build.yml)). |
| PERF-01 | **Fixed in code; Instruments pending.** Audio level delivery is latest-value sampled and the 50-source regression proves one presentation frame ([model.rs:226-269](../native/wrenflow-gpui/src/app/model.rs), [model.rs:432-445](../native/wrenflow-gpui/src/app/model.rs)). |
| A11Y-02 | **Fixed in code; manual traversal pending.** The dialog disables background controls, focuses Cancel next frame, handles Escape and restores the invoking control ([screens/mod.rs:694-719](../native/wrenflow-gpui/src/screens/mod.rs), [screens/mod.rs:1425-1513](../native/wrenflow-gpui/src/screens/mod.rs)). |
| A11Y-03 | **Fixed for GPUI; native overlay retest pending.** Both palettes have executable 4.5:1 text and 3:1 non-text assertions ([theme.rs:227-249](../native/wrenflow-gpui/src/ui/theme.rs)); controls render a contrasting inner border plus outer focus outline. |
| LAYOUT-01 | **Fixed in code; M20 pending.** Fluid max widths, compact navigation, wrapping, flexible heights and rem typography are tokenized ([theme.rs:15-40](../native/wrenflow-gpui/src/ui/theme.rs), [screens/mod.rs:887-929](../native/wrenflow-gpui/src/screens/mod.rs)). |
| INPUT-01 | **Fixed and unit-tested.** Capture requires explicit listening; Tab navigates, Escape cancels, unsupported keys are ignored and state is announced ([screens/mod.rs:102-155](../native/wrenflow-gpui/src/screens/mod.rs), [screens/mod.rs:1550-1576](../native/wrenflow-gpui/src/screens/mod.rs)). |
| FSM-01 | **Fixed.** The dead `Pasting`/dismiss contract was removed; success emits ordered transcript/paste events and returns immediately to `Idle`. `basic_flow` and immediate-restart coverage are green in the 47-test domain result. |
| A11Y-04 | **Fixed and unit-tested.** Button labels and switch values update in place, retaining their entities/focus handles ([controls.rs:77-84](../native/wrenflow-gpui/src/ui/controls.rs), [controls.rs:234-240](../native/wrenflow-gpui/src/ui/controls.rs), [controls.rs:625-701](../native/wrenflow-gpui/src/ui/controls.rs)). |
| A11Y-05 | **Implemented for the semantic notice path; manual native-overlay validation pending.** Serial priority announcements are bridged to AppKit and transient errors retain a persistent settings recovery path. Real VoiceOver behavior remains an external validation item. |
| THEME-01, DISPLAY-01, MOTION-01 | **Open release-validation policy items.** Production still forces light appearance, overlays use the existing main-display policy, and reduced-motion behavior requires the manual environment matrix. |
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

#### THEME-01: dark tokens exist but production and overlays force fixed appearances

The token module defines light and dark palettes
([theme.rs:65-105](../native/wrenflow-gpui/src/ui/theme.rs)), but production
always calls `ui::init(...ThemeMode::Light)`
([main.rs:84-87](../native/wrenflow-gpui/src/main.rs)). Native recording panels
force light and error panels force dark regardless of system appearance
([WrenflowOverlayController.swift:74-80](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift),
[WrenflowOverlayController.swift:130-149](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift)). No effective-appearance or Increase Contrast observation is present.

Impact: titlebar/content/overlay appearance can disagree with macOS, and the
untested dark token set provides false confidence.

Acceptance evidence: follow system appearance changes live, test both token
sets and native panels, and verify Dark Mode, Increase Contrast, Differentiate
Without Color and Reduce Transparency.

#### DISPLAY-01: transient overlays target `NSScreen.main` and do not track display changes

Errors, notch geometry, recording and transcribing panels all resolve placement
from `NSScreen.main`
([WrenflowOverlayController.swift:83-88](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift),
[WrenflowOverlayController.swift:152-178](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift),
[WrenflowOverlayController.swift:210-236](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift)). No active-cursor/frontmost-window display policy or screen-parameter observer is present. Existing panels are only reframed when the same phase is shown again.

Impact: dictating on a secondary display, moving between Spaces, hot-plugging a
display or changing resolution can place feedback on a different display or at
stale notch coordinates.

Acceptance evidence: define the target-display policy and re-resolve it for
every show and display/Space change. Run the multi-display/Spaces/notch rows
below, including unplug during recording.

#### MOTION-01: native status panels ignore Reduce Motion

Panels animate frame/alpha unconditionally
([WrenflowOverlayController.swift:89-98](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift),
[WrenflowOverlayController.swift:197-217](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift)); waveform/dots animate continuously
([WrenflowOverlayController.swift:265-319](../native/wrenflow-gpui/macos/WrenflowOverlayController.swift)).

Impact: reduced-motion preferences are ignored; continuous spring/dot movement
can remain active throughout recording/transcription.

Acceptance evidence: suppress or simplify frame/alpha, dot and spring animation
under Reduce Motion and verify that state remains equally understandable.

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

## Clean-account manual validation matrix

Run this on a new macOS user account with no Wrenflow preferences, TCC grants,
models, history or launch-at-login registration. Install the exact downloaded
signed/notarized DMG in `/Applications`; record macOS/hardware/display versions,
artifact hash, signing identity, timestamps, screenshots/video and pass/fail for
every row. Do not substitute a terminal-launched binary for LaunchServices.

| ID | Scenario and setup | Expected measurable result | Preflight status |
| --- | --- | --- | --- |
| M01 | Gatekeeper: download DMG, verify hash, mount, drag to Applications, first open | `codesign --verify --deep --strict`, `xcrun stapler validate` and `spctl --assess --type execute -vv` pass; no unidentified/developer-damaged warning; bundle/version/team match release metadata | **Not run; CI is fail-closed, actual Apple candidate is external** |
| M02 | Fresh launch with both TCC states unknown | Menu item appears; onboarding opens once; no terminal is responsible process; permission state matches System Settings | Not run |
| M03 | Microphone: allow on first prompt | One system prompt; state becomes granted without relaunch; device list loads; a recording captures non-zero audio | Not run |
| M04 | Microphone: deny, retry, open settings, grant | No prompt loop; denial explains recovery; correct Privacy pane opens; grant is detected within the documented poll interval and recording succeeds | Not run |
| M05 | Accessibility: deny, open settings, grant, then revoke while running | Hotkey/paste availability and explanation track real TCC state; correct pane opens; grant/revocation is detected without corrupting pipeline state | Not run |
| M06 | Global hotkey: presets and custom capture, key down/repeat/release, very short press | Exactly one start/stop per physical press; repeat ignored; duration threshold respected; Tab/Escape remain keyboard navigation/cancel controls | Automated capture policy green; manual not run |
| M07 | Paste into TextEdit plus one Chromium and one Electron target | Transcript is inserted once at the active insertion point; clipboard and focus behavior match the chosen product contract; denial/error has recovery | Not run |
| M08 | Recording/transcribing/success/error overlays on non-notch and notch display | Phase, audio level and failure action match runtime exactly; panels do not steal focus; no stale overlay remains; success behavior matches resolved FSM | Not run; FSM-01 |
| M09 | Two displays: start on each display, move active app between Spaces/full-screen, change resolution, unplug during recording | Overlay follows the documented target display, remains inside safe area, and repositions after topology/Space changes | Not run; DISPLAY-01 |
| M10 | Model lifecycle: empty catalog, download, progress, cancel, offline/error, retry, activate, warm, relaunch | Every state/action is visible and single-shot; progress is monotonic; cancellation/retry work; selected/active model survives relaunch | Not run |
| M11 | History: empty, add entries, expand, delete, clear/cancel/confirm, corrupt/unwritable store | Correct content/error states; destructive action is modal and focus-safe; retention is 50; audio/metadata deletion follows policy | Modal implementation/tests green; manual not run |
| M12 | Settings: microphone switch, sound, vocabulary debounce, duration, launch at login | Controls disable while pending; failures restore usable state; values persist after relaunch; vocabulary produces one final write; login item launches once | Not run |
| M13 | Updates: current, newer, offline/API error, malformed release, open download | Status and recovery are accurate; URL is HTTPS/expected host; no duplicate request; published artifact is notarized | Not run |
| M14 | Sleep/wake during idle, recording and model operation; lock/unlock; audio device change | No stuck hotkey/overlay; interrupted operation resolves deterministically; event tap/audio devices recover; no duplicate process or login item | Not run |
| M15 | Quit/relaunch/crash during recording/download/settings write | Resources shut down or recover; partial model files/history/config remain valid; no stale overlay; next launch has a truthful state | Not run |
| M16 | Upgrade from last shipped build with legacy preferences/history/models and existing TCC grants | Data migrates once without loss; bundle identity preserves or deliberately re-prompts TCC; onboarding is not repeated incorrectly | Not run |
| M17 | Keyboard-only all screens, clear-history dialog and error recovery | Logical tab order; every action works; focus visible/stable; modal trap/Escape/restoration correct; no keyboard trap | Interaction tests green; manual not run |
| M18 | VoiceOver + Accessibility Inspector across onboarding/settings/models/history/about and native panels | Every control has role/name/value/state/action; groups/headings and reading order are useful; progress/errors announced; modal semantics correct | **Signed AX smoke green; real VoiceOver/Inspector not run** |
| M19 | Light/Dark, Increase Contrast, Differentiate Without Color, Reduce Motion/Transparency | System changes apply live; contrast tests pass; state never depends on color only; motion/transparency preferences are honored | Not run; THEME-01/MOTION-01 |
| M20 | Resize every screen at minimum/default/wide sizes and 125/150/200% effective scale | No clipped/overlapping text, horizontal loss, hidden actions or unreachable controls; scroll position/focus remain stable | Adaptive implementation green; manual not run |
| M21 | Endurance: 60 s idle, 60 s recording, 20 transcriptions, max 50-entry history | Instruments shows no full-tree work per audio tick, no sustained idle churn, no UI stall and no monotonic memory/resource growth; measured baselines attached | 33 ms coalescing regression green; Instruments not run |
| M22 | Roll back to the previous signed release after upgrade/failure | Documented rollback restores a launchable app; data schema compatibility/loss is explicit; TCC/login item behavior is understood | Not run |

## `.8` acceptance checklist

### Release prerequisites

- [x] `wrenflow-duh.7` is closed and final Flutter/Rinf packaging removal is
  verified; only intentional one-time legacy data migration keys remain.
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

### Manual acceptance

- [ ] M01–M22 have named tester, date, machine/macOS/display matrix, artifact
  hash, evidence link and pass/fail; no “code inspected” substitution.
- [ ] Fresh-account microphone/accessibility denial and recovery pass through
  LaunchServices with the Developer ID identity used for release.
- [ ] VoiceOver and Accessibility Inspector pass all GPUI and native-panel
  states, including hidden-settings recording/transcribing/error flows.
- [ ] Keyboard-only use passes every screen and destructive/error path without
  lost focus, hidden focus, background modal activation or traps.
- [ ] Dark Mode, increased contrast, reduced motion/transparency and effective
  larger-text/display scaling pass live changes and relaunch.
- [ ] Multiple displays, Spaces, full-screen apps, notch/no-notch, hot-plug and
  resolution changes pass the documented overlay-target policy.
- [ ] Sleep/wake, lock/unlock, crash/relaunch, update, launch at login, legacy
  upgrade and rollback pass without duplicate processes, stuck state or data
  loss outside the documented policy.

### Exit criteria

- [ ] Every P1 is fixed or explicitly waived by the product owner with bounded
  impact and follow-up issue; no accessibility, trust or data-loss risk may be
  waived for release.
- [ ] P2/P3 follow-ups have owners and acceptance tests.
- [ ] The release candidate tested manually is byte-identical to the published
  artifact and its notarization evidence is retained.
- [x] The code-hardening scope may close only after every unchecked
  credential/human row is moved intact to a blocking P0 release-validation
  issue.
- [ ] The migration epic/release is not release-ready until that P0 issue passes
  against the byte-identical published candidate.

## Fix-slice disposition

1. **Completed — accessibility bridge:** stable semantic IDs/frames, AppKit
   `NSAccessibilityElement` proxies, actions/value changes/live announcements
   and a signed AX-tree smoke test; manual VoiceOver stays external.
2. **Completed — keyboard/focus hardening:** modal focus manager, Escape/default
   actions and restoration, stable control entities and an explicit cancelable
   hotkey capture state with reserved-key policy.
3. **Partly completed — contrast and system appearance:** contrast tokens/tests
   are executable and green; live system appearance/accessibility display
   settings remain in the external policy matrix.
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
8. **Open — overlay environment policy:** define/validate active display,
   Space/notch changes, Reduce Motion and persistent recovery on real hardware.
9. **Deferred P3 — hierarchy distillation:** replace repetitive card stacks
   only with product/design direction and narrow/text-scale evidence.

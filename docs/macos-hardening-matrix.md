# macOS hardening acceptance matrix

This matrix is executable where automation is safe and deliberately manual
where macOS requires a human decision, Apple credentials, VoiceOver, or a clean
account. Never report a row as passing without attaching the listed evidence.

Run repository commands through mise. `WRENFLOW_TEST_APP` may point to an exact
installed Developer ID bundle; otherwise the scripts use
`build/gpui/Wrenflow.app`.

## Automated and local smoke checks

| Gate | Command | Required evidence |
| --- | --- | --- |
| Locked Rust and Swift compile | `mise run check` | Both root and isolated app workspaces finish successfully. |
| App and bridge tests | `mise run test-app` | Rust semantic/action tests and the Swift schema validator pass. |
| Developer ID bundle | `mise run build && mise run hardening-bundle` | Bundle ID `me.gulya.wrenflow`, Team ID `T4LV8K9BGV`, hardened runtime, strict nested signature. |
| Native accessibility tree | `mise run build && mise run hardening-accessibility`, or `WRENFLOW_TEST_APP=/absolute/path/Wrenflow.app mise run hardening-accessibility` for the retained candidate | The exact Developer ID app publishes a non-empty, measured AppScreens tree through the Swift NSAccessibility bridge and exits cleanly. This is a bridge smoke, not human M18/VoiceOver acceptance. |
| LaunchServices lifecycle | `mise run hardening-lifecycle` | Exact bundle path/PID, visible settings window, one process after a second `open`, accessory policy after close. |
| Notarized artifact | `WRENFLOW_TEST_DMG=build/Wrenflow.dmg mise run hardening-notarized` | `notarytool` result is `Accepted`, ticket validates, Gatekeeper accepts the signed DMG, SHA-256 recorded. |

`scripts/notarize-release.sh` fails before contacting Apple when any of
`APPLE_ID`, `APPLE_TEAM_ID`, or `APPLE_APP_PASSWORD` is missing. The release
workflow additionally refuses to publish unless the Developer ID certificate,
certificate password, and temporary-keychain password are all present. Pull
requests are the only path allowed to use ad-hoc signing.

## Disposable-account TCC matrix

Use a disposable macOS account or clean VM with the production Developer ID
bundle installed at a stable path. Resetting TCC destroys existing consent, so
the helper requires an explicit guard:

```bash
WRENFLOW_TEST_APP=/Applications/Wrenflow.app \
WRENFLOW_CONFIRM_TCC_RESET=me.gulya.wrenflow \
  mise run hardening-reset-tcc
```

| Scenario | Procedure | Pass criteria and evidence |
| --- | --- | --- |
| Fresh microphone grant | Launch with `open /Applications/Wrenflow.app`, request microphone in onboarding, choose Allow. | Prompt names Wrenflow; settings changes to granted without terminal attribution; TCC log and screenshot recorded. |
| Microphone denial/recovery | Reset, choose Don't Allow, then use the in-app recovery button. | Denied state is actionable; the button opens Privacy & Security → Microphone; granting is observed without relaunch. |
| Fresh Accessibility grant | Request Accessibility, then enable Wrenflow in Privacy & Security → Accessibility. | Entry identifies the Developer ID app; permission observer changes to granted; global hotkey and paste work. |
| Accessibility denial/recovery | Keep the toggle disabled and use recovery actions. | App remains usable, explains the limitation, opens the correct pane, and observes a later grant. |
| Upgrade identity | Grant both permissions, replace the app with a newer build signed by the same Team ID at the same path, relaunch with `open`. | Existing grants remain associated with `me.gulya.wrenflow`; no terminal or ad-hoc identity appears. |
| Negative identity control | On a separate disposable account only, compare an ad-hoc build. | It must not be accepted as evidence for persistent TCC or release signing. |

Capture `/usr/bin/log stream --predicate 'subsystem == "com.apple.TCC"'` during
the tests. `mise run hardening-tcc-status` reads only the current user's TCC
database; Accessibility lives in the protected system database and must not be
queried or changed on a developer's normal account for acceptance.

## VoiceOver and NSAccessibility matrix

Run with VoiceOver enabled against the signed bundle. The GPUI 0.2.2 visual
tree is mirrored by the private AppKit bridge; every exported frame comes from
GPUI prepaint geometry in window-content, top-left coordinates. Nodes without
current geometry are omitted rather than assigned fabricated hit targets.

| Scenario | Pass criteria |
| --- | --- |
| Linear traversal | VO-Right/VO-Left follows the exported `order` through visible sidebar and screen controls without trapping or visiting hidden controls. |
| Roles and names | Buttons, switches, text fields, pop-up/list controls, progress, dialogs, navigation and status content announce the expected role and non-empty label. |
| State and value | Disabled, focused, switch value, selected model/text values and progress update after runtime snapshots. |
| Actions | VoiceOver Press, Focus, Increment, Decrement and Set Value round-trip through Swift → typed Rust event → `AppScreens`; disabled actions fail. |
| Focus | Accessibility focus and GPUI focus ring stay aligned; keyboard Tab/Shift-Tab and VoiceOver traversal reach the same visible interactive set. |
| Dynamic changes | Permission recovery, model download progress/completion, error notices and route changes post value/layout/focus notifications and one deduplicated announcement per serial. |
| Geometry | Accessibility Inspector highlight matches each rendered control after resizing and on Retina/non-Retina displays. |
| Dialog | Clear-history confirmation is exposed as the active dialog and hidden background actions are not traversed until dismissal. |

Record an Accessibility Inspector audit, a short VoiceOver screen recording,
the app version/signing output, display scaling, and macOS version. Automated
schema/action tests are necessary but do not replace this human VoiceOver gate.

## Release/notarization matrix

| Scenario | Expected result |
| --- | --- |
| Any signing secret missing | Workflow stops before release build/publication. |
| Any notary secret missing | Workflow stops before release build/publication. |
| Apple rejects submission | `notarize-release.sh` exits non-zero and prints the submission log; no upload step runs. |
| Apple accepts submission | DMG is stapled and validated, strict app/nested signatures pass, Gatekeeper accepts the DMG, and only then is it uploaded. |
| Clean-machine install | Download the published DMG on a clean non-developer account, verify Gatekeeper opens it without override, then execute the TCC and VoiceOver rows above. |

Actual Apple submission and clean-machine results require repository secrets and
a disposable machine. They must remain unchecked until those external runs are
performed; local Developer ID signing is not a substitute for notarization.

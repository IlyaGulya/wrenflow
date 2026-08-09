# Production GPUI macOS shell

Status: production shell. The GPUI bundle is the sole application target; the
former compatibility UI and transport were removed during the migration
cutover.

## Ownership boundary

| Owner | Responsibilities |
| --- | --- |
| GPUI/Rust | Settings content, navigation state, runtime commands and snapshots |
| Swift/AppKit | `NSStatusItem`, activation policy, TCC, launch at login, external URLs, window show/hide and native panels |
| Runtime | Transport-neutral product state, transcription lifecycle and cooperative shutdown |

`native/wrenflow-gpui/src/shell.rs` is the only Rust FFI surface. It converts
the C callback into typed `ShellEvent` values. `WrenflowShell.swift` is the
matching AppKit implementation. `WrenflowOverlayController.swift` preserves the
non-activating, screenSaver-level SwiftUI/AppKit recording, transcribing and
actionable error panels behind the typed FFI boundary.

The settings window is created once with `show: false`. The app starts as an
`LSUIElement` accessory, and the status item opens that same GPUI window after
switching to regular policy. Closing the red button hides the window and returns
to accessory policy; it does not tear down GPUI or the runtime. Tray Quit asks
the runtime to quit, GPUI's `on_app_quit` awaits `RuntimeInstance::shutdown`,
then the AppKit bridge is released.

Permissions are observed every second because macOS can change TCC state while
the app is open. Microphone and Accessibility requests/settings URLs are owned
by the signed AppKit process. Launch at login uses `SMAppService.mainApp` and
reports both state and errors to the runtime. External release/update URLs are
opened through `NSWorkspace`, not by GPUI.

## Cargo and platform constraints

The app is an intentionally isolated nested Cargo workspace because GPUI 0.2.2
pins `core-foundation` 0.10.0. Global push-to-talk input is implemented by the
Swift/AppKit shell and enters the same typed `AppAction` boundary as GPUI
controls.

The deployment target is macOS 14.0. This matches the bundled ONNX Runtime
dylib's load-command minimum. The Swift shell is compiled into
`libWrenflowShell.dylib` by `build.rs`, placed in `Contents/Frameworks`, and
loaded through `@executable_path/../Frameworks`. Runtime Metal shaders remain
enabled until an offline shader pack is owned by Wrenflow.

## Build and launch

Run all commands through mise:

```bash
mise run check
mise run build
mise run run
```

`build` creates the bundle, copies the ONNX Runtime dylib and icon, signs
nested dylibs first, signs the outer app with hardened runtime and the project
entitlements, then performs a strict deep verification. Override the default
Developer ID only for local experiments:

```bash
WRENFLOW_GPUI_SIGN_IDENTITY=- mise run build
```

Launch with `open`, never by running the Mach-O directly, so LaunchServices and
TCC attribute permissions to `me.gulya.wrenflow`:

```bash
open build/gpui/Wrenflow.app
open build/gpui/Wrenflow.app --args --shell-self-test
```

The self-test argument opens the normally hidden settings window and shows the
initializing native overlay. It is a reproducible smoke test for window policy,
the Swift dylib boundary and panel construction; it does not mutate TCC.

### Verified acceptance evidence

On 2026-08-09 the production path passed the following checks:

- `mise run check` compiled the isolated app, Swift shell, runtime and UI
  foundation with the locked dependency graph.
- `mise run build` produced a strict-valid nested bundle signed by
  `Developer ID Application: Ilya Gulya (T4LV8K9BGV)` with hardened runtime.
- The main Mach-O resolves `@rpath/libWrenflowShell.dylib` through
  `@executable_path/../Frameworks`.
- `mise run run -- --shell-self-test` launched the settings window and
  LaunchServices reported `ApplicationType=Foreground`.
- A normal `open` launch stayed alive and LaunchServices reported
  `ApplicationType=UIElement`, proving the menu-bar startup policy.
- Re-opening that running bundle kept exactly one process and changed
  LaunchServices to `ApplicationType=Foreground`, proving the reopen callback
  restores the existing GPUI settings window.
- A targeted Apple-event Quit shut down the production runtime and shell
  cleanly.

## Manual TCC verification

A clean first-grant test is intentionally manual because resetting TCC deletes
the developer's existing consent and is outside a normal build. On a disposable
macOS account or CI host, launch the signed bundle through `open`, request each
permission from the diagnostics settings surface, and verify System Settings
shows bundle identifier `me.gulya.wrenflow`. Re-signing with ad-hoc identity is
not equivalent to the Developer ID acceptance path.

# Production GPUI macOS shell

Status: production shell. The GPUI bundle is the sole application target; no
compatibility UI or transport is shipped.

## Ownership boundary

| Owner | Responsibilities |
| --- | --- |
| GPUI/Rust | Settings content, navigation state, runtime commands and snapshots |
| Swift/AppKit | `NSStatusItem`, activation policy, TCC, launch at login, fixed permission-settings deep links, window show/hide and native panels |
| Runtime | Transport-neutral product state, transcription lifecycle and cooperative shutdown |

`native/wrenflow-gpui/src/shell.rs` is the only Rust FFI surface. It converts
the C callback into typed `ShellEvent` values. `WrenflowShell.swift` is the
matching AppKit implementation. `WrenflowOverlayController.swift` preserves the
non-activating, screenSaver-level SwiftUI/AppKit recording, transcribing and
actionable error panels behind the typed FFI boundary.

The bundle is a Dock-free `LSUIElement` application. Onboarding or permission
recovery creates a compact GPUI window automatically. Closing the red button
removes that window from GPUI's registry and returns to accessory policy while
preserving `AppModel` and the runtime. The status item, a forced current-line
duplicate, or `mise run run` enters the typed OpenSettings boundary and creates
a new route-sized GPUI window; plain Finder reopen is not a windowless-show
contract. Tray Quit asks the runtime to quit, GPUI's
`on_app_quit` awaits `RuntimeInstance::shutdown`, then the AppKit bridge is
released.

Permissions are observed every second because macOS can change TCC state while
the app is open. Microphone and Accessibility requests plus the two fixed
System Settings pane links are owned by the signed AppKit process. Launch at
login uses `SMAppService.mainApp` and reports both state and errors to the
runtime. The authenticated updater never passes a response, release or download
URL to AppKit; selection, download and installation remain typed Rust runtime
operations.

Single-instance redirect, sleep/wake recovery, atomic installed-bundle
replacement, clean-break data retention and login-item-safe uninstall are
specified in [gpui-production-lifecycle.md](gpui-production-lifecycle.md).

## Cargo and platform constraints

The app is an intentionally isolated nested Cargo workspace because GPUI 0.2.2
pins `core-foundation` 0.10.0. Global push-to-talk input is implemented by the
Swift/AppKit shell and enters the same typed `AppAction` boundary as GPUI
controls.

The deployment target is macOS 14.0. This matches the bundled ONNX Runtime
dylib's load-command minimum. The Swift shell is compiled into
`libWrenflowShell.dylib` by `build.rs`, placed in `Contents/Frameworks`, and
loaded through `@executable_path/../Frameworks`. GPUI's Metal shaders are
compiled into an embedded metallib at build time after a fail-closed selected-
Xcode compiler/linker probe; the signed app never compiles Metal source during
its first window creation.

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

Launch with the mise task, never by running the Mach-O directly, so
LaunchServices and TCC attribute permissions to `me.gulya.wrenflow`. The task
also sends the exact verified current-line PID the typed show-settings signal:

```bash
mise run run
mise run run -- --shell-self-test
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
- Twenty normal cold launches reported only `ApplicationType=UIElement`, proving
  a Dock-free menu-bar startup policy.
- `mise run run` retained exactly one verified PID and the typed SIGUSR2 request
  recreated a 720×520 settings window over the preserved model/runtime.
- The bounded exact-bundle quit produced a fresh PID on relaunch.

## Manual TCC verification

A clean first-grant test is intentionally manual because resetting TCC deletes
the developer's existing consent and is outside a normal build. On a disposable
macOS account or CI host, launch the signed bundle through `open`, request each
permission from the diagnostics settings surface, and verify System Settings
shows bundle identifier `me.gulya.wrenflow`. Re-signing with ad-hoc identity is
not equivalent to the Developer ID acceptance path.

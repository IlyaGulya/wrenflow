# GPUI macOS shell spike

Issue: `wrenflow-duh.1`

Verified on 2026-08-09 with Rust 1.94.1, GPUI 0.2.2 and Xcode 26.4.

## Decision

**Conditional go.** GPUI can own Wrenflow's settings/onboarding/history window while
AppKit continues to own the menu-bar lifecycle and native overlays. Do not attempt
to replace those AppKit boundaries with GPUI abstractions during the first migration.

The spike is deliberately outside the production Cargo workspace at
`spikes/gpui-macos`. It does not link `wrenflow-core` yet and cannot affect the
shipping Flutter target.

## Reproduce

All entry points go through `mise`:

```sh
mise run gpui-spike-check
mise run gpui-spike-build
mise run gpui-spike-run
```

`gpui-spike-build` produces:

```text
build/gpui-spike/Wrenflow GPUI Spike.app
```

The default signature is ad hoc so every developer can reproduce the bundle. To
exercise the exact hardened-runtime signing path with the installed Wrenflow
Developer ID identity:

```sh
WRENFLOW_SPIKE_SIGN_IDENTITY='Developer ID Application: Ilya Gulya (T4LV8K9BGV)' \
  mise run gpui-spike-build
```

The script signs the bundled ONNX Runtime dylib first, then the app, and runs
`codesign --verify --deep --strict`. It copies ONNX Runtime beside the executable,
matching `native/hub/src/platform/runtime_probe.rs`.

Launch only via `open`, just like production. Starting the executable directly from
a terminal attributes TCC checks to the wrong responsible process.

## What is proven

| Boundary | Evidence | Result |
| --- | --- | --- |
| GPUI settings window | `src/main.rs` opens a titled Metal-backed GPUI window | Go |
| Menu-bar app | `Info.plist` has `LSUIElement=true`; Swift creates and retains `NSStatusItem` | Go |
| Dock lifecycle | bridge resets `.accessory` after GPUI startup, tray changes to `.regular`, hide returns to `.accessory` | Go with AppKit bridge |
| Last window hidden | the `NSStatusItem` is retained independently and reopens the existing GPUI `NSWindow` | Go; keep a single long-lived settings window |
| Native overlay | Rust calls a Swift C ABI; Swift creates a non-activating `NSPanel` at `screenSaver` level on all Spaces | Go with AppKit bridge |
| Permissions | tray actions call microphone and Accessibility trust prompts from the `.app` process | Mechanism proven; clean-machine user grant still manual |
| ONNX Runtime | bundle script copies and signs `libonnxruntime.dylib` beside the executable | Go |
| Signing | configurable Developer ID, hardened runtime, entitlements, nested dylib-first signing, strict verification | Go; notarization is release-pipeline work |
| LaunchServices | `gpui-spike-run` uses `open` on the signed bundle | Go |
| Input/select/switch | companion `spikes/gpui-controls` target pins GPUI 0.2.2 + gpui-component 0.5.1 | Conditional go; see accessibility gap below |

The concrete verification produced a hardened-runtime arm64 bundle signed by
`Developer ID Application: Ilya Gulya (T4LV8K9BGV)`. Both the app and ONNX dylib
passed strict verification. After `gpui-spike-run`, LaunchServices reported bundle
`me.gulya.wrenflow.gpui-spike` as `ApplicationType=UIElement`, and the process stayed
alive with its settings window hidden until it received the normal Quit Apple event.

## Important implementation findings

### GPUI does not replace the AppKit shell

GPUI initializes the macOS application and owns its event loop/window rendering.
Wrenflow still needs a small main-thread AppKit controller for:

- `NSStatusItem` and its menu;
- `.accessory`/`.regular` activation-policy transitions;
- showing and hiding the settings window without terminating the process;
- microphone and Accessibility permission prompts;
- the screen-saver-level, all-Spaces, non-activating recording overlay.

The proof uses a Swift object compiled by `build.rs` and four stable C ABI entry
points. Production should use the same direction of dependency: Rust/GPUI calls a
small platform interface, while Swift owns AppKit objects on the main thread.

### Reusing the current overlay requires one extraction

`macos/Runner/OverlayHandler.swift` combines two concerns in one type:

1. reusable `NSPanel`/SwiftUI overlay implementation;
2. Flutter `FlutterMethodChannel` transport.

The spike reproduces the same panel invariants through the C ABI. Production
migration should extract the views and panel controller into a Flutter-free Swift
file, then keep two thin adapters during the transition: the existing method-channel
adapter and the new Rust C ABI adapter. No overlay rewrite is required.

### Controls are usable, not accessibility-complete

The companion `spikes/gpui-controls` proof covers real controlled text input,
select, switches, sidebar, and a virtualized list without Zed's GPL UI crate.
However, gpui-component 0.5.1's switch is mouse-driven and lacks a focus handle,
keyboard activation, and an explicit accessibility role/value. The migration must
wrap or replace it before feature parity. Dropdown buttons and custom rows need the
same audit.

## TCC and signing limits of this spike

TCC consent is keyed to code identity and user state. An automated development run
cannot prove the first-run consent UX on a clean user's machine without resetting
that user's privacy database, which this spike intentionally does not do. The app
contains the production-equivalent usage string and permission calls and can be
Developer-ID signed. Release hardening still needs a clean macOS account/VM test for:

- first microphone prompt and subsequent granted/denied states;
- first Accessibility prompt and System Settings deep link;
- upgrade preserving grants under the final production bundle identifier;
- notarized distribution and Gatekeeper launch.

The spike uses a distinct bundle identifier (`me.gulya.wrenflow.gpui-spike`) so it
cannot disturb the production app's existing grants.

## Production shape

Keep the boundary intentionally small:

```text
Rust runtime + AppModel
          |
          v
     GPUI views
          |
   platform commands
          v
Swift/AppKit shell (tray, activation policy, permissions, overlay)
```

Pin GPUI and gpui-component to exact versions. Upgrade them only in dedicated PRs
with the settings interaction/accessibility harness running.

The spike enables GPUI's `runtime_shaders` feature. Xcode 26 no longer ships the
command-line Metal compiler by default, and a normal GPUI build otherwise fails
with `xcodebuild -downloadComponent MetalToolchain`. Runtime compilation makes the
developer spike reproducible without mutating the host Xcode installation. Release
CI should install that component and use GPUI's precompiled metallib path to avoid
the small first-window shader compilation cost.

### Current ONNX Runtime raises the real deployment floor

The current arm64 `vendor/onnxruntime/lib/libonnxruntime.dylib` has
`LC_BUILD_VERSION minos 14.0`, although the Flutter Xcode project currently declares
macOS 10.15. The GPUI spike therefore declares 14.0 rather than publishing a bundle
that launches on an OS where local inference cannot load. Before migration ships,
either make macOS 14 the supported floor or source/build an ORT dylib with the chosen
older deployment target. This mismatch exists independently of GPUI.

## Remaining risks / follow-up

- Extract the Flutter-free overlay controller and define the final Rust/Swift ABI.
- Decide whether the production bridge stays Swift or moves to `objc2`; Swift is the
  lower-risk choice because the existing overlays and permission code are Swift.
- Add lifecycle tests for close/reopen, multiple screens, Spaces, full-screen apps,
  sleep/wake, and display reconfiguration.
- Add keyboard and AccessKit acceptance tests for every settings control.
- Validate Developer ID + notarization + TCC in a clean account or VM.
- Resolve the declared macOS 10.15 versus ONNX Runtime 14.0 deployment mismatch.
- Run the production runtime in the GPUI process and verify ORT loading by the bundled
  executable path; this spike verifies packaging, not inference.

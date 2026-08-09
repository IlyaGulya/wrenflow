# Wrenflow GPUI design system

This module is the compatibility boundary around GPUI 0.2.2 and
gpui-component 0.5.1. Screens should use these Wrenflow-owned primitives rather
than depend directly on upstream controls where an equivalent exists.

## Included foundation

- light/dark color, spacing, typography, sizing and focus tokens;
- keyboard-operable buttons and switches with change/press events;
- cards, text-input/select/progress presets, dialogs and status states;
- settings rows, sections, navigation and scrolling layout;
- settings-schema validation for stable IDs and select values;
- composite Wrenflow branding and component icon assets;
- semantic snapshots with real GPUI layout geometry and interaction-test helpers.

## VoiceOver boundary

GPUI 0.2.2 does not expose a native macOS accessibility tree. Wrenflow therefore
owns a narrow compatibility bridge instead of assuming that visual GPUI
elements are visible to VoiceOver. The upstream `Switch` is also pointer-only;
its implementation has no focus handle or keyboard activation.

`AccessibleButton` and `AccessibleSwitch` close the keyboard/focus gaps with
real tab stops, Space/Enter actions and two-tone visible focus rings. Stable
control entities preserve focus across label/value changes.

`AppScreens` now publishes a stable `AccessibilitySnapshot` containing visible
nodes in traversal order, roles, labels, values, enabled/focused state,
supported actions, announcements and exact window-content frames. Frames come
from a layout-transparent GPUI element during prepaint; incomplete or stale
geometry is never published. The AppKit shell maps that snapshot to real
`NSAccessibilityElement` proxies and sends native press/focus/value actions
back through `AppScreens::perform_accessibility_action`, which dispatches only
typed `AppAction`s.

The schema and Swift decoder/action round-trip are automated, including
rejection of zero-sized geometry. Release acceptance still requires the signed
app's `mise run hardening-accessibility` check plus manual Accessibility
Inspector and VoiceOver traversal on the clean-account matrix; Rust semantic
tests alone are not sufficient evidence.

## Test expectations

Run the isolated production app checks through mise:

```sh
mise run check-app
mise run test-app
mise run lint-app
mise run hardening-accessibility
```

On Xcode 26, GPUI shader compilation requires the optional Metal Toolchain:

```sh
mise exec -- xcodebuild -downloadComponent MetalToolchain
mise exec -- xcodebuild -runFirstLaunch -checkForNewerComponents
```

# GPUI controls spike

This standalone crate answers one narrow question: can the current GPUI ecosystem
cover Wrenflow's settings-style desktop UI without importing Zed's GPL `ui` crate?

## Dependency decision

- `gpui = =0.2.2`
- `gpui-component = =0.5.1`
- `gpui-component-assets = =0.5.1`

`gpui-component` 0.5.1 declares GPUI 0.2.2 in its own workspace. Exact versions
are intentional: GPUI is pre-1.0 and its own README warns that breaking changes
are frequent. The component library and GPUI core are Apache-2.0.

## What the executable proves

- a controlled text input backed by Rust state;
- a dropdown with typed values;
- switches;
- a settings sidebar and a virtualized, scrollable list;
- programmatic keyboard focus and a tab-stop input;
- a complete native GPUI window rooted in `gpui_component::Root`.

Build without joining the production workspace:

```sh
mise exec rust@1.94.1 -- cargo check \
  --manifest-path spikes/gpui-controls/Cargo.toml --locked \
  --config 'source.crates-io.registry="sparse+https://index.crates.io/"'
```

Run the spike directly only for local visual inspection. Production Wrenflow must
still be launched as a signed `.app` through `open` so microphone and accessibility
permissions are attributed correctly.

## Accessibility and testing finding

The result is a **conditional go**, not complete parity:

- `InputState` and `SelectState` expose `FocusHandle`s and install tab stops;
- GPUI has a `test-support` feature and `TestAppContext`, but gpui-component 0.5.1
  has almost no component-level test coverage (the tree component is the sole use
  in this release), so Wrenflow needs its own interaction harness;
- `Switch` 0.5.1 is mouse-driven: its implementation has no `FocusHandle`, tab stop,
  keyboard action, or accessibility role/value. Do not ship it unchanged. Wrap or
  replace it with a Wrenflow control that supports Space/Enter, focus indication,
  and an explicit switch/checkbox accessibility node;
- the same accessibility audit must be applied to dropdown buttons and custom rows.

This gap belongs in the design-system foundation task, before screen migration.

## Verification on this machine

Cargo successfully resolved the exact pins into the spike-local `Cargo.lock` (761
packages). Xcode's optional Metal Toolchain was installed non-interactively with:

```sh
mise exec rust@1.94.1 -- xcodebuild -downloadComponent MetalToolchain
mise exec rust@1.94.1 -- xcodebuild -runFirstLaunch -checkForNewerComponents
```

The SDK-scoped probe `mise exec rust@1.94.1 -- xcrun --sdk macosx metal -v`
reports Apple metal version 32023.883. The locked `cargo check` command above then
compiled GPUI, gpui-component and this application crate successfully, proving the
exact dependency set and controls API are compatible on this host.

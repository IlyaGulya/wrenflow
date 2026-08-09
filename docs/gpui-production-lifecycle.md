# GPUI production lifecycle

This is the supported install, replacement, reset and uninstall contract for
the production GPUI application. Wrenflow keeps bundle identifier
`me.gulya.wrenflow` and Developer ID Team `T4LV8K9BGV` at every supported
installed path so LaunchServices, TCC and `SMAppService` see one responsible
application identity.

## Clean-break data policy

The first GPUI release is a clean break. It does not migrate or silently import
Flutter settings, history, recordings or model state. There is no downgrade or
rollback contract to a Flutter release. Old data may remain on disk, but it is
ignored unless the user explicitly removes it.

Current GPUI state is rooted below a versioned namespace:

```text
~/Library/Application Support/me.gulya.wrenflow/gpui-v1/
  config.json
  history.sqlite
  models/
  recordings/
~/Library/Caches/me.gulya.wrenflow/gpui-v1/
~/Library/Logs/me.gulya.wrenflow/gpui-v1/
```

The current-format integrity contract proves those paths are used and a
populated legacy plist/data root is ignored. The pre-GPUI locations are:

```text
~/Library/Application Support/Wrenflow/
~/Library/Application Support/wrenflow/
~/Library/Preferences/me.gulya.wrenflow.plist
~/Library/Saved Application State/me.gulya.wrenflow.savedState/
~/Library/Caches/me.gulya.wrenflow/
```

The shared bundle identifier deliberately preserves the app's TCC identity;
it is not evidence of data-format compatibility.

## Installation and GPUI-line replacement

The user contract is a notarized DMG: open it, drag `Wrenflow.app` to
Applications, eject it, and launch Wrenflow from Applications. The user must not
run a Mach-O or terminal installer. The clean-machine DMG/Gatekeeper proof is
owned by `.9.8` and `.9.9`.

For a local Developer ID candidate, the executable validation path is:

```bash
mise run release-install
```

The installer accepts only `/Applications/Wrenflow.app` and
`$HOME/Applications/Wrenflow.app`. It verifies bundle ID, Team ID and the deep
signature before publishing. Shared process lookup also requires the running
LaunchServices bundle path to equal that exact target before it may signal a
PID; a same-ID process from another copy is rejected without signalling. An
existing GPUI-line bundle is stopped, a fully
verified candidate is copied to a staging directory on the destination volume,
and `renameatx_np(RENAME_SWAP)` exchanges both bundles atomically. The old
bundle is unregistered from LaunchServices and then moved to Trash; the new
bundle is explicitly registered. Only exact production-bundle PIDs receive the
current-line `SIGUSR1` quit request; the running app finishes typed runtime
shutdown and writes its clean recovery marker before terminating. It is a
release validation tool, not the end-user DMG contract.

Replacement preserves the versioned current-format data root and existing TCC
identity. It never examines a Flutter data root. Failed verification leaves the
installed app untouched; interrupted staging leaves a hidden staging directory
that contains no user data and can be removed safely.

## Login item and application lifecycle

Launch at Login uses `SMAppService.mainApp`. The status is read from macOS on
every launch and after wake; it is not inferred from a preference. Registration
and unregistration are synchronously verified and `.requiresApproval` is
reported as not yet enabled.

The AppKit shell enforces one process before runtime IO even when `open -n`
attempts to force a duplicate. It redirects only when the existing process has
the same resolved bundle and executable URL as the launching copy; a same-ID
process from another path is untrusted and receives no signal. `LSUIElement=true` keeps every ready cold launch
Dock-free. The shell installs a `SIGUSR2` DispatchSource during process preflight;
a duplicate and `mise run run` send that signal only to an exact verified
current-line PID. The signal becomes the typed OpenSettings action, and a request
arriving before AppModel is ready is retained until shell installation. Plain
Finder/LaunchServices reopen of an already-running windowless UIElement app is
not a supported show-window contract; the menu-bar tray is the canonical user
entry point. Closing removes the GPUI window from GPUI's registry but keeps
`AppModel` and the runtime alive; a tray/tooling request creates a fresh
route-sized window and switches to regular policy. Tray Quit enters typed runtime shutdown;
the bounded replacement/test path sends the same typed `SIGUSR1` request only
to an exact verified current-line production PID. Neither path unregisters
Launch at Login.

Onboarding and permission recovery open automatically at the Flutter-parity
compact frame of 340×380 points with a 300×340 minimum. Settings, Models,
History and About use 720×520. Completing a startup-only surface hides the
window and returns the ready app to accessory mode; screen code never calls
AppKit directly.

Before sleep, the shell destroys the event tap and hides transient overlays.
After wake it creates a fresh event tap and republishes permission and login
item state. TCC remains macOS-owned and is never reset as part of an update,
uninstall or data reset.

Automated local evidence:

```bash
mise run test-lifecycle-contract
mise run hardening-lifecycle
```

The signed lifecycle test records the exact bundle, PID, signing identity,
LaunchServices application type and visible frame. It proves Dock-free accessory
ready-state startup, typed same-PID show/recreation, forced duplicate suppression,
exact route geometry, bounded quit/fresh relaunch, and 20 cold starts with zero
Foreground/Dock samples.

Before a production candidate, manually record these macOS-owned transitions:

1. From the tray, enable Launch at Login. If System Settings requires approval,
   approve Wrenflow and confirm the UI observes `.enabled`.
2. Quit and relaunch twice; the toggle remains enabled and only one process
   exists.
3. Log out and in. Wrenflow starts once as a menu-bar accessory. Reopen Settings,
   close it, and confirm the Dock icon disappears while the tray remains.
4. Sleep and wake while idle and while the settings window is visible. The
   global hotkey recovers, stale overlays are absent, permission state is
   correct, and only one process exists.
5. Disable Launch at Login, quit and relaunch, then log out/in once more. No
   Wrenflow process starts.

Attach `ps`, `lsappinfo`, signing identity, macOS version and System Settings
screenshots to `.9.9`; do not claim a clean-machine result from a developer host.

## Uninstall and reset

Default uninstall retains all application data and TCC decisions:

```bash
mise run release-uninstall
```

The script first launches the exact signed app through LaunchServices in a
restricted preparation mode. The app calls `SMAppService.mainApp.unregister()`,
verifies the result is neither `.enabled` nor `.requiresApproval`, writes
bundle-path/PID/status evidence into a private temporary directory, and exits.
Only after validating that evidence does the script move the bundle to Trash.
That ordering prevents an orphan login item.

Remove current GPUI config, history, models and recordings as well:

```bash
mise run release-uninstall -- --purge-current-data
```

Remove old Flutter-era data only when the user explicitly requests it:

```bash
mise run release-uninstall -- --remove-legacy-data
```

Both scopes can be selected together. All removals use fixed allowlisted paths
and move data to Trash. Uninstall and reset never alter TCC consent.

Reset without removing the installed application also requires an explicit
scope:

```bash
mise run reset-app-data -- --current-data --relaunch
mise run reset-app-data -- --legacy-data
mise run reset-app-data -- --all --relaunch
```

`--current-data` resets only the versioned GPUI namespace. `--legacy-data`
removes only pre-GPUI paths. `--all` combines them. A reset without one of these
flags is rejected. When both supported install locations exist, `--target` is
required; the exact path/Team/bundle identity receives typed `SIGUSR1`, and a
bounded failure to write the clean marker and quit aborts the reset.

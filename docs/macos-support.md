# macOS support contract

Status: production GPUI line. Last reviewed 2026-08-09.

`support/macos.env` is the machine-readable source of truth. The release build,
CI jobs and `scripts/verify-macos-support.sh` fail closed when any declared
value drifts.

## Supported systems

| Dimension | Production contract |
| --- | --- |
| macOS | macOS 14 Sonoma through macOS 26 Tahoe, including current security and point updates |
| CPU | Apple Silicon, Apple M1 or newer; the shipped artifact is arm64-only |
| Memory | 8 GiB minimum; model downloads need at least 2 GiB of free storage in addition to application data |
| Install location | `/Applications/Wrenflow.app` or `$HOME/Applications/Wrenflow.app` |
| Displays | One or two displays; built-in Retina and external 1×/2× backing scales, including scaled desktop modes |
| Audio input | Built-in microphone or a directly connected CoreAudio USB input that exposes a default input configuration |
| Application state | Clean first installation of the public GPUI release |

Intel Macs are not supported. The app is not a Universal binary, Rosetta does
not make an arm64 application runnable on Intel, and the pinned ONNX Runtime
archive is arm64-only. macOS 13 and older are also unsupported. Finder or
LaunchServices may present the standard incompatible-application UI; release
verification rejects an Intel or Universal Mach-O before publication.

Pre-GPUI releases and their data are outside the support contract. There is no
Flutter-state import, schema migration, downgrade, rollback, or update-from-beta
promise. This first public release starts clean; later update compatibility is
not claimed by this release contract.

## Display and input boundaries

The settings window must remain usable at its compact and default sizes on a
built-in Retina panel and an external display, including a two-display layout
where the active display changes. The product matrix exercises 125%, 150% and
200% effective content scaling. Display hot-plug, Spaces/full-screen placement
and overlay safe-area behavior are real-hardware release gates in
`docs/macos-hardening-matrix.md`; a compile-only CI runner cannot certify them.

The audio contract follows CoreAudio through `cpal`: Wrenflow selects either
the configured device name or the system default, accepts its default sample
rate and channel count, mixes multichannel input to mono and resamples to 16
kHz. Built-in microphones and ordinary directly connected USB interfaces are
supported. Bluetooth headsets, aggregate/multi-output devices, virtual audio
drivers, network audio and device removal during recording are best effort
until they receive explicit real-hardware evidence. No-input and permission
denial must produce a recoverable product error rather than a crash.

## Automated matrix

| Tier | GitHub runner | Xcode | What it proves |
| --- | --- | --- | --- |
| Minimum | `macos-14` arm64 / M1 | 16.2 | The complete ad-hoc bundle builds on the oldest supported OS and hardware class; all nested Mach-O files stay arm64 with `minos <= 14.0` |
| Current | `macos-26` arm64 | 26.3 | Tests, lint, signed release build and the same artifact contract on the current supported major/toolchain |

The runner and Xcode labels are intentionally pinned; `macos-latest` is
forbidden. GitHub currently documents `macos-14`, `macos-15` and `macos-26` as
arm64 labels in the
[runner-images catalog](https://github.com/actions/runner-images#available-images),
and lists Xcode 26.3 on the
[macOS 26 arm64 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
The macOS 14 hosted image is scheduled for removal on 2026-11-02. Before that
date the minimum tier must move to a self-hosted M1 runner kept on the latest
macOS 14 security update, or the product floor must be raised in one reviewed
change to the contract, plist, CI and documentation.

Run the same gates locally with:

```bash
mise exec -- scripts/verify-macos-support.sh source
mise exec -- scripts/verify-macos-support.sh host
mise exec -- scripts/test-macos-support.sh
mise exec -- scripts/verify-macos-support.sh bundle build/gpui/Wrenflow.app
```

The source check reconciles `Info.plist`, Rust and Swift target selection, ORT,
Rust, CI runners/Xcode and user-facing requirements. The bundle check reads
every shipped Mach-O rather than trusting build settings.

## Real-hardware release evidence

CI is sufficient for architecture, deployment floor and clean bundle assembly.
Each production candidate still needs S01/S02 owner smoke on the available
physical Apple-Silicon host. Record the artifact SHA-256, exact macOS version,
Mac model/chip, memory, display topology/scale and the actually used input
device. This is a clean-install/core-workflow and accessibility/appearance/
display spot check, not an invented base-M1 physical cohort. The automated
`macos-14` runner remains the fail-closed minimum-machine build and performance
gate. Do not substitute a terminal-launched Mach-O for the owner LaunchServices
observation.

<table align="center"><tr><td>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="Resources/logo-light.svg">
    <img src="Resources/logo-light.svg" width="96" height="96" alt="Wrenflow icon">
  </picture>
</td><td>
  <h1>Wrenflow</h1>
  <p>Local-first speech-to-text.<br>Hold a key, speak, release — text appears at your cursor.</p>
</td></tr></table>

<p align="center">
  <a href="https://github.com/IlyaGulya/wrenflow/releases/latest/download/Wrenflow.dmg"><b>Download for macOS</b></a><br>
  <sub>macOS 14+ · Apple Silicon · Windows and Linux planned</sub>
</p>

---

Wrenflow is a free, open-source dictation app. A lightweight alternative to [Wispr Flow](https://wisprflow.ai/), [Superwhisper](https://superwhisper.com/), and [Monologue](https://www.monologue.to/).

> **Note:** Currently tested on macOS only. The core is written in Rust for cross-platform support — Windows and Linux builds are in progress.

All transcription runs on-device using [Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2). No cloud, no API key, nothing leaves your Mac.

## How it works

1. Hold **Fn** (or your configured hotkey) to record
2. Release to transcribe
3. Text is pasted at your cursor

Transcription typically completes in under a second. The model downloads automatically on first launch (~600 MB).

## Features

- **On-device transcription** — Parakeet TDT 0.6B via ONNX Runtime, no internet required
- **AI cleanup** (optional) — LLM post-processing that reads screen context, fixes grammar, and respects custom vocabulary. Uses [Groq](https://groq.com/) API (free tier available). Off by default.
- **Configurable hotkey** — Fn, Right Option, or F5
- **Run log** — history of all transcriptions with pipeline metrics
- **CLI tool** — `wrenflow start | stop | toggle | status` for scripting

## Architecture

Wrenflow's core logic lives in Rust for cross-platform portability. The macOS frontend is native SwiftUI.

```
core/
  wrenflow-domain/    Pure types and business logic (no IO)
  wrenflow-core/      Infrastructure: audio capture (cpal), transcription,
                      HTTP clients, SQLite history store
  wrenflow-ffi/       UniFFI bridge to Swift

Sources/              macOS SwiftUI app
```

**Audio capture** uses [cpal](https://github.com/RustAudio/cpal) (CoreAudio on macOS, WASAPI on Windows, ALSA on Linux).
**Transcription** uses [parakeet-rs](https://github.com/istupakov/parakeet-rs) with ONNX Runtime.
**History** is stored in SQLite via [rusqlite](https://github.com/rusqlite/rusqlite), persisted by the Rust layer directly.
**Post-processing, model fetching, and all HTTP** go through Rust — no Swift networking code.

## Build from source

Requires: Xcode 16+, Rust stable, [just](https://github.com/casey/just).

```bash
just build    # Debug .app bundle
just run      # Build, kill running instance, launch
just release  # Release build (arm64, signed)
just dmg      # Release + DMG installer
```

Other useful commands:

```bash
just icon         # Regenerate app icon from Resources/logo.svg
just setup-hooks  # Install conventional commit git hook
just logs         # Stream app logs
just crashes      # Show recent crash reports
just clean        # Remove build artifacts
```

## Contributing

Commits follow [Conventional Commits](https://www.conventionalcommits.org/). Run `just setup-hooks` to enable the validation hook.

Releases are managed by [release-please](https://github.com/googleapis/release-please) — push `feat:` or `fix:` commits to `main` and a release PR will be created automatically.

## Acknowledgments

Thanks to [Zach Latta](https://github.com/zachlatta) and [FreeFlow](https://github.com/zachlatta/freeflow) — the project that started it all.

## License

MIT

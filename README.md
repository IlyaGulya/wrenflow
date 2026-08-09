<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/readme-header-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="Resources/readme-header-light.svg">
    <img src="Resources/readme-header-light.svg" width="600" alt="Wrenflow — Local-first speech-to-text">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/IlyaGulya/wrenflow/releases/latest/download/Wrenflow.dmg"><b>Download for macOS</b></a><br>
  <sub>macOS 14+ · Apple Silicon</sub>
</p>

---

Wrenflow is a free, open-source dictation app. Hold a key, speak, release — text appears at your cursor. All transcription runs locally on your Mac.

> **Platform support:** macOS only for now. The core is written in Rust — other platforms are planned.
> The production build requires macOS 14 or later on Apple Silicon (M1 or
> newer); see the [complete support contract](docs/macos-support.md).

## How it works

1. Hold **Fn** (or your configured hotkey) to record
2. Release to transcribe
3. Text is pasted at your cursor

Transcription typically completes in under a second. The model downloads automatically on first launch (~600 MB).

## Features

- **On-device transcription** — [Parakeet TDT 0.6B V3 ONNX, exact pinned revision](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/tree/8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce) via ONNX Runtime, no internet required after model installation
- **Model prewarm** — first transcription is as fast as subsequent ones
- **Configurable hotkey** — Fn, Right Option, or F5
- **Transcription history** — searchable log with audio recordings saved as OGG/Opus
- **Menu bar app** — lives in the menu bar, no dock icon

## Architecture

GPUI renders the product window, Rust owns application/runtime state, and a
small Swift/AppKit shell owns the menu bar, macOS permissions and native
overlays. The UI sends typed actions into `AppModel`; it never calls the audio,
model or history services directly.

```
core/
  wrenflow-domain/    Pure types and business logic (no IO)
  wrenflow-core/      Infrastructure: audio capture, transcription,
                      HTTP clients, SQLite history store
  wrenflow-runtime/   Transport-neutral runtime commands, snapshots and events
native/wrenflow-gpui/ GPUI screens plus the Swift/AppKit macOS shell
```

**Audio capture** uses [cpal](https://github.com/RustAudio/cpal) with CoreAudio.
**Transcription** uses [parakeet-rs](https://github.com/istupakov/parakeet-rs) with ONNX Runtime.
**History** is stored in SQLite via [rusqlite](https://github.com/rusqlite/rusqlite).
**Recordings** saved as OGG/Opus (~15 KB per recording).

## Build from source

Requires: [mise](https://mise.jdx.dev/) (manages all other tools automatically).

```bash
mise run setup     # Install Rust tooling and fetch locked dependencies
mise run check     # Check the core/runtime workspace and desktop app
mise run build     # Build the signed, hardened .app bundle
mise run run       # Build + launch through LaunchServices for TCC
mise run release   # Rebuild and strictly verify the release bundle
```

Local machines without the Developer ID certificate can build an ad-hoc signed
bundle with `WRENFLOW_GPUI_SIGN_IDENTITY=- mise run build`.

Other useful commands:

```bash
mise run lint          # Core/app Clippy + workflow lints
mise run test          # Core/runtime + desktop app tests
mise run test-rust     # Domain, core and runtime tests
mise run test-app      # GPUI application tests
mise run icons         # Regenerate app icons from SVG sources
mise run pin-actions   # Pin GitHub Actions to full-length SHAs
mise run logs          # Stream macOS logs for the app process
mise run clean         # Remove build artifacts
```

## Contributing

Commits follow [Conventional Commits](https://www.conventionalcommits.org/). Pre-commit hooks validate commits and run linters automatically.

```bash
git config core.hooksPath .githooks
```

Releases are managed by [release-please](https://github.com/googleapis/release-please) — push `feat:` or `fix:` commits to `main` and a release PR will be created automatically. Merging that PR stages a draft; stable publication is a separate exact-byte manual promotion after the production go/no-go.

## Acknowledgments

Thanks to [Zach Latta](https://github.com/zachlatta) and [FreeFlow](https://github.com/zachlatta/freeflow) — the project that started it all.

## License

MIT

# Wrenflow

macOS menu bar app for speech-to-text dictation. Hold a key to record, release to transcribe.

## Build & Run

```bash
make        # Build debug .app bundle + CLI tool
make run    # Build, kill running instance, and (re)launch the app
make cli    # Build CLI tool only → build/wrenflow
make install-cli  # Copy CLI to /usr/local/bin/wrenflow
make clean  # Remove build/ and .build/
make dmg    # Build + create DMG installer
```

`make run` automatically kills any running Wrenflow instance before launching, so it always starts fresh.

The app is built as `build/Wrenflow Debug.app` via Swift Package Manager + Makefile.
Do NOT run the binary directly from `.build/debug/Wrenflow` — always use `make run` (or `open "build/Wrenflow Debug.app"`).

## Project Structure

- `Sources/` — all Swift source files (flat, no subdirectories)
- `Resources/` — app icon source
- `Package.swift` — SPM manifest
- `Makefile` — builds .app bundle, codesigns, creates DMG
- `Info.plist`, `Wrenflow.entitlements` — app metadata

### Key Files
- `AppState.swift` — central state, `@Published` properties, transcription pipeline
- `AppDelegate.swift` — app lifecycle, setup wizard flow, menu bar setup
- `SetupView.swift` — onboarding wizard (multi-step)
- `SettingsView.swift` — settings window
- `LocalTranscriptionService.swift` — on-device Parakeet transcription
- `TranscriptionService.swift` — Groq (Whisper) cloud transcription
- `HotkeyManager.swift` — global hotkey monitoring

## Data Storage

- Debug app SQLite: `~/Library/Application Support/Wrenflow Debug/PipelineHistory.sqlite`
- Release app SQLite: `~/Library/Application Support/Wrenflow/PipelineHistory.sqlite`
- CoreData uses `Z`-prefixed tables (e.g. `ZPIPELINEHISTORYENTRY`) and `Z`-prefixed columns (e.g. `ZMETRICSJSON`)
- Pipeline metrics stored as JSON in `metricsJSON` column via `PipelineMetrics` (Codable)

## Architecture Notes

- SwiftUI app with `@EnvironmentObject` AppState
- Two transcription providers: Local (Parakeet via FluidAudio) and Groq (Whisper API)
- `TranscriptionProvider` enum in `AppState.swift`
- `localTranscriptionService.initialize()` downloads the model — only call after user explicitly chooses local transcription
- Setup wizard state managed via `SetupStep` enum with rawValue-based navigation

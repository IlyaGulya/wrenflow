# Wrenflow

Menu bar speech-to-text app. Hold key → record → release → transcribe locally → paste.

## Tooling

All tools are managed by **mise**. Never run bare `cargo`, `swiftc`, or packaging
scripts — always use `mise run <task>` or `mise exec -- <cmd>`.

## Launching

`mise run run` builds and opens the signed `.app` through LaunchServices. Never
run the Mach-O directly: TCC evaluates the responsible process and the terminal
does not carry Wrenflow's microphone identity. See
[docs/tcc-debugging.md](docs/tcc-debugging.md).

## Non-Obvious Architecture

- **Single GPUI window**: `AppScreens` renders onboarding, Settings, Models,
  History and About from immutable `AppPresentation` values.
- **Typed UI boundary**: screens dispatch `AppAction` into `AppModel`; runtime
  IO crosses `RuntimeCommand`, snapshots and events.
- **ONNX Runtime**: `load-dynamic` — dylib fetched by `scripts/download-ort.sh`, copied and codesigned by the app bundle script.
- **CGEvent paste**: Replaces enigo (TSM crash). Uses `core-graphics` for Cmd+V.
- **Global hotkey**: the Swift shell owns a listen-only `CGEventTap`; presses and release durations enter the typed `AppAction` boundary.
- **One long-lived settings window**: the AppKit shell shows, focuses and hides the existing GPUI window.
- **Native overlays**: recording, transcribing and actionable error panels are SwiftUI-backed `NSPanel`s at `screenSaver` level behind the narrow Rust/Swift FFI.
- **Icons built from SVG**: `mise run icons` generates `Resources/AppIcon.icns` from `AppIcon-Dock.svg`.
- **Bundle metadata**: `native/wrenflow-gpui/macos/Info.plist` and `Wrenflow.entitlements` are copied and signed by the bundle script.
- **Audio**: Recordings saved as OGG/Opus (~15KB vs ~300KB WAV). Transcription runs from memory buffer, WAV write is parallel.
- **Paths**: Use `dirs` crate for platform data directories (history.sqlite, recordings/).
- **LSUIElement**: the app starts as a menu-bar accessory. The AppKit shell switches activation policy when showing or hiding the GPUI window.
- **No sandbox**: Required for accessibility + global hotkeys.

## Releases

See the canonical [release skill](.agents/skills/release/SKILL.md) for the full
Rust/GPUI release workflow. Quick version: merge the release-please PR to cut a
release.

## Code Signing

`Developer ID Application: Ilya Gulya (T4LV8K9BGV)`, bundle `me.gulya.wrenflow`

<!-- BEGIN BEADS_RUST INTEGRATION -->
## Beads Issue Tracker

This project uses **br (beads_rust)** for issue tracking. Run `br robot-docs guide` for the agent workflow.

**Note:** `br` is non-invasive and never executes git commands. After `br sync --flush-only`, stage `.beads/` and commit it explicitly.

### Quick Reference

```bash
br ready                # Find available work
br show <id>            # View issue details
br update <id> --claim  # Claim work
br close <id>           # Complete work
```

### Rules

- Use `br` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Use `br comments add <id> --message "..."` for persistent task knowledge — do NOT use MEMORY.md files
- Use `--json` for machine-readable output when automating

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   br sync --flush-only
   git add .beads/
   git commit -m "chore: sync beads"  # only when the index contains changes
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS_RUST INTEGRATION -->

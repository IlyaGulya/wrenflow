# Wrenflow

Menu bar speech-to-text app. Hold key → record → release → transcribe locally → paste.

## Tooling

All tools managed by **mise**. NEVER run bare `flutter`/`cargo`/`xcodegen` — always `mise run <task>` or `mise exec -- <cmd>`.

## Launching

`mise run run` builds + opens .app via `open`. NEVER use `flutter run` — TCC checks entitlements on the terminal (responsible process), blocking microphone access. See [docs/tcc-debugging.md](docs/tcc-debugging.md) for details.

## Non-Obvious Architecture

- **Single Flutter engine**: Settings (with History/About tabs) in main window via `ActiveScreen` (none/settings) — no multi-window. Rinf signals work everywhere.
- **ONNX Runtime**: `load-dynamic` — dylib fetched by `scripts/download-ort.sh`, codesigned in XcodeGen post-build.
- **CGEvent paste**: Replaces enigo (TSM crash). Uses `core-graphics` for Cmd+V.
- **raw-input**: Replaces rdev. CGEventTap hotkeys, keycode changeable at runtime.
- **No imperative windows**: `WindowSynchronizer` drives show/hide from state. Tray can also show/focus window directly.
- **Native overlays**: Recording overlay + error toasts are native NSPanels at screenSaver level, driven via `dev.gulya.wrenflow/overlay` platform channel. NOT Flutter widgets (main window is hidden during recording).
- **Icons built from SVG**: `mise run icons` — `AppIcon-Dock.svg` (dock), `AppIcon-Source.svg` (settings), `logo-bird.svg` (tray) via resvg. PNGs gitignored.
- **Info.plist generated**: XcodeGen generates from `project.yml` `info:` section. Don't edit Info.plist directly.
- **Audio**: Recordings saved as OGG/Opus (~15KB vs ~300KB WAV). Transcription runs from memory buffer, WAV write is parallel.
- **Paths**: Use `dirs` crate for platform data directories (history.sqlite, recordings/).
- **LSUIElement**: App starts as menu bar accessory (no dock icon). `dev.gulya.wrenflow/app_policy` channel toggles dock visibility when showing/hiding windows.
- **No sandbox**: Required for accessibility + global hotkeys.

## Releases

See [release skill](.claude/skills/release/SKILL.md) for the full release workflow. Quick version: merge the release-please PR to cut a release.

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

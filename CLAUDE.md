# Wrenflow

Menu bar speech-to-text app. Hold key → record → release → transcribe locally → paste.

## Tooling

All tools managed by **mise**. NEVER run bare `flutter`/`cargo`/`xcodegen` — always `mise run <task>` or `mise exec -- <cmd>`.

## Launching

`mise run run` builds + opens .app via `open`. NEVER use `flutter run` — TCC checks entitlements on the terminal (responsible process), blocking microphone access. See [docs/tcc-debugging.md](docs/tcc-debugging.md) for details.

## Non-Obvious Architecture

- **Single Flutter engine**: Settings/History in main window via `ActiveScreen` — no multi-window. Rinf signals work everywhere.
- **ONNX Runtime**: `load-dynamic` — dylib fetched by `scripts/download-ort.sh`, codesigned in XcodeGen post-build.
- **CGEvent paste**: Replaces enigo (TSM crash). Uses `core-graphics` for Cmd+V.
- **raw-input**: Replaces rdev. CGEventTap hotkeys, keycode changeable at runtime.
- **No imperative windows**: `WindowSynchronizer` drives show/hide from state. Never call `windowManager.show()/hide()`.
- **Icons built from source**: `mise run icons` — `AppIcon-Source.png` + `logo-bird.svg` via resvg. PNGs gitignored.
- **No sandbox**: Required for accessibility + global hotkeys.

## Code Signing

`Developer ID Application: Ilya Gulya (T4LV8K9BGV)`, bundle `me.gulya.wrenflow`

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:b9766037 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
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
<!-- END BEADS INTEGRATION -->

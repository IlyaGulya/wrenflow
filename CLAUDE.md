# Wrenflow

Menu bar speech-to-text app. Hold key → record → release → transcribe locally → paste.

## Tooling: mise

All tools (Flutter, Rust, XcodeGen, rinf, CocoaPods) are managed by **mise**. The system `flutter` is a different version — always use `mise run` or `mise exec --` prefix.

```bash
mise install          # One-time setup
mise run build        # Downloads ORT dylib + generates bindings + XcodeGen + Flutter build
mise run run          # Build + open .app (TCC-safe, app is its own responsible process)
mise run logs         # Tail Rust logs at /tmp/wrenflow.log
mise run analyze      # Flutter analyze (NOT bare `flutter analyze`)
mise run test         # Flutter tests
mise run check-rust   # Cargo check on hub
```

**NEVER run bare `flutter`, `dart`, `cargo`, `xcodegen`, or `rinf` commands.** Always go through mise:
- `mise run <task>` for defined tasks (see `mise.toml`)
- `mise exec -- flutter ...` for ad-hoc Flutter commands
- `mise exec -- cargo ...` for ad-hoc Cargo commands

## macOS TCC & Launching

macOS TCC checks entitlements on the **responsible process**, not just the requesting process. When launching via terminal (`flutter run`), the terminal becomes responsible — TCC requires `com.apple.security.device.audio-input` on the terminal too, which it doesn't have. **Result: microphone permission dialog never appears.**

**Always launch the built .app via `open` command** so wrenflow is its own responsible process:
```bash
mise run run    # builds + opens .app via `open` (correct)
# NOT: flutter run -d macos (terminal becomes responsible → TCC blocks mic)
```

Debug TCC issues:
```bash
/usr/bin/log stream --predicate 'subsystem == "com.apple.TCC"'  # live TCC log
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service,client,auth_value from access where client like '%wrenflow%';"
```

## Non-Obvious Architecture

- **ONNX Runtime**: `load-dynamic` feature in parakeet-rs — dylib NOT statically linked. `scripts/download-ort.sh` fetches it, XcodeGen post-build copies to `Contents/MacOS/`. If model loading deadlocks, check dylib is present.
- **raw-input crate**: Replaces rdev (which crashed on macOS). Uses CGEventTap for global hotkeys.
- **desktop_multi_window**: Forked in `vendor/desktop_multi_window` — added transparency/borderless/alwaysOnTop support.
- **Pipeline domain is paste-agnostic**: `on_transcript_ready()` emits text. Orchestrator in `hub/src/actors/mod.rs` decides paste vs display-only based on `TranscriptAction` signal from Dart. Lifecycle state machine drives this.
- **No imperative window management**: `WindowSynchronizer` reactively shows/hides based on `AppLifecycleState`. Never call `windowManager.show()/hide()` in handlers.
- **No sandbox**: Entitlements disable sandbox — required for accessibility + global hotkeys.

## Data Paths

- Model: `~/Library/Application Support/wrenflow/models/parakeet-tdt/`
- History DB: `~/Library/Application Support/wrenflow/history.sqlite`
- ORT dylib: `vendor/onnxruntime/lib/libonnxruntime.dylib`
- Rust logs: `/tmp/wrenflow.log` (truncated on each launch, `mise run logs` to tail)
- Crash log: `~/Library/Application Support/wrenflow/crash.log`

## Code Signing

Identity: `Developer ID Application: Ilya Gulya (T4LV8K9BGV)`, Bundle ID: `me.gulya.wrenflow`

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

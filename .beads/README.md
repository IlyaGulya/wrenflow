# Beads Rust Issue Tracking

This repository uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust), exposed through the `br` CLI.

`br` stores primary state in local SQLite and exports `.beads/issues.jsonl` for git collaboration. It never runs git commands or installs hooks.

## Essential Commands

```bash
br ready
br list
br show <issue-id>
br create "Issue title"
br update <issue-id> --claim
br close <issue-id> --reason "Completed"
```

## Sync and Handoff

```bash
br sync --flush-only
git add .beads/
git commit -m "chore: sync beads"
```

Run `br robot-docs guide` for the concise agent workflow and `br --help` for the full command list.

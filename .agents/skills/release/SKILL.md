---
name: release
description: >-
  Manage releases with release-please. Use when cutting a release, reviewing
  the release PR changelog, editing release notes, troubleshooting release-please,
  or when the user says "release", "cut a release", "make a release", "changelog".
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# Release Management

This project uses [release-please](https://github.com/googleapis/release-please) for automated releases.

## How It Works

1. Every `feat:` or `fix:` commit pushed to `main` updates a **Release PR** (currently PR #3)
2. Release-please auto-generates `CHANGELOG.md` from conventional commit messages
3. **When you're ready to release**: merge the Release PR
4. On merge, release-please automatically:
   - Updates `CHANGELOG.md`, `Cargo.toml`, `pubspec.yaml` with new version
   - Creates a git tag (e.g., `v0.3.0`)
   - Creates a GitHub Release
5. The GitHub Release triggers the **Build** workflow which creates a signed, notarized DMG

## Key Files

| File | Purpose |
|------|---------|
| `release-please-config.json` | Release configuration (type, changelog sections, extra-files) |
| `.release-please-manifest.json` | Tracks current released version |
| `CHANGELOG.md` | Generated changelog (updated by release-please PR) |
| `.github/workflows/release-please.yml` | GitHub Actions workflow |

## Version Sources

Version is managed in two places, both updated by release-please via `x-release-please-version` annotation:
- `Cargo.toml` — `version = "X.Y.Z" # x-release-please-version`
- `pubspec.yaml` — `version: X.Y.Z # x-release-please-version`

## Cutting a Release

### Step 1: Check the Release PR

```bash
gh pr view 3
```

The Release PR body contains the auto-generated changelog preview.

### Step 2: Review the Changelog

The changelog is generated from conventional commit messages. It groups by type:
- `feat:` → **New Features**
- `fix:` → **Bug Fixes**
- `perf:` → **Performance**
- `refactor:` → **Improvements**
- `docs:`, `style:`, `chore:`, `ci:`, `build:`, `test:` → **hidden** (not in changelog)

If the changelog needs editing, you have two options:

**Option A: Edit before merge (recommended for major releases)**

The release PR lives on branch `release-please--branches--main`. You can push commits to that branch to edit `CHANGELOG.md`. However, any new push to `main` will cause release-please to **regenerate** the PR, potentially overwriting your edits.

Best practice: make all your code changes first, wait for the PR to stabilize, then edit if needed and merge quickly.

**Option B: Edit after merge**

After merging the release PR:
1. The GitHub Release is created automatically
2. Edit the release notes on the GitHub Release page directly
3. `CHANGELOG.md` in the repo keeps the auto-generated version (good enough for git history)

### Step 3: Merge the Release PR

```bash
gh pr merge <PR_NUMBER> --squash
```

Or merge via GitHub UI. Both squash-merge and merge commits work.

### Step 4: Verify

After merge:
1. Check that the tag was created: `gh release list --limit 1`
2. Check that the Build workflow triggered: `gh run list --limit 3`
3. Wait for Build to complete — it creates a signed, notarized DMG
4. Verify the DMG is attached to the release: `gh release view <tag>`

## Writing Good Commit Messages

Release-please generates changelog from commit messages. Write them for **users**, not developers:

```
# Good — user-facing
feat: save recordings as OGG/Opus format
fix: prevent dock icon flash on startup
perf: prewarm model to eliminate first-transcription delay

# Bad — internal implementation detail
feat: add audio actor with cpal capture and level signals
fix: resolve ONNX duplicate symbol linker error with load-dynamic
refactor: remove desktop_multi_window, single Flutter engine
```

For internal changes that shouldn't appear in changelog, use hidden types:
`chore:`, `ci:`, `build:`, `docs:`, `style:`, `test:`

### Multiple changes in one commit

Use footers for multiple entries:

```
feat: configurable hotkey support

fix: prevent crash when no microphone is connected
```

## Changelog Sections Configuration

Defined in `release-please-config.json` under `changelog-sections`:

```json
"changelog-sections": [
  { "type": "feat", "section": "New Features" },
  { "type": "fix", "section": "Bug Fixes" },
  { "type": "perf", "section": "Performance" },
  { "type": "refactor", "section": "Improvements" },
  { "type": "docs", "hidden": true },
  { "type": "style", "hidden": true },
  { "type": "chore", "hidden": true },
  { "type": "ci", "hidden": true },
  { "type": "build", "hidden": true },
  { "type": "test", "hidden": true }
]
```

## Beta Releases

The Build workflow automatically creates beta pre-releases on every push to `main`:
- Tag format: `v0.3.0-beta.N` (N = commit count since last stable tag)
- These are marked as pre-release on GitHub
- DMG is attached for testing

## Forcing a Version

To force a specific version (skip conventional commit version calculation):

Add `"release-as": "1.0.0"` to the package config in `release-please-config.json`:

```json
{
  "packages": {
    ".": {
      "release-as": "1.0.0",
      ...
    }
  }
}
```

**Remove this after the release PR is merged**, or it will keep proposing the same version.

## Troubleshooting

### Release PR not updating
- Release-please only runs on push to `main`
- Check the workflow: `gh run list --workflow "Release Please"`
- The PR updates automatically; force-pushing or rebasing `main` can confuse it

### Wrong version proposed
- Check `.release-please-manifest.json` — it tracks the last released version
- Manually edit the manifest if it's out of sync

### Changelog includes unwanted commits
- Use hidden types (`chore:`, `ci:`) for internal changes
- Use squash-merge for PRs to control the final commit message

### Release PR was merged but no GitHub Release appeared
- Check `autorelease: tagged` label on the merged PR
- Verify the release-please workflow ran after merge
- Check workflow logs: `gh run list --workflow "Release Please"`

## Reference

Full release-please documentation is available at `vendor/release-please/docs/`:
- [Customizing releases](vendor/release-please/docs/customizing.md)
- [Manifest configuration](vendor/release-please/docs/manifest-releaser.md)
- [Troubleshooting](vendor/release-please/docs/troubleshooting.md)

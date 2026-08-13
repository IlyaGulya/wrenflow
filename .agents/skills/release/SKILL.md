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

1. Every `feat:` or `fix:` commit pushed to `main` updates the open **Release PR**
2. Release-please auto-generates `CHANGELOG.md` from conventional commit messages
3. **When you're ready to stage the final candidate**: merge the Release PR
4. On merge, release-please automatically:
   - Updates `CHANGELOG.md`, the root `Cargo.toml`, and the isolated GPUI `Cargo.toml` with the new version
   - Creates a private, tagless GitHub Release draft whose target is the exact
     release commit; the workflow derives its immutable numeric release ID from
     release-please's official `upload_url`
5. When `release_created` is true, Release Please explicitly calls the reusable
   **Build** workflow. That workflow tests, lints, signs, notarizes, verifies and
   uploads the exact DMG to the empty draft, retaining the Actions payload for
   21 days. For the first stable draft it also revalidates the pinned beta.64
   frozen 24/24 artifact and approved non-runtime source diff instead of rerunning
   the 30-minute sampler. It does not publish stable.
6. After the draft bytes pass the owner acceptance gates and recorded
   go/no-go, manually dispatch **Promote Verified Stable Draft** with the exact
   tag, approved DMG SHA-256 and confirmation. It re-downloads/verifies the
   staged payload, publishes the draft and creates the stable tag at the
   draft's verified source commit; all private reads/uploads/downloads and the
   publication PATCH use that exact release ID, and it never rebuilds or replaces assets.

## Key Files

| File | Purpose |
|------|---------|
| `release-please-config.json` | Release configuration (type, changelog sections, extra-files) |
| `.release-please-manifest.json` | Tracks current released version |
| `CHANGELOG.md` | Generated changelog (updated by release-please PR) |
| `.github/workflows/release-please.yml` | GitHub Actions workflow |
| `.github/workflows/promote-stable.yml` | Manual exact-byte stable promotion |
| `docs/production-release-runbook.md` | Cohort, go/no-go and promotion procedure |

## Version Sources

Version is managed in two places, both updated by release-please via the
`x-release-please-version` annotation:

- `Cargo.toml` — root workspace version
- `native/wrenflow-gpui/Cargo.toml` — isolated GPUI workspace version

## Cutting a Release

### Step 1: Check the Release PR

```bash
gh pr list --state open --search "release in:title"
gh pr view <PR_NUMBER>
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
1. The draft GitHub Release is created automatically
2. Edit the draft notes before final go/no-go; do not alter staged assets
3. `CHANGELOG.md` in the repo keeps the auto-generated version (good enough for git history)

### Step 3: Merge the Release PR to stage a draft

```bash
gh pr merge <PR_NUMBER> --squash
```

Or merge via GitHub UI. Both squash-merge and merge commits work.

### Step 4: Verify the staged candidate

After merge:
1. Check that the tagless private draft was created with the expected source:
   `gh api repos/IlyaGulya/wrenflow/releases/<release_id>`
2. Inspect the same Release Please workflow run and confirm its
   `build-staged-stable-release` reusable-workflow job started
3. Wait for that job to complete — it runs tests/lints, creates a Developer ID
   signed DMG, requires explicit `Accepted` notarization, staples and validates
   it, passes Gatekeeper verification, and fail-closed revalidates the pinned
   beta.64 24/24 baseline before upload
4. Verify the DMG is attached while `isDraft` remains true. Download the exact
   payload and complete `.9.8`–`.9.11`; do not rebuild it.

If the automatic reusable Build fails before attaching any assets, recover the
same empty draft without recreating it:

```bash
mise exec -- gh workflow run build.yml \
  -f release_tag=<tag> \
  -f release_id=<positive-numeric-private-draft-id> \
  -f release_tool_source_commit=a81827311a8aa5745a88e1f4a081746ce820a6f5 \
  -f release_source_commit=<targetCommitish> \
  -f verifier_source_commit=e233cc6db6b37307e9774db228ab11ecc4d0673c \
  -f confirmation=STAGE_EXISTING_PRIVATE_DRAFT
```

The recovery workflow rejects a nonempty draft, a mismatched source commit, an
already-created stable tag, or verifier bytes other than reviewed commit
`e233cc6db6b37307e9774db228ab11ecc4d0673c`.

If the exact nine assets are already attached but the private re-download
verification did not complete, never rerun staging or replace the assets. Use
the verification-only dispatch:

```bash
mise exec -- gh workflow run build.yml \
  -f release_tag=<tag> \
  -f release_id=<positive-numeric-private-draft-id> \
  -f release_tool_source_commit=a81827311a8aa5745a88e1f4a081746ce820a6f5 \
  -f release_source_commit=<targetCommitish> \
  -f verifier_source_commit=e233cc6db6b37307e9774db228ab11ecc4d0673c \
  -f confirmation=VERIFY_EXISTING_PRIVATE_DRAFT
```

This mode performs only immutable asset-ID downloads and exact candidate
verification. It does not build, upload, edit, publish, or recreate a release.

The known `v0.4.0` private payload whose release evidence recorded the workflow
event SHA instead of the stable source may be replaced once with the reviewed
repair mode. It is bound to release ID `369445618`, source `7e0e698…`, the
literal invalid fingerprint `086ec8d…`, all nine immutable old asset
IDs/digests, and recoverable signed payload artifact `9163585962` from run
`31652943641`. Use only the exact command in
`docs/production-release-runbook.md`; any partial repair remains private and
requires a newly reviewed exact manifest rather than an automatic retry.

### Step 5: Promote the exact bytes after go/no-go

```bash
mise exec -- gh workflow run promote-stable.yml \
  -f release_tag=<tag> \
  -f release_id=<positive-numeric-private-draft-id> \
  -f release_tool_source_commit=a81827311a8aa5745a88e1f4a081746ce820a6f5 \
  -f expected_dmg_sha256=<64-lowercase-hex> \
  -f confirmation=PROMOTE_VERIFIED_STABLE
```

The job targets the `stable-production` GitHub Environment. Required reviewers
add a hold when configured, but their presence must be verified rather than
assumed. After success, verify `isDraft == false`, `isPrerelease == false`,
`releases/latest` resolves to the tag, and the public DMG hash still matches.

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
refactor: move window state synchronization into AppModel
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

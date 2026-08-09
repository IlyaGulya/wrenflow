# ADR 001: authenticated GPUI-line automatic updater

Status: accepted for the GPUI production line.

## Decision

Wrenflow uses an in-app automatic updater, not a generic “open the latest
release in a browser” action. The old shell implementation that copied URLs
from arbitrary GitHub JSON into `OpenUrl` is not part of the production
contract. A browser is never the update trust boundary.

The application checks only the public GitHub Releases API endpoint for
`IlyaGulya/wrenflow`, and only after an explicit user action. GitHub's current
release-asset representation includes a `sha256:` digest and documents binary
downloads through the asset URL. The updater requires that digest rather than
treating it as optional. See [GitHub release asset API](https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28).

An update is accepted only when all of these identities agree:

1. The feed is fetched over HTTPS from the exact `api.github.com` repository
   endpoint with a bounded response and current API-version header.
2. The release has a canonical `v<semver>` tag, is not a draft and has exactly
   one `Wrenflow.dmg` asset. The URL must be the exact repository/tag/asset
   path. Only GitHub's HTTPS release-asset hosts are accepted for redirects.
3. The API-provided SHA-256 digest, declared size and downloaded bytes agree.
   A partial, oversized or mismatched file is deleted without publication.
4. macOS validates the signed and stapled DMG, Gatekeeper assessment and the
   deep signature of `Wrenflow.app`. Apple describes Developer ID signing,
   notarization and stapled offline tickets in [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
5. Bundle ID is `me.gulya.wrenflow`, Team ID is `T4LV8K9BGV`, all shipped
   Mach-O files are exactly arm64 with minimum macOS 14.0, the app version is
   the selected release, and embedded supply-chain checksums/pins match the
   current checked-in release contract used by `.9.7`.

The feed and artifact are therefore only discovery/transport inputs. The
Developer ID/notarization identity, exact digest and embedded production
contract authenticate what can be installed.

## Stable and beta policy

- Stable is the default channel. It considers only non-prerelease SemVer
  releases newer than the installed version.
- Beta is explicit opt-in. It considers both prereleases and stable releases
  and selects the highest SemVer precedence, so a final stable supersedes its
  beta.
- The `prerelease` API flag must agree with SemVer. Drafts, duplicate versions,
  malformed tags and ambiguous/missing DMGs fail closed.
- Versions below `0.3.0`, versions from another SemVer major line, downgrades
  and the installed version are never install candidates. Pre-GPUI imports and
  cross-line rollback are intentionally unsupported.
- Network offline, rate limit, service failure, invalid metadata and every
  verification failure have closed UI/diagnostic codes. A GitHub response body
  or third-party error string is never a diagnostic field.

The current release workflow already publishes stable releases from
release-please and `vX.Y.Z-beta.N` prereleases from `main`; both use the same
signed, notarized `Wrenflow.dmg` payload and `.9.7` verifier.

## Atomic installation and interruption recovery

The verified app is copied to a hidden staging bundle beside the installed
app, restricted to `/Applications/Wrenflow.app` or
`~/Applications/Wrenflow.app`. The installed bundle remains untouched until
the entire staged bundle passes verification a second time.

A private `gpui-v1/updates/update-transaction.json` stores only schema,
versions, closed install-root enum, release/asset token and SHA-256. The running
signed executable starts itself in a narrowly parsed helper mode containing
only the old PID and transaction token, then follows normal typed shutdown.
After that PID exits, macOS `renameatx_np(RENAME_SWAP)` exchanges the staged and
installed app directories atomically on the same volume. There is no interval
where the installed path contains a partial app.

Downloaded update storage is bounded to the one selected canonical
`Wrenflow-<semver>.dmg` plus its in-progress partial file. Before another
download, older canonical DMGs are removed; unknown files and symlinks are
never treated as updater-owned cleanup targets. The selected DMG is removed
after finalization or abandoned-transaction recovery.

If scheduling or verification fails, the installed app was never changed. If
the helper is interrupted, the swap is either wholly before or wholly after
the interruption. At the next ready launch, version/identity inspection
classifies the transaction:

- staging journal + unchanged installed app: remove only the exact interrupted
  staging directory, then clear the journal;
- old installed + verified new staged: discard the uninstalled candidate;
- selected new installed + signed old staged: finalize the update and move the
  old bundle to Trash;
- any other combination: make no destructive guess, surface
  `recovery_required`, and direct the user to current-line reinstall/reset.

This is transaction recovery, not a supported downgrade or rollback feature.
After the new app reports runtime and native-shell readiness, the previous app
is moved to Trash and the journal is removed. Current `gpui-v1` data and TCC
identity remain in place. A crash loop enters the safe runtime with platform IO
disabled so diagnostics can be exported and current data can be explicitly
reset or the current line reinstalled.

## Rejected alternatives

- Opening `browser_download_url` or a release page: the response controls user
  navigation, verification happens too late, and partial install state is not
  recoverable.
- Integrating Sparkle now: it adds a second feed/signature/update lifecycle and
  supply-chain surface when Wrenflow already owns notarized release metadata,
  exact bundle verification and an atomic install primitive.
- Silently falling back from automatic update to an unverified download: this
  converts an authentication failure into code execution and is prohibited.
- Keeping an in-product rollback button: clean-break releases make no
  cross-version data compatibility promise. Recovery is reset/reinstall only.

Human update/endurance proof remains owned by `.9.11`; this ADR and its unit
tests define the automated fail-closed contract.

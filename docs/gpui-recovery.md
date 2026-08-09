# GPUI crash, update and support recovery

All recovery state belongs to the current `gpui-v1` namespace. It never reads
Flutter state and never promises a downgrade or rollback.

## Launch transaction and crash loop

The primary process begins recovery only after the native single-instance
guard accepts it. `recovery/launch-state.json` is an atomic, `0600` closed
marker with phase, timestamps and a consecutive-unclean counter; it contains no
arguments, paths, errors or product content. Normal shell/runtime readiness
changes `starting` to `running`, and typed orderly shutdown changes it to
`clean`. Panic, SIGKILL and power loss cannot produce the clean transition.

Three prior unclean launches in five minutes select safe recovery. The runtime
then starts without audio, model, history or paste platform services, keeping a
small typed UI available for support export and explicit reset/reinstall. A
single unclean launch is reported as recovered but does not disable the normal
runtime. This policy avoids an unusable infinite restart loop without treating
one OS shutdown or power loss as corruption.

At next launch Wrenflow removes only strict current-line temporary patterns:

- `config.json.tmp-*` atomic-write siblings;
- `.recording_*.ogg.tmp-*` unpublished recordings;
- model `*.part` downloads;
- update `*.partial` / `*.download` files.

Complete recordings, verified models, configuration, SQLite WAL/SHM and
quarantined evidence are not deleted. SQLite opens with full durability and
performs its own current-schema integrity recovery as documented in
[GPUI current-data integrity](gpui-data-integrity.md). Cleanup diagnostics are
fixed codes and omit filenames/counts.

## Support bundle

The support bundle is a deterministic JSON document with extension
`.wrenflow-support.json`. It consumes `collect_diagnostics()`; it never reads
history, recordings, models, configuration, clipboard or legacy logs. A second
strict parser accepts only the seven rotated diagnostic filenames and the
closed diagnostic schema, drops malformed/unknown-field records, sorts files,
and writes at most 3 MiB atomically with mode `0600`.

The manifest contains only app version, OS family, architecture, literal
`remote_telemetry: "disabled"`, closed update state and closed recovery
counters/actions. It contains no local path. Generation is local and explicit;
there is no upload endpoint. The explicit Export action writes the private
bundle to the user's Downloads folder under a closed timestamped filename; the
full destination path never enters diagnostics or bundle contents. The user
reviews and chooses whether to share it. Wrenflow does not retain another
staging copy after export.

## Update failures

The authenticated updater and atomic transaction are specified in
[ADR 001](adr-001-gpui-updater.md). Failures never open a response-provided URL.
Retry is available for offline, rate-limit, partial-transfer and temporary
service/storage cases. Digest, signature, notarization, bundle, support or
supply-chain mismatches are permanent for that candidate and require a newer
valid release. An ambiguous interrupted transaction offers diagnostics and the
documented current-data reset/current-line reinstall paths without deleting a
possibly launchable bundle.

Automated coverage:

```bash
mise exec -- cargo test -p wrenflow-runtime recovery:: -- --test-threads=1
mise exec -- cargo test -p wrenflow-runtime support:: -- --test-threads=1
mise exec -- cargo test -p wrenflow-runtime update:: -- --test-threads=1
mise run test-endurance-preflight
```

`.9.11` owns the signed human M13/M15 update and crash acceptance on an
installed candidate; unit tests do not claim that external proof. The exact
candidate/fault/sleep/device procedure is
[GPUI current-line endurance and fault acceptance](gpui-endurance-acceptance.md).

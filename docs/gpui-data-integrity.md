# GPUI current-data integrity contract

Wrenflow's GPUI release line owns one macOS data namespace:

```text
~/Library/Application Support/me.gulya.wrenflow/gpui-v1/
  config.json
  history.sqlite
  models/
  recordings/
  diagnostics/events.ndjson
  diagnostics/crashes.ndjson
  recovery/launch-state.json
  updates/update-transaction.json
```

The `gpui-v1` directory names the data contract, not a migration sequence.
Wrenflow deliberately provides no compatibility across namespace versions and
does not inspect older Flutter roots, preference plists or database schemas.
The bundle identifier remains `me.gulya.wrenflow` only to preserve the app's
macOS signing, LaunchServices and TCC identity.

## Configuration

`config.json` is serialized completely before touching the destination. Each
save creates a unique sibling temporary file, writes and flushes all bytes,
calls `fsync`, atomically renames the file over the destination, then syncs the
parent directory. Concurrent saves can select the last complete document, but
cannot publish partial JSON. A failure before rename retains the previous valid
configuration and removes the temporary file.

Invalid JSON is never converted to defaults in place. The file is renamed to a
unique `config.json.corrupt-*` sibling, the parent directory is synced and
startup fails with the quarantine path in both the runtime error and log. A
subsequent launch may create a fresh default only because the invalid original
is preserved separately.

## History

`history.sqlite` is a current-format-only SQLite database with
`PRAGMA user_version = 1`. A fresh database creates the schema in an immediate
transaction. Every open enables WAL, a five-second busy timeout, full
synchronous durability and foreign-key enforcement, then runs
`integrity_check` and validates the exact table and column set.

Insert, replace, trim, delete and clear operations are transactional. A dropped
or interrupted transaction leaves the previous committed rows intact. A
database with failed integrity, a different `user_version`, extra schema or the
old `raw_transcript` column is not altered. Wrenflow moves the database and its
WAL/SHM companions to unique `history.sqlite.corrupt-*` files and surfaces an
actionable startup error. No `ALTER TABLE`, import or legacy row copy exists.

## Other state and recovery

Recordings, verified model assets and crash diagnostics resolve only below the
same `gpui-v1` root. Model files are downloaded into `.part` files and published
only after size and SHA-256 verification. Bounded structured events and panic
markers live under `diagnostics/`; no old crash log is read. Rotation,
retention, permissions and support-export limits are defined in
[GPUI production diagnostics](gpui-diagnostics.md).

Crash-loop state, strict cleanup of unpublished temporary files and
interrupted-update classification are defined in
[GPUI crash, update and support recovery](gpui-recovery.md). Recovery never
deletes a complete recording, a verified model or SQLite WAL/SHM files.

The supported destructive recovery is explicit and recoverable through macOS
Trash:

```bash
mise run reset-app-data -- --current-data --relaunch
```

This command stops the app and removes exactly the versioned current-data root.
It enumerates config, history, models, recordings and diagnostics through that
root. Legacy data removal is a separate opt-in scope; neither reset changes TCC
consent. See `docs/gpui-production-lifecycle.md` for uninstall and legacy-data
commands.

The deterministic regression coverage lives in `config_store`, `history_store`
and `data_paths` unit tests. It covers clean and populated stores, atomic-write
interruption, concurrent writers, disk/path errors, corrupt JSON and SQLite,
transaction rollback, schema rejection, and populated Flutter fixtures that
remain untouched.

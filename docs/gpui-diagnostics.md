# GPUI production diagnostics contract

Wrenflow emits local-only structured diagnostics for troubleshooting the GPUI
release line. There is no remote telemetry or crash upload. The only Unified
Logging subsystem is `me.gulya.wrenflow`, with these stable categories:

| Category | Scope |
| --- | --- |
| `lifecycle` | startup, shutdown and privacy-safe panic markers |
| `permissions` | permission state transitions, never device names |
| `hotkey` | hotkey lifecycle, never typed keys or target applications |
| `recording` | state transitions, never samples or recording paths |
| `transcription` | state transitions, never transcript or vocabulary content |
| `models` | model state transitions, never arbitrary errors or paths |
| `history` | persistence outcomes, never rows or transcript metadata |
| `updates` | update state and verification outcomes |
| `bridge` | typed Rust/AppKit bridge outcomes |

The closed levels are `trace`, `debug`, `info`, `warning` and `error`. Release
builds cap Rust logging at `info`, regardless of `RUST_LOG`; debug builds may
opt into more detail. The structured boundary is identical at every level.

## Schema and privacy boundary

Each record is one schema-versioned JSON object containing only:

- timestamp, ephemeral launch `session_id` and optional operation
  `correlation_id`;
- category, level and a closed `DiagnosticCode` value;
- an optional sanitized Rust module target and source line;
- for `startup` only: app version, OS family, architecture, debug/release
  profile and the literal `remote_telemetry: "disabled"` statement.

Free-form `log!` arguments are never formatted by the production logger. This
is fail-closed by design: old errors can contain a transcript, custom
vocabulary, microphone name, credential or full user path. They become a
`runtime_log` marker with source target/line. Panic payloads and thread names
are omitted; only a `rust_panic` marker and basename/line are retained.

The C shim calls `os_log_with_type` with `%{public}s`. Marking the bounded JSON
record public is safe because private values cannot enter the schema. Raw
values are not passed as `private` arguments and are not hashed: low-entropy
transcripts or device names could otherwise be recovered by guessing.

Recording/transcription stages share an ephemeral correlation ID, so one flow
can be followed without transcript, audio, duration, filename, microphone or
target-application data. IDs reset on each process launch and are not device
identifiers.

Typed runtime commands also emit payload-free markers: permission and login
item observations, hotkey press/release, model activation/cancellation,
history delete/clear, update status and shell capability publication. Values
inside those commands are never serialized. Settings changes intentionally
have no generic marker because vocabulary, microphone and hotkey values share
that command family; a failed durable write emits only `settings_write_failed`.

Swift/AppKit failures cross a registered C callback as one `UInt8`, never as a
string. The stable mapping is:

| Code | Diagnostic event |
| --- | --- |
| 1 | `swift_shell_install_failed` |
| 2 | `swift_login_item_failed` |
| 3 | `swift_uninstall_evidence_failed` |
| 4 | `swift_bridge_decode_failed` |
| 5 | `swift_accessibility_failed` |
| other | `swift_shell_failure` |

The callback is installed before the AppKit shell and cleared after synchronous
shutdown. This keeps the standalone Swift dylib linkable and routes its events
through the same Rust session, Unified Logging sink and bounded files.

## Bounded local files

Unified Logging is complemented by local NDJSON because `.9.3` needs a
deterministic, reviewable support export and panic markers must survive process
exit. Files live only below:

```text
gpui-v1/diagnostics/
  events.ndjson
  events.1.ndjson ... events.3.ndjson
  crashes.ndjson
  crashes.1.ndjson ... crashes.2.ndjson
```

The directory mode is forced to `0700` and files to `0600` on every open.
Event segments are at most 512 KiB and retained for seven days; crash segments
are at most 128 KiB and retained for 30 days. Rotation happens before an append
would cross the limit. Expired allowlisted segments are purged at startup and
periodically. A single record is at most 4 KiB. A storage/permission failure is
non-fatal and does not fall back to an unbounded or less-private location.

`collect_diagnostics()` is the support-bundle boundary for `.9.3`. It returns
at most 2 MiB in memory, reads only the seven allowlisted filenames, parses
every line back into the closed schema and discards malformed/tampered lines.
It exposes no application-support path. Users must still review a bundle
before sharing it.

`.9.3` consumes that boundary into one deterministic, at-most-3-MiB local JSON
bundle. It reparses the closed records, drops unknown fields/files, contains no
path, and is written atomically with mode `0600`. See
[GPUI crash, update and support recovery](gpui-recovery.md). It does not add a
second logger or an upload service.

The legacy `/tmp/wrenflow.log` is never read and is removed by exact filename
at production diagnostics initialization. No other `/tmp` path is touched.

## Operations and verification

Stream or query only the Wrenflow subsystem:

```bash
/usr/bin/log stream --style compact \
  --predicate 'subsystem == "me.gulya.wrenflow"'
/usr/bin/log show --last 5m --style compact \
  --predicate 'subsystem == "me.gulya.wrenflow" AND category == "transcription"'
```

Unit coverage exercises schema stability, correlation, private fixtures,
rotation, retention, permissions, tampered export input and storage failure:

```bash
mise exec -- cargo test -p wrenflow-runtime diagnostics:: -- --test-threads=1
```

Swift/AppKit uses the same subsystem, categories and fixed event codes through
the narrow bridge. Swift must never interpolate `localizedDescription`, URLs,
paths, tray payloads or accessibility JSON into `Logger` calls.

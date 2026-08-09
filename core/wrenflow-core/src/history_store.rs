//! Current-format GPUI history persistence.
//!
//! The database has exactly one schema version. A database with any other
//! version or shape is quarantined, never migrated or silently overwritten.

use rusqlite::{params, Connection, ErrorCode, OptionalExtension, TransactionBehavior};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use thiserror::Error;
use wrenflow_domain::history::HistoryEntry;

pub const CURRENT_HISTORY_SCHEMA_VERSION: i64 = 1;
const HISTORY_COLUMNS: [&str; 6] = [
    "id",
    "timestamp",
    "transcript",
    "custom_vocabulary",
    "audio_file_name",
    "metrics_json",
];
static QUARANTINE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Error)]
pub enum HistoryError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("not a current-format history database: {0}")]
    InvalidCurrentSchema(String),
    #[error(
        "current history at {path} failed validation and was quarantined at {quarantined}: {reason}"
    )]
    CorruptQuarantined {
        path: PathBuf,
        quarantined: PathBuf,
        reason: String,
    },
    #[error(
        "current history at {path} failed validation ({reason}) and could not be quarantined: {quarantine_error}"
    )]
    CorruptNotQuarantined {
        path: PathBuf,
        reason: String,
        quarantine_error: std::io::Error,
    },
}

pub struct HistoryStore {
    conn: Connection,
}

impl HistoryStore {
    pub fn open(db_path: &Path) -> Result<Self, HistoryError> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let existed = db_path.exists();
        match Self::open_current(db_path, existed) {
            Ok(store) => Ok(store),
            Err(error) if existed && is_quarantinable(&error) => {
                let reason = error.to_string();
                match quarantine_database(db_path) {
                    Ok(quarantined) => Err(HistoryError::CorruptQuarantined {
                        path: db_path.to_path_buf(),
                        quarantined,
                        reason,
                    }),
                    Err(quarantine_error) => Err(HistoryError::CorruptNotQuarantined {
                        path: db_path.to_path_buf(),
                        reason,
                        quarantine_error,
                    }),
                }
            }
            Err(error) => Err(error),
        }
    }

    fn open_current(db_path: &Path, existed: bool) -> Result<Self, HistoryError> {
        let mut conn = Connection::open(db_path)?;
        configure_connection(&conn)?;
        if existed {
            validate_integrity(&conn)?;
            validate_current_schema(&conn)?;
        } else {
            initialize_schema(&mut conn)?;
        }
        Ok(Self { conn })
    }

    pub fn open_in_memory() -> Result<Self, HistoryError> {
        let mut conn = Connection::open_in_memory()?;
        configure_connection(&conn)?;
        initialize_schema(&mut conn)?;
        Ok(Self { conn })
    }

    pub fn schema_version(&self) -> Result<i64, HistoryError> {
        Ok(self
            .conn
            .pragma_query_value(None, "user_version", |row| row.get(0))?)
    }

    pub fn integrity_check(&self) -> Result<(), HistoryError> {
        validate_integrity(&self.conn)
    }

    pub fn insert(&mut self, entry: &HistoryEntry) -> Result<(), HistoryError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT INTO pipeline_history
             (id, timestamp, transcript, custom_vocabulary, audio_file_name, metrics_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(id) DO UPDATE SET
               timestamp = excluded.timestamp,
               transcript = excluded.transcript,
               custom_vocabulary = excluded.custom_vocabulary,
               audio_file_name = excluded.audio_file_name,
               metrics_json = excluded.metrics_json",
            params![
                entry.id,
                entry.timestamp,
                entry.transcript,
                entry.custom_vocabulary,
                entry.audio_file_name,
                entry.metrics_json,
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn load_all(&self) -> Result<Vec<HistoryEntry>, HistoryError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, timestamp, transcript, custom_vocabulary, audio_file_name, metrics_json
             FROM pipeline_history ORDER BY timestamp DESC",
        )?;
        let entries = stmt
            .query_map([], |row| {
                Ok(HistoryEntry {
                    id: row.get(0)?,
                    timestamp: row.get(1)?,
                    transcript: row.get(2)?,
                    custom_vocabulary: row.get(3)?,
                    audio_file_name: row.get(4)?,
                    metrics_json: row.get(5)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(entries)
    }

    pub fn trim(&mut self, max_count: usize) -> Result<Vec<String>, HistoryError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let removed_files = {
            let mut stmt = tx.prepare(
                "SELECT audio_file_name FROM pipeline_history
                 ORDER BY timestamp DESC LIMIT -1 OFFSET ?1",
            )?;
            let files = stmt
                .query_map(params![max_count], |row| row.get::<_, Option<String>>(0))?
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .collect();
            files
        };
        tx.execute(
            "DELETE FROM pipeline_history WHERE id NOT IN
             (SELECT id FROM pipeline_history ORDER BY timestamp DESC LIMIT ?1)",
            params![max_count],
        )?;
        tx.commit()?;
        Ok(removed_files)
    }

    pub fn delete(&mut self, id: &str) -> Result<Option<String>, HistoryError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let audio = tx
            .query_row(
                "SELECT audio_file_name FROM pipeline_history WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        tx.execute("DELETE FROM pipeline_history WHERE id = ?1", params![id])?;
        tx.commit()?;
        Ok(audio)
    }

    pub fn clear_all(&mut self) -> Result<Vec<String>, HistoryError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let files = {
            let mut stmt = tx.prepare("SELECT audio_file_name FROM pipeline_history")?;
            let files = stmt
                .query_map([], |row| row.get::<_, Option<String>>(0))?
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .collect();
            files
        };
        tx.execute("DELETE FROM pipeline_history", [])?;
        tx.commit()?;
        Ok(files)
    }

    pub fn count(&self) -> Result<usize, HistoryError> {
        let count: i64 =
            self.conn
                .query_row("SELECT COUNT(*) FROM pipeline_history", [], |row| {
                    row.get(0)
                })?;
        Ok(count as usize)
    }
}

fn configure_connection(conn: &Connection) -> Result<(), HistoryError> {
    conn.busy_timeout(Duration::from_secs(5))?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "FULL")?;
    Ok(())
}

fn initialize_schema(conn: &mut Connection) -> Result<(), HistoryError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute_batch(
        "CREATE TABLE pipeline_history (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            transcript TEXT NOT NULL DEFAULT '',
            custom_vocabulary TEXT NOT NULL DEFAULT '',
            audio_file_name TEXT,
            metrics_json TEXT NOT NULL DEFAULT '{}'
        );
        PRAGMA user_version = 1;",
    )?;
    tx.commit()?;
    Ok(())
}

fn validate_integrity(conn: &Connection) -> Result<(), HistoryError> {
    let result: String = conn.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    if result == "ok" {
        Ok(())
    } else {
        Err(HistoryError::InvalidCurrentSchema(format!(
            "integrity_check returned {result}"
        )))
    }
}

fn validate_current_schema(conn: &Connection) -> Result<(), HistoryError> {
    let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if version != CURRENT_HISTORY_SCHEMA_VERSION {
        return Err(HistoryError::InvalidCurrentSchema(format!(
            "user_version {version}, expected {CURRENT_HISTORY_SCHEMA_VERSION}; migrations are intentionally unsupported"
        )));
    }

    let tables: Vec<String> = {
        let mut stmt = conn.prepare(
            "SELECT name FROM sqlite_schema
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        )?;
        let tables = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        tables
    };
    if tables != ["pipeline_history"] {
        return Err(HistoryError::InvalidCurrentSchema(format!(
            "unexpected tables: {tables:?}"
        )));
    }

    let columns: Vec<String> = {
        let mut stmt = conn.prepare("PRAGMA table_info('pipeline_history')")?;
        let columns = stmt
            .query_map([], |row| row.get(1))?
            .collect::<Result<Vec<_>, _>>()?;
        columns
    };
    if columns != HISTORY_COLUMNS {
        return Err(HistoryError::InvalidCurrentSchema(format!(
            "unexpected pipeline_history columns: {columns:?}"
        )));
    }
    Ok(())
}

fn is_quarantinable(error: &HistoryError) -> bool {
    match error {
        HistoryError::InvalidCurrentSchema(_) => true,
        HistoryError::Sqlite(rusqlite::Error::SqliteFailure(failure, _)) => matches!(
            failure.code,
            ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase
        ),
        _ => false,
    }
}

fn quarantine_database(path: &Path) -> std::io::Result<PathBuf> {
    let sequence = QUARANTINE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let marker = format!("corrupt-{timestamp}-{}-{sequence}", std::process::id());
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("history.sqlite");
    let quarantined = path.with_file_name(format!("{file_name}.{marker}"));
    std::fs::rename(path, &quarantined)?;

    for suffix in ["-wal", "-shm"] {
        let auxiliary = path.with_file_name(format!("{file_name}{suffix}"));
        if auxiliary.exists() {
            let quarantined_auxiliary =
                path.with_file_name(format!("{file_name}{suffix}.{marker}"));
            std::fs::rename(auxiliary, quarantined_auxiliary)?;
        }
    }
    sync_directory(path.parent().unwrap_or_else(|| Path::new(".")))?;
    Ok(quarantined)
}

#[cfg(unix)]
fn sync_directory(directory: &Path) -> std::io::Result<()> {
    std::fs::File::open(directory)?.sync_all()
}

#[cfg(not(unix))]
fn sync_directory(_directory: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(id: &str, ts: f64) -> HistoryEntry {
        HistoryEntry {
            id: id.to_string(),
            timestamp: ts,
            transcript: "hello".to_string(),
            custom_vocabulary: String::new(),
            audio_file_name: Some(format!("{id}.ogg")),
            metrics_json: "{}".to_string(),
        }
    }

    #[test]
    fn fresh_database_has_explicit_current_schema() {
        let dir = tempfile::tempdir().unwrap();
        let store = HistoryStore::open(&dir.path().join("history.sqlite")).unwrap();
        assert_eq!(
            store.schema_version().unwrap(),
            CURRENT_HISTORY_SCHEMA_VERSION
        );
        store.integrity_check().unwrap();
    }

    #[test]
    fn insert_and_load() {
        let mut store = HistoryStore::open_in_memory().unwrap();
        store.insert(&make_entry("a", 1000.0)).unwrap();
        store.insert(&make_entry("b", 2000.0)).unwrap();
        let entries = store.load_all().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].id, "b");
    }

    #[test]
    fn repeated_open_retains_populated_current_database() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        {
            let mut store = HistoryStore::open(&path).unwrap();
            store.insert(&make_entry("persisted", 42.0)).unwrap();
        }

        let reopened = HistoryStore::open(&path).unwrap();
        assert_eq!(reopened.schema_version().unwrap(), 1);
        assert_eq!(reopened.load_all().unwrap()[0].id, "persisted");
        reopened.integrity_check().unwrap();
    }

    #[test]
    fn trim_keeps_newest() {
        let mut store = HistoryStore::open_in_memory().unwrap();
        for i in 0..5 {
            store
                .insert(&make_entry(&format!("e{i}"), i as f64 * 1000.0))
                .unwrap();
        }
        let removed = store.trim(3).unwrap();
        assert_eq!(removed.len(), 2);
        assert_eq!(store.count().unwrap(), 3);
    }

    #[test]
    fn delete_returns_audio_file() {
        let mut store = HistoryStore::open_in_memory().unwrap();
        store.insert(&make_entry("x", 1000.0)).unwrap();
        let audio = store.delete("x").unwrap();
        assert_eq!(audio, Some("x.ogg".to_string()));
        assert_eq!(store.count().unwrap(), 0);
    }

    #[test]
    fn clear_all_returns_files() {
        let mut store = HistoryStore::open_in_memory().unwrap();
        store.insert(&make_entry("a", 1000.0)).unwrap();
        store.insert(&make_entry("b", 2000.0)).unwrap();
        let files = store.clear_all().unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(store.count().unwrap(), 0);
    }

    #[test]
    fn dropped_transaction_leaves_previous_state() {
        let mut store = HistoryStore::open_in_memory().unwrap();
        store.insert(&make_entry("before", 1.0)).unwrap();
        {
            let tx = store
                .conn
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .unwrap();
            tx.execute(
                "INSERT INTO pipeline_history
                 (id, timestamp, transcript, custom_vocabulary, metrics_json)
                 VALUES ('interrupted', 2, 'partial', '', '{}')",
                [],
            )
            .unwrap();
        }
        assert_eq!(store.count().unwrap(), 1);
        assert_eq!(store.load_all().unwrap()[0].id, "before");
    }

    #[test]
    fn corrupt_database_is_quarantined_and_never_silently_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        std::fs::write(&path, b"not a sqlite database").unwrap();

        let error = HistoryStore::open(&path).err().unwrap();
        let HistoryError::CorruptQuarantined { quarantined, .. } = error else {
            panic!("expected quarantine, got {error:?}");
        };
        assert!(!path.exists());
        assert_eq!(
            std::fs::read(quarantined).unwrap(),
            b"not a sqlite database"
        );
        let fresh = HistoryStore::open(&path).unwrap();
        assert_eq!(fresh.count().unwrap(), 0);
    }

    #[test]
    fn legacy_raw_transcript_schema_is_quarantined_not_migrated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE pipeline_history (
                    id TEXT PRIMARY KEY,
                    timestamp REAL NOT NULL,
                    raw_transcript TEXT
                );
                INSERT INTO pipeline_history VALUES ('legacy', 1, 'do not import');",
            )
            .unwrap();
        }

        let error = HistoryStore::open(&path).err().unwrap();
        let HistoryError::CorruptQuarantined { quarantined, .. } = error else {
            panic!("expected legacy schema quarantine, got {error:?}");
        };
        let legacy = Connection::open(quarantined).unwrap();
        let raw: String = legacy
            .query_row("SELECT raw_transcript FROM pipeline_history", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(raw, "do not import");
        assert!(!path.exists());
    }

    #[test]
    fn concurrent_connections_commit_complete_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = std::sync::Arc::new(dir.path().join("history.sqlite"));
        drop(HistoryStore::open(&path).unwrap());
        let writers: Vec<_> = (0..12)
            .map(|index| {
                let path = path.clone();
                std::thread::spawn(move || {
                    let mut store = HistoryStore::open(&path).unwrap();
                    store
                        .insert(&make_entry(&format!("row-{index}"), index as f64))
                        .unwrap();
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap();
        }

        let store = HistoryStore::open(&path).unwrap();
        assert_eq!(store.count().unwrap(), 12);
        store.integrity_check().unwrap();
    }

    #[test]
    fn storage_error_is_surfaced() {
        let dir = tempfile::tempdir().unwrap();
        let not_a_directory = dir.path().join("file");
        std::fs::write(&not_a_directory, b"occupied").unwrap();
        let error = HistoryStore::open(&not_a_directory.join("history.sqlite"))
            .err()
            .unwrap();
        assert!(matches!(error, HistoryError::Io(_)));
    }
}

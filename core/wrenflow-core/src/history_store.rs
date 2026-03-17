//! Pipeline history — SQLite storage for run history.
//! Replaces Swift CoreData PipelineHistoryStore with rusqlite.

use wrenflow_domain::history::HistoryEntry;
use rusqlite::{params, Connection, Result as SqlResult};
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum HistoryError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

pub struct HistoryStore {
    conn: Connection,
}

impl HistoryStore {
    pub fn open(db_path: &Path) -> Result<Self, HistoryError> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(db_path)?;
        let store = Self { conn };
        store.create_table()?;
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, HistoryError> {
        let conn = Connection::open_in_memory()?;
        let store = Self { conn };
        store.create_table()?;
        Ok(store)
    }

    fn create_table(&self) -> Result<(), HistoryError> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS pipeline_history (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                raw_transcript TEXT NOT NULL DEFAULT '',
                post_processed_transcript TEXT NOT NULL DEFAULT '',
                post_processing_prompt TEXT,
                post_processing_reasoning TEXT,
                context_summary TEXT NOT NULL DEFAULT '',
                context_prompt TEXT,
                context_screenshot_data_url TEXT,
                context_screenshot_status TEXT NOT NULL DEFAULT '',
                post_processing_status TEXT NOT NULL DEFAULT '',
                debug_status TEXT NOT NULL DEFAULT '',
                custom_vocabulary TEXT NOT NULL DEFAULT '',
                audio_file_name TEXT,
                metrics_json TEXT NOT NULL DEFAULT '{}'
            )"
        )?;
        Ok(())
    }

    pub fn insert(&self, entry: &HistoryEntry) -> Result<(), HistoryError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO pipeline_history
             (id, timestamp, raw_transcript, post_processed_transcript,
              post_processing_prompt, post_processing_reasoning,
              context_summary, context_prompt, context_screenshot_data_url,
              context_screenshot_status, post_processing_status, debug_status,
              custom_vocabulary, audio_file_name, metrics_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            params![
                entry.id, entry.timestamp, entry.raw_transcript,
                entry.post_processed_transcript, entry.post_processing_prompt,
                entry.post_processing_reasoning, entry.context_summary,
                entry.context_prompt, entry.context_screenshot_data_url,
                entry.context_screenshot_status, entry.post_processing_status,
                entry.debug_status, entry.custom_vocabulary,
                entry.audio_file_name, entry.metrics_json,
            ],
        )?;
        Ok(())
    }

    pub fn load_all(&self) -> Result<Vec<HistoryEntry>, HistoryError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, timestamp, raw_transcript, post_processed_transcript,
                    post_processing_prompt, post_processing_reasoning,
                    context_summary, context_prompt, context_screenshot_data_url,
                    context_screenshot_status, post_processing_status, debug_status,
                    custom_vocabulary, audio_file_name, metrics_json
             FROM pipeline_history ORDER BY timestamp DESC"
        )?;
        let entries = stmt.query_map([], |row| {
            Ok(HistoryEntry {
                id: row.get(0)?,
                timestamp: row.get(1)?,
                raw_transcript: row.get(2)?,
                post_processed_transcript: row.get(3)?,
                post_processing_prompt: row.get(4)?,
                post_processing_reasoning: row.get(5)?,
                context_summary: row.get(6)?,
                context_prompt: row.get(7)?,
                context_screenshot_data_url: row.get(8)?,
                context_screenshot_status: row.get(9)?,
                post_processing_status: row.get(10)?,
                debug_status: row.get(11)?,
                custom_vocabulary: row.get(12)?,
                audio_file_name: row.get(13)?,
                metrics_json: row.get(14)?,
            })
        })?.collect::<SqlResult<Vec<_>>>()?;
        Ok(entries)
    }

    pub fn trim(&self, max_count: usize) -> Result<Vec<String>, HistoryError> {
        let mut stmt = self.conn.prepare(
            "SELECT audio_file_name FROM pipeline_history
             ORDER BY timestamp DESC LIMIT -1 OFFSET ?1"
        )?;
        let removed_files: Vec<String> = stmt.query_map(params![max_count], |row| {
            row.get::<_, Option<String>>(0)
        })?.filter_map(|r| r.ok().flatten()).collect();

        self.conn.execute(
            "DELETE FROM pipeline_history WHERE id NOT IN
             (SELECT id FROM pipeline_history ORDER BY timestamp DESC LIMIT ?1)",
            params![max_count],
        )?;
        Ok(removed_files)
    }

    pub fn delete(&self, id: &str) -> Result<Option<String>, HistoryError> {
        let audio: Option<String> = self.conn.query_row(
            "SELECT audio_file_name FROM pipeline_history WHERE id = ?1",
            params![id],
            |row| row.get(0),
        ).ok().flatten();
        self.conn.execute("DELETE FROM pipeline_history WHERE id = ?1", params![id])?;
        Ok(audio)
    }

    pub fn clear_all(&self) -> Result<Vec<String>, HistoryError> {
        let mut stmt = self.conn.prepare("SELECT audio_file_name FROM pipeline_history")?;
        let files: Vec<String> = stmt.query_map([], |row| {
            row.get::<_, Option<String>>(0)
        })?.filter_map(|r| r.ok().flatten()).collect();
        self.conn.execute("DELETE FROM pipeline_history", [])?;
        Ok(files)
    }

    pub fn count(&self) -> Result<usize, HistoryError> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM pipeline_history", [], |row| row.get(0)
        )?;
        Ok(count as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(id: &str, ts: f64) -> HistoryEntry {
        HistoryEntry {
            id: id.to_string(),
            timestamp: ts,
            raw_transcript: "hello".to_string(),
            post_processed_transcript: "Hello.".to_string(),
            post_processing_prompt: None,
            post_processing_reasoning: None,
            context_summary: "test".to_string(),
            context_prompt: None,
            context_screenshot_data_url: None,
            context_screenshot_status: "none".to_string(),
            post_processing_status: "skipped".to_string(),
            debug_status: "done".to_string(),
            custom_vocabulary: String::new(),
            audio_file_name: Some(format!("{id}.wav")),
            metrics_json: "{}".to_string(),
        }
    }

    #[test]
    fn insert_and_load() {
        let store = HistoryStore::open_in_memory().unwrap();
        store.insert(&make_entry("a", 1000.0)).unwrap();
        store.insert(&make_entry("b", 2000.0)).unwrap();
        let entries = store.load_all().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].id, "b"); // newest first
    }

    #[test]
    fn trim_keeps_newest() {
        let store = HistoryStore::open_in_memory().unwrap();
        for i in 0..5 {
            store.insert(&make_entry(&format!("e{i}"), i as f64 * 1000.0)).unwrap();
        }
        let removed = store.trim(3).unwrap();
        assert_eq!(removed.len(), 2);
        assert_eq!(store.count().unwrap(), 3);
    }

    #[test]
    fn delete_returns_audio_file() {
        let store = HistoryStore::open_in_memory().unwrap();
        store.insert(&make_entry("x", 1000.0)).unwrap();
        let audio = store.delete("x").unwrap();
        assert_eq!(audio, Some("x.wav".to_string()));
        assert_eq!(store.count().unwrap(), 0);
    }

    #[test]
    fn clear_all_returns_files() {
        let store = HistoryStore::open_in_memory().unwrap();
        store.insert(&make_entry("a", 1000.0)).unwrap();
        store.insert(&make_entry("b", 2000.0)).unwrap();
        let files = store.clear_all().unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(store.count().unwrap(), 0);
    }
}

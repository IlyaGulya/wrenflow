//! Pipeline history — domain types only.

use crate::metrics::PipelineMetrics;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: String,
    pub timestamp: f64,
    pub transcript: String,
    pub custom_vocabulary: String,
    pub audio_file_name: Option<String>,
    pub metrics_json: String,
}

impl HistoryEntry {
    pub fn metrics(&self) -> PipelineMetrics {
        PipelineMetrics::from_json(&self.metrics_json)
    }
}

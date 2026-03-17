//! Pipeline history — domain types only.

use crate::metrics::PipelineMetrics;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: String,
    pub timestamp: f64,
    pub raw_transcript: String,
    pub post_processed_transcript: String,
    pub post_processing_prompt: Option<String>,
    pub post_processing_reasoning: Option<String>,
    pub context_summary: String,
    pub context_prompt: Option<String>,
    pub context_screenshot_data_url: Option<String>,
    pub context_screenshot_status: String,
    pub post_processing_status: String,
    pub debug_status: String,
    pub custom_vocabulary: String,
    pub audio_file_name: Option<String>,
    pub metrics_json: String,
}

impl HistoryEntry {
    pub fn metrics(&self) -> PipelineMetrics {
        PipelineMetrics::from_json(&self.metrics_json)
    }
}

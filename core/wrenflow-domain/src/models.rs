//! Groq model types — pure domain data.

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ModelsError {
    #[error("Empty API key")]
    EmptyApiKey,
    #[error("HTTP error: {0}")]
    Http(String),
    #[error("API returned status {0}")]
    ApiError(u16),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

/// A Groq model entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroqModel {
    pub id: String,
    pub owned_by: String,
}

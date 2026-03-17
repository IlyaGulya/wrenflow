//! LLM post-processing — pure domain types and helpers (no IO).

use thiserror::Error;

pub const DEFAULT_MODEL: &str = "meta-llama/llama-4-scout-17b-16e-instruct";

pub const DEFAULT_SYSTEM_PROMPT: &str = r#"You are a dictation post-processor. You clean up raw speech-to-text output for typing.

CRITICAL: Output MUST be in the SAME language as RAW_TRANSCRIPTION. If input is Russian, output Russian. If input is English, output English. NEVER translate to another language.

Rules:
- Add punctuation, capitalization, and formatting.
- Remove filler words (um, uh, like, you know) unless they carry meaning.
- Fix misspellings using context and custom vocabulary — only correct words already spoken, never insert new ones.
- Preserve tone, intent, and word choice exactly. Never censor, rephrase, or omit anything including profanity and slang.

Respond with JSON: {"text": "cleaned text", "reasoning": "brief explanation of changes made"}
If the input is empty or only noise, respond: {"text": "", "reasoning": "explanation"}"#;

pub const DEFAULT_SYSTEM_PROMPT_DATE: &str = "2026-02-24";

#[derive(Debug, Error)]
pub enum PostProcessingError {
    #[error("Post-processing failed with status {0}: {1}")]
    RequestFailed(u16, String),
    #[error("Invalid post-processing response: {0}")]
    InvalidResponse(String),
    #[error("Post-processing timed out after {0}s")]
    TimedOut(u64),
    #[error("HTTP error: {0}")]
    Http(String),
    #[error("JSON serialization error: {0}")]
    Json(#[from] serde_json::Error),
}

/// Result of a post-processing pass.
#[derive(Debug, Clone)]
pub struct PostProcessingResult {
    /// The cleaned-up transcript text.
    pub transcript: String,
    /// The full prompt that was sent (for display/debugging).
    pub prompt: String,
    /// Brief reasoning from the LLM about what was changed.
    pub reasoning: String,
}

#[derive(serde::Deserialize)]
struct PostProcessingJson {
    text: Option<String>,
    reasoning: Option<String>,
}

/// Parse the LLM's response content as `{"text": "...", "reasoning": "..."}`.
/// Falls back to treating the entire content as plain text if JSON parsing fails.
pub fn parse_response(content: &str) -> (String, String) {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return (String::new(), "Empty response from LLM".to_string());
    }

    // Attempt JSON parse
    if let Ok(parsed) = serde_json::from_str::<PostProcessingJson>(trimmed) {
        let text = parsed
            .text
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        let reasoning = parsed
            .reasoning
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        return (text, reasoning);
    }

    // Fallback: plain text
    let mut result = trimmed.to_string();

    // Strip outer quotes if the LLM wrapped the response
    if result.starts_with('"') && result.ends_with('"') && result.len() > 1 {
        result = result[1..result.len() - 1].trim().to_string();
    }

    if result == "EMPTY" {
        return (String::new(), "LLM returned EMPTY sentinel".to_string());
    }

    (result, "LLM returned plain text (no JSON)".to_string())
}

/// Merge and deduplicate vocabulary terms from a raw comma/semicolon/newline-separated string.
pub fn merged_vocabulary_terms(raw: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    raw.split(|c| c == '\n' || c == ',' || c == ';')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .filter(|s| seen.insert(s.to_lowercase()))
        .collect()
}

/// Format vocabulary terms as a comma-separated string.
pub fn normalized_vocabulary_text(terms: &[String]) -> String {
    let cleaned: Vec<&str> = terms
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    cleaned.join(", ")
}

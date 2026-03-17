//! Groq Whisper API client

use reqwest::Client;
use serde::Deserialize;
use thiserror::Error;
use std::path::Path;
use std::time::Duration;

use crate::http_client::GROQ_BASE_URL;

const TRANSCRIPTION_MODEL: &str = "whisper-large-v3-turbo";
const TRANSCRIPTION_TIMEOUT_SECS: u64 = 20;

#[derive(Debug, Error)]
pub enum CloudTranscriptionError {
    #[error("Upload failed: {0}")]
    UploadFailed(String),
    #[error("Submission failed: {0}")]
    SubmissionFailed(String),
    #[error("Transcription failed: {0}")]
    TranscriptionFailed(String),
    #[error("Transcription timed out after {0}s")]
    TimedOut(u64),
    #[error("Poll failed: {0}")]
    PollFailed(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Deserialize)]
struct TranscriptionResponse {
    text: Option<String>,
}

/// Determine the MIME type for the audio file based on its extension.
fn audio_content_type(file_name: &str) -> &'static str {
    let lower = file_name.to_lowercase();
    if lower.ends_with(".wav") {
        "audio/wav"
    } else if lower.ends_with(".mp3") {
        "audio/mpeg"
    } else if lower.ends_with(".m4a") {
        "audio/mp4"
    } else {
        "audio/mp4"
    }
}

/// Transcribe an audio file using the Groq Whisper API.
///
/// Sends a multipart POST to `/audio/transcriptions` and returns the transcript text.
pub async fn transcribe(
    client: &Client,
    api_key: &str,
    file_path: &Path,
    base_url: &str,
) -> Result<String, CloudTranscriptionError> {
    let url = format!("{}/audio/transcriptions", base_url);

    let file_name = file_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("audio.m4a")
        .to_owned();

    let audio_bytes = tokio::fs::read(file_path).await?;
    let mime = audio_content_type(&file_name);

    let file_part = reqwest::multipart::Part::bytes(audio_bytes)
        .file_name(file_name)
        .mime_str(mime)
        .map_err(|e| CloudTranscriptionError::SubmissionFailed(e.to_string()))?;

    let form = reqwest::multipart::Form::new()
        .text("model", TRANSCRIPTION_MODEL)
        .part("file", file_part);

    let response = tokio::time::timeout(
        Duration::from_secs(TRANSCRIPTION_TIMEOUT_SECS),
        client
            .post(&url)
            .header("Authorization", format!("Bearer {}", api_key))
            .multipart(form)
            .send(),
    )
    .await
    .map_err(|_| CloudTranscriptionError::TimedOut(TRANSCRIPTION_TIMEOUT_SECS))?
    .map_err(CloudTranscriptionError::Http)?;

    let status = response.status().as_u16();
    if status != 200 {
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| String::from("<unreadable>"));
        return Err(CloudTranscriptionError::SubmissionFailed(format!(
            "Status {}: {}",
            status, body
        )));
    }

    let body_text = response.text().await?;

    // Try JSON parse first: {"text": "..."}
    if let Ok(parsed) = serde_json::from_str::<TranscriptionResponse>(&body_text) {
        if let Some(text) = parsed.text {
            return Ok(text);
        }
    }

    // Fallback: treat entire response as plain text (join lines)
    let plain = body_text
        .lines()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_owned();

    if plain.is_empty() {
        return Err(CloudTranscriptionError::PollFailed(
            "Invalid response".to_string(),
        ));
    }

    Ok(plain)
}

/// Convenience wrapper that uses the default Groq base URL.
pub async fn transcribe_groq(
    client: &Client,
    api_key: &str,
    file_path: &Path,
) -> Result<String, CloudTranscriptionError> {
    transcribe(client, api_key, file_path, GROQ_BASE_URL).await
}

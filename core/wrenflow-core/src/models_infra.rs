//! Fetch available models from the Groq API — infrastructure (IO).

use reqwest::Client;
use serde::Deserialize;

use wrenflow_domain::models::{GroqModel, ModelsError};
use crate::http_client::GROQ_BASE_URL;

#[derive(Deserialize)]
struct ModelsResponse {
    data: Vec<RawGroqModel>,
}

#[derive(Deserialize)]
struct RawGroqModel {
    id: String,
    owned_by: String,
}

/// Fetch available chat/text models from the Groq API.
///
/// Excludes whisper, distil-whisper, playai, tts, and known vision-only models --
/// mirroring the filtering in `GroqModelsService.swift`.
pub async fn fetch_models(
    client: &Client,
    api_key: &str,
    base_url: &str,
) -> Result<Vec<GroqModel>, ModelsError> {
    let trimmed = api_key.trim();
    if trimmed.is_empty() {
        return Err(ModelsError::EmptyApiKey);
    }

    let url = format!("{}/models", base_url);

    let response = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", trimmed))
        .send()
        .await
        .map_err(|e| ModelsError::Http(e.to_string()))?;

    let status = response.status().as_u16();
    if status != 200 {
        return Err(ModelsError::ApiError(status));
    }

    let body: ModelsResponse = response.json().await
        .map_err(|e| ModelsError::Http(e.to_string()))?;

    let excluded_prefixes = ["whisper", "distil-whisper", "playai", "tts"];
    let excluded_ids: std::collections::HashSet<&str> = [
        "llama-3.2-11b-vision-preview",
        "llama-3.2-90b-vision-preview",
    ]
    .iter()
    .copied()
    .collect();

    let mut models: Vec<GroqModel> = body
        .data
        .into_iter()
        .filter(|m| {
            let lower = m.id.to_lowercase();
            let has_excluded_prefix = excluded_prefixes
                .iter()
                .any(|prefix| lower.starts_with(prefix));
            let is_excluded_id = excluded_ids.contains(m.id.as_str());
            !has_excluded_prefix && !is_excluded_id
        })
        .map(|m| GroqModel {
            id: m.id,
            owned_by: m.owned_by,
        })
        .collect();

    models.sort_by(|a, b| a.id.cmp(&b.id));

    Ok(models)
}

/// Convenience wrapper using the default Groq base URL.
pub async fn fetch_groq_models(
    client: &Client,
    api_key: &str,
) -> Result<Vec<GroqModel>, ModelsError> {
    fetch_models(client, api_key, GROQ_BASE_URL).await
}

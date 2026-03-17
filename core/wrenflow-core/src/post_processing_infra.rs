//! LLM post-processing — infrastructure (HTTP calls).

use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;

use wrenflow_domain::post_processing::{
    PostProcessingError, PostProcessingResult,
    DEFAULT_MODEL, DEFAULT_SYSTEM_PROMPT,
    parse_response, merged_vocabulary_terms, normalized_vocabulary_text,
};
use crate::http_client::GROQ_BASE_URL;

const POST_PROCESSING_TIMEOUT_SECS: u64 = 20;

#[derive(Serialize)]
struct Message {
    role: String,
    content: String,
}

#[derive(Serialize)]
struct ResponseFormat {
    r#type: String,
}

#[derive(Serialize)]
struct ChatCompletionRequest {
    model: String,
    temperature: f64,
    response_format: ResponseFormat,
    messages: Vec<Message>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatMessage,
}

#[derive(Deserialize)]
struct ChatMessage {
    content: String,
}

#[derive(Deserialize)]
struct ChatCompletionResponse {
    choices: Vec<ChatChoice>,
}

/// Run LLM post-processing on a transcript.
///
/// # Parameters
/// - `client` -- shared reqwest Client
/// - `api_key` -- Groq API key
/// - `transcript` -- raw speech-to-text output
/// - `context_summary` -- brief description of the current screen/context
/// - `model` -- LLM model identifier (defaults to `DEFAULT_MODEL`)
/// - `custom_vocabulary` -- raw vocabulary hint string (newline/comma/semicolon separated)
/// - `custom_system_prompt` -- override the default system prompt (empty = use default)
/// - `base_url` -- API base URL
pub async fn post_process(
    client: &Client,
    api_key: &str,
    transcript: &str,
    context_summary: &str,
    model: &str,
    custom_vocabulary: &str,
    custom_system_prompt: &str,
    base_url: &str,
) -> Result<PostProcessingResult, PostProcessingError> {
    let url = format!("{}/chat/completions", base_url);

    let vocabulary_terms = merged_vocabulary_terms(custom_vocabulary);
    let normalized_vocab = normalized_vocabulary_text(&vocabulary_terms);

    let vocabulary_prompt = if !normalized_vocab.is_empty() {
        format!(
            "The following vocabulary must be treated as high-priority terms while rewriting.\n\
             Use these spellings exactly in the output when relevant:\n{}",
            normalized_vocab
        )
    } else {
        String::new()
    };

    let mut system_prompt = if custom_system_prompt.trim().is_empty() {
        DEFAULT_SYSTEM_PROMPT.to_string()
    } else {
        custom_system_prompt.trim().to_string()
    };

    if !vocabulary_prompt.is_empty() {
        system_prompt.push_str("\n\n");
        system_prompt.push_str(&vocabulary_prompt);
    }

    let user_message = format!(
        "CONTEXT: {}\n\nRAW_TRANSCRIPTION: {}",
        context_summary, transcript
    );

    let prompt_for_display = format!(
        "Model: {}\n\n[System]\n{}\n\n[User]\n{}",
        model, system_prompt, user_message
    );

    let payload = ChatCompletionRequest {
        model: model.to_string(),
        temperature: 0.0,
        response_format: ResponseFormat {
            r#type: "json_object".to_string(),
        },
        messages: vec![
            Message {
                role: "system".to_string(),
                content: system_prompt,
            },
            Message {
                role: "user".to_string(),
                content: user_message,
            },
        ],
    };

    let response = tokio::time::timeout(
        Duration::from_secs(POST_PROCESSING_TIMEOUT_SECS),
        client
            .post(&url)
            .header("Authorization", format!("Bearer {}", api_key))
            .header("Content-Type", "application/json")
            .json(&payload)
            .send(),
    )
    .await
    .map_err(|_| PostProcessingError::TimedOut(POST_PROCESSING_TIMEOUT_SECS))?
    .map_err(|e| PostProcessingError::Http(e.to_string()))?;

    let status = response.status().as_u16();
    if status != 200 {
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "<unreadable>".to_string());
        return Err(PostProcessingError::RequestFailed(status, body));
    }

    let completion: ChatCompletionResponse = response.json().await
        .map_err(|e| PostProcessingError::Http(e.to_string()))?;

    let content = completion
        .choices
        .into_iter()
        .next()
        .map(|c| c.message.content)
        .ok_or_else(|| {
            PostProcessingError::InvalidResponse(
                "Missing choices[0].message.content".to_string(),
            )
        })?;

    let (cleaned_text, reasoning) = parse_response(&content);

    Ok(PostProcessingResult {
        transcript: cleaned_text,
        prompt: prompt_for_display,
        reasoning,
    })
}

/// Convenience wrapper using the default Groq base URL and default model.
pub async fn post_process_groq(
    client: &Client,
    api_key: &str,
    transcript: &str,
    context_summary: &str,
    custom_vocabulary: &str,
    custom_system_prompt: &str,
) -> Result<PostProcessingResult, PostProcessingError> {
    post_process(
        client,
        api_key,
        transcript,
        context_summary,
        DEFAULT_MODEL,
        custom_vocabulary,
        custom_system_prompt,
        GROQ_BASE_URL,
    )
    .await
}

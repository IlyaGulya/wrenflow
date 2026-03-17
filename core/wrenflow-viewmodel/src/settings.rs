//! Settings ViewModel — UI state + commands for the settings screens.
//!
//! Each native UI (SwiftUI, Compose, egui) binds to this ViewModel.
//! The ViewModel owns ephemeral UI state (validation flags, model lists, etc.)
//! and delegates to wrenflow-core for business logic.

use std::sync::Arc;
use wrenflow_core::config::AppConfig;
use wrenflow_core::config_store::{ConfigStore, default_config_path};
use wrenflow_core::history::HistoryEntry;
use wrenflow_core::history_store::HistoryStore;
use wrenflow_core::http_client;
use wrenflow_core::models::GroqModel;
use wrenflow_core::models_infra;
use wrenflow_core::platform::PlatformHost;
use wrenflow_core::post_processing;
use wrenflow_core::post_processing_infra;

// ---------------------------------------------------------------------------
// Settings ViewModel
// ---------------------------------------------------------------------------

pub struct SettingsViewModel {
    /// Persisted config (loaded from disk).
    pub config: AppConfig,
    config_path: std::path::PathBuf,

    /// Platform host for native operations.
    pub host: Arc<dyn PlatformHost>,

    // -- API Key validation --
    pub api_key: String,
    pub api_key_validating: bool,
    pub api_key_error: Option<String>,
    pub api_key_valid: bool,

    // -- Model fetching --
    pub models: Vec<GroqModel>,
    pub models_fetching: bool,
    pub models_error: bool,

    // -- History --
    pub history: Vec<HistoryEntry>,
    history_db_path: std::path::PathBuf,

    // -- Prompt test --
    pub system_test_running: bool,
    pub system_test_output: Option<String>,
    pub system_test_error: Option<String>,
    pub system_test_prompt: Option<String>,

    pub context_test_running: bool,
    pub context_test_output: Option<String>,
    pub context_test_error: Option<String>,
}

impl SettingsViewModel {
    pub fn new(
        app_name: &str,
        host: Arc<dyn PlatformHost>,
    ) -> Self {
        let config_path = default_config_path(app_name);
        let config_store = ConfigStore::new(config_path.clone());
        let config = config_store.load_or_default();
        let history_db_path = config_path
            .parent()
            .unwrap()
            .join("PipelineHistory.sqlite");

        let mut vm = Self {
            config,
            config_path,
            host,
            api_key: String::new(),
            api_key_validating: false,
            api_key_error: None,
            api_key_valid: false,
            models: Vec::new(),
            models_fetching: false,
            models_error: false,
            history: Vec::new(),
            history_db_path,
            system_test_running: false,
            system_test_output: None,
            system_test_error: None,
            system_test_prompt: None,
            context_test_running: false,
            context_test_output: None,
            context_test_error: None,
        };
        vm.load_history();
        vm
    }

    // -- Config persistence --

    pub fn save_config(&self) {
        let store = ConfigStore::new(self.config_path.clone());
        let _ = store.save(&self.config);
    }

    // -- API Key --

    /// Validate an API key. Returns true if valid.
    /// Caller is responsible for running this async.
    pub async fn validate_api_key(key: &str, base_url: &str) -> Result<bool, String> {
        let base_url = if base_url.trim().is_empty() {
            http_client::GROQ_BASE_URL
        } else {
            base_url.trim()
        };
        let client = http_client::build_client().map_err(|e| format!("{e}"))?;
        Ok(http_client::validate_api_key(&client, key.trim(), base_url).await)
    }

    // -- Models --

    /// Fetch available models. Returns the list or error.
    pub async fn fetch_models(api_key: &str, base_url: &str) -> Result<Vec<GroqModel>, String> {
        let base_url = if base_url.trim().is_empty() {
            http_client::GROQ_BASE_URL
        } else {
            base_url.trim()
        };
        let client = http_client::build_client().map_err(|e| format!("{e}"))?;
        models_infra::fetch_models(&client, api_key.trim(), base_url)
            .await
            .map_err(|e| format!("{e}"))
    }

    // -- History --

    pub fn load_history(&mut self) {
        if let Ok(store) = HistoryStore::open(&self.history_db_path) {
            self.history = store.load_all().unwrap_or_default();
        }
    }

    pub fn clear_history(&mut self) {
        if let Ok(store) = HistoryStore::open(&self.history_db_path) {
            let _ = store.clear_all();
        }
        self.history.clear();
    }

    pub fn delete_history_entry(&mut self, id: &str) {
        if let Ok(store) = HistoryStore::open(&self.history_db_path) {
            let _ = store.delete(id);
        }
        self.history.retain(|e| e.id != id);
    }

    // -- Prompt test --

    /// Run a system prompt test. Returns (output, prompt_text) or error.
    pub async fn test_system_prompt(
        api_key: &str,
        base_url: &str,
        model: &str,
        custom_prompt: &str,
        vocabulary: &str,
        test_input: &str,
    ) -> Result<(String, String), String> {
        let base_url = if base_url.trim().is_empty() {
            http_client::GROQ_BASE_URL
        } else {
            base_url.trim()
        };
        let client = http_client::build_client().map_err(|e| format!("{e}"))?;
        let result = post_processing_infra::post_process(
            &client,
            api_key.trim(),
            test_input,
            "User is testing the system prompt in settings.",
            model,
            vocabulary,
            custom_prompt,
            base_url,
        )
        .await
        .map_err(|e| format!("{e}"))?;
        Ok((result.transcript, result.prompt))
    }

    // -- Default prompts --

    pub fn default_system_prompt() -> &'static str {
        post_processing::DEFAULT_SYSTEM_PROMPT
    }

    pub fn default_system_prompt_date() -> &'static str {
        post_processing::DEFAULT_SYSTEM_PROMPT_DATE
    }
}

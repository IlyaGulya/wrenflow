//! Setup Wizard ViewModel — state machine for the onboarding flow.

use std::sync::Arc;
use wrenflow_core::config::AppConfig;
use wrenflow_core::config_store::{ConfigStore, default_config_path};
use wrenflow_core::http_client;
use wrenflow_core::platform::{
    OsPermissionStatus, PlatformCapabilities, PlatformHost, PermissionKind,
};

// ---------------------------------------------------------------------------
// Step definitions
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WizardStep {
    Welcome,
    TranscriptionProvider,
    ApiKey,
    MicrophonePermission,
    Accessibility,
    ScreenRecording,
    Hotkey,
    Vocabulary,
    LaunchAtLogin,
    TestTranscription,
    Ready,
}

impl WizardStep {
    pub fn steps_for(caps: &PlatformCapabilities) -> Vec<WizardStep> {
        let mut s = vec![
            WizardStep::Welcome,
            WizardStep::TranscriptionProvider,
            WizardStep::ApiKey,
            WizardStep::MicrophonePermission,
            WizardStep::Accessibility,
            WizardStep::ScreenRecording,
        ];
        s.push(WizardStep::Hotkey);
        s.push(WizardStep::Vocabulary);
        if caps.launch_at_login {
            s.push(WizardStep::LaunchAtLogin);
        }
        s.push(WizardStep::Ready);
        s
    }

    pub fn skippable(self) -> bool {
        matches!(
            self,
            WizardStep::ApiKey
                | WizardStep::Vocabulary
                | WizardStep::ScreenRecording
                | WizardStep::TestTranscription
        )
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Welcome => "Welcome",
            Self::TranscriptionProvider => "Transcription",
            Self::ApiKey => "API Key",
            Self::MicrophonePermission => "Microphone",
            Self::Accessibility => "Accessibility",
            Self::ScreenRecording => "Screen Recording",
            Self::Hotkey => "Push-to-Talk Key",
            Self::Vocabulary => "Custom Vocabulary",
            Self::LaunchAtLogin => "Launch at Login",
            Self::TestTranscription => "Test",
            Self::Ready => "Ready",
        }
    }

    /// The permission kind this step grants, if any.
    pub fn permission_kind(self) -> Option<PermissionKind> {
        match self {
            Self::MicrophonePermission => Some(PermissionKind::Microphone),
            Self::Accessibility => Some(PermissionKind::Accessibility),
            Self::ScreenRecording => Some(PermissionKind::ScreenRecording),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Wizard ViewModel
// ---------------------------------------------------------------------------

pub struct WizardViewModel {
    pub steps: Vec<WizardStep>,
    pub current_index: usize,
    pub config: AppConfig,
    config_path: std::path::PathBuf,
    pub host: Arc<dyn PlatformHost>,

    // API Key validation
    pub api_key: String,
    pub api_key_validating: bool,
    pub api_key_error: Option<String>,
    pub api_key_valid: bool,
}

impl WizardViewModel {
    pub fn new(app_name: &str, host: Arc<dyn PlatformHost>) -> Self {
        let config_path = default_config_path(app_name);
        let config_store = ConfigStore::new(config_path.clone());
        let config = config_store.load_or_default();
        let caps = host.capabilities();
        let steps = WizardStep::steps_for(&caps);
        Self {
            steps,
            current_index: 0,
            config,
            config_path,
            host,
            api_key: String::new(),
            api_key_validating: false,
            api_key_error: None,
            api_key_valid: false,
        }
    }

    pub fn current_step(&self) -> WizardStep {
        self.steps[self.current_index.min(self.steps.len() - 1)]
    }

    pub fn is_last_step(&self) -> bool {
        self.current_index + 1 >= self.steps.len()
    }

    pub fn can_go_back(&self) -> bool {
        self.current_index > 0
    }

    pub fn advance(&mut self) {
        if self.current_index + 1 < self.steps.len() {
            self.current_index += 1;
        }
    }

    pub fn go_back(&mut self) {
        if self.current_index > 0 {
            self.current_index -= 1;
        }
    }

    pub fn complete(&self) {
        let store = ConfigStore::new(self.config_path.clone());
        let _ = store.save(&self.config);
    }

    // -- Permission helpers using the new generic API --

    pub fn get_permission_status(&self, step: WizardStep) -> OsPermissionStatus {
        match step.permission_kind() {
            Some(kind) => self.host.get_permission(kind),
            None => OsPermissionStatus::NotApplicable,
        }
    }

    pub fn request_permission(&self, step: WizardStep) {
        if let Some(kind) = step.permission_kind() {
            self.host.request_permission(kind);
        }
    }

    // -- API Key --

    pub async fn validate_api_key(key: &str, base_url: &str) -> Result<bool, String> {
        let base_url = if base_url.trim().is_empty() {
            http_client::GROQ_BASE_URL
        } else {
            base_url.trim()
        };
        let client = http_client::build_client().map_err(|e| format!("{e}"))?;
        Ok(http_client::validate_api_key(&client, key.trim(), base_url).await)
    }
}

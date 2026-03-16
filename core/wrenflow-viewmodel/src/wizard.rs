//! Setup Wizard ViewModel — state machine for the onboarding flow.
//!
//! The wizard steps are dynamic based on platform capabilities.
//! Each native UI renders these steps in its own way
//! (accordion, paged, etc.) but the state logic is shared.

use std::sync::Arc;
use wrenflow_core::config::AppConfig;
use wrenflow_core::http_client;
use wrenflow_core::platform::{PlatformCapabilities, PlatformHost, PermissionStatus};

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
    /// Build the step list based on platform capabilities.
    pub fn steps_for(caps: &PlatformCapabilities) -> Vec<WizardStep> {
        let mut s = vec![
            WizardStep::Welcome,
            WizardStep::TranscriptionProvider,
            WizardStep::ApiKey,
        ];
        if caps.permissions {
            s.push(WizardStep::MicrophonePermission);
            s.push(WizardStep::Accessibility);
            s.push(WizardStep::ScreenRecording);
        }
        s.push(WizardStep::Hotkey);
        s.push(WizardStep::Vocabulary);
        if caps.launch_at_login {
            s.push(WizardStep::LaunchAtLogin);
        }
        // TestTranscription requires audio + hotkey — only if platform supports it
        // (not included by default; native shell can add it)
        s.push(WizardStep::Ready);
        s
    }

    /// Whether this step can be skipped.
    pub fn skippable(self) -> bool {
        matches!(
            self,
            WizardStep::ApiKey
                | WizardStep::Vocabulary
                | WizardStep::LaunchAtLogin
                | WizardStep::ScreenRecording
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

    // -- API Key validation state --
    pub api_key: String,
    pub api_key_validating: bool,
    pub api_key_error: Option<String>,
    pub api_key_valid: bool,
}

impl WizardViewModel {
    pub fn new(app_name: &str, host: Arc<dyn PlatformHost>) -> Self {
        let config_path = AppConfig::default_path(app_name);
        let config = AppConfig::load_or_default(&config_path);
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

    pub fn go_to(&mut self, index: usize) {
        if index < self.steps.len() {
            self.current_index = index;
        }
    }

    pub fn complete(&self) {
        let _ = self.config.save(&self.config_path);
    }

    // -- Permission helpers --

    pub fn get_permission_status(&self, step: WizardStep) -> PermissionStatus {
        match step {
            WizardStep::MicrophonePermission => self.host.get_microphone_permission(),
            WizardStep::Accessibility => self.host.get_accessibility_permission(),
            WizardStep::ScreenRecording => self.host.get_screen_recording_permission(),
            _ => PermissionStatus::NotApplicable,
        }
    }

    pub fn request_permission(&self, step: WizardStep) {
        match step {
            WizardStep::MicrophonePermission => self.host.request_microphone_permission(),
            WizardStep::Accessibility => self.host.request_accessibility_permission(),
            WizardStep::ScreenRecording => self.host.request_screen_recording_permission(),
            _ => {}
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

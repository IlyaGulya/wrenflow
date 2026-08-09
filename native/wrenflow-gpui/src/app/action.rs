use std::time::Duration;

use wrenflow_runtime::{RuntimeCommand, SettingsPatch, TranscriptDisposition};

use super::{CommandKey, NavigationTarget};

#[derive(Clone, Debug, PartialEq)]
pub enum AppAction {
    Navigate(NavigationTarget),
    SelectLocalModel(String),
    ActivateSelectedModel,
    CancelModelOperation,
    SetSelectedHotkey(String),
    SetSelectedMicrophone(String),
    SetSoundEnabled(bool),
    SetCustomVocabulary(String),
    SetMinimumRecordingDurationMs(f64),
    SetHasCompletedSetup(bool),
    AdvanceOnboarding,
    RetreatOnboarding,
    DeleteHistoryEntry(String),
    ClearHistory,
    OpenHistoryEntry(String),
    CloseHistoryEntry,
    ReloadAudioDevices,
    SetTranscriptDisposition(TranscriptDisposition),
    HotkeyPressed,
    HotkeyReleased(Duration),
    RequestQuit,
    RequestMicrophonePermission,
    RequestAccessibilityPermission,
    OpenMicrophoneSettings,
    OpenAccessibilitySettings,
    SetLaunchAtLogin(bool),
    CheckForUpdates,
    OpenAvailableUpdate,
    ClearNotice,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppActionError {
    InvalidMinimumRecordingDuration,
    InvalidHotkey,
}

impl std::fmt::Display for AppActionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidMinimumRecordingDuration => formatter
                .write_str("minimum recording duration must be a finite non-negative number"),
            Self::InvalidHotkey => formatter
                .write_str("hotkey must be a numeric macOS keycode or a supported legacy preset"),
        }
    }
}

impl std::error::Error for AppActionError {}

impl AppAction {
    pub(crate) fn runtime_command(
        &self,
    ) -> Result<Option<(CommandKey, RuntimeCommand)>, AppActionError> {
        let command = match self {
            Self::Navigate(_)
            | Self::OpenHistoryEntry(_)
            | Self::CloseHistoryEntry
            | Self::RequestMicrophonePermission
            | Self::RequestAccessibilityPermission
            | Self::OpenMicrophoneSettings
            | Self::OpenAccessibilitySettings
            | Self::SetLaunchAtLogin(_)
            | Self::CheckForUpdates
            | Self::OpenAvailableUpdate
            | Self::ClearNotice => return Ok(None),
            Self::SelectLocalModel(model_id) => (
                CommandKey::Settings,
                RuntimeCommand::UpdateSettings(SettingsPatch::SelectedLocalModelId(
                    model_id.clone(),
                )),
            ),
            Self::ActivateSelectedModel => {
                (CommandKey::Models, RuntimeCommand::ActivateSelectedModel)
            }
            Self::CancelModelOperation => {
                (CommandKey::Models, RuntimeCommand::CancelModelOperation)
            }
            Self::SetSelectedHotkey(hotkey) => {
                let hotkey = hotkey.trim();
                let supported_legacy = matches!(hotkey, "fn" | "fnKey" | "rightOption" | "f5");
                if !supported_legacy && hotkey.parse::<u16>().is_err() {
                    return Err(AppActionError::InvalidHotkey);
                }
                (
                    CommandKey::Settings,
                    RuntimeCommand::UpdateSettings(SettingsPatch::SelectedHotkey(
                        hotkey.to_string(),
                    )),
                )
            }
            Self::SetSelectedMicrophone(microphone_id) => (
                CommandKey::Settings,
                RuntimeCommand::UpdateSettings(SettingsPatch::SelectedMicrophoneId(
                    microphone_id.clone(),
                )),
            ),
            Self::SetSoundEnabled(enabled) => (
                CommandKey::Settings,
                RuntimeCommand::UpdateSettings(SettingsPatch::SoundEnabled(*enabled)),
            ),
            Self::SetCustomVocabulary(vocabulary) => (
                CommandKey::Settings,
                RuntimeCommand::UpdateSettings(SettingsPatch::CustomVocabulary(vocabulary.clone())),
            ),
            Self::SetMinimumRecordingDurationMs(milliseconds) => {
                if !milliseconds.is_finite() || *milliseconds < 0.0 {
                    return Err(AppActionError::InvalidMinimumRecordingDuration);
                }
                (
                    CommandKey::Settings,
                    RuntimeCommand::UpdateSettings(SettingsPatch::MinimumRecordingDuration(
                        Duration::from_secs_f64(*milliseconds / 1_000.0),
                    )),
                )
            }
            Self::SetHasCompletedSetup(completed) => (
                CommandKey::Onboarding,
                RuntimeCommand::UpdateSettings(SettingsPatch::HasCompletedSetup(*completed)),
            ),
            Self::AdvanceOnboarding => (CommandKey::Onboarding, RuntimeCommand::AdvanceOnboarding),
            Self::RetreatOnboarding => (CommandKey::Onboarding, RuntimeCommand::RetreatOnboarding),
            Self::DeleteHistoryEntry(id) => (
                CommandKey::History,
                RuntimeCommand::DeleteHistoryEntry { id: id.clone() },
            ),
            Self::ClearHistory => (CommandKey::History, RuntimeCommand::ClearHistory),
            Self::ReloadAudioDevices => {
                (CommandKey::AudioDevices, RuntimeCommand::ReloadAudioDevices)
            }
            Self::SetTranscriptDisposition(disposition) => (
                CommandKey::Pipeline,
                RuntimeCommand::SetTranscriptDisposition(*disposition),
            ),
            Self::HotkeyPressed => (CommandKey::Pipeline, RuntimeCommand::HotkeyPressed),
            Self::HotkeyReleased(duration) => (
                CommandKey::Pipeline,
                RuntimeCommand::HotkeyReleased {
                    duration: *duration,
                },
            ),
            Self::RequestQuit => (CommandKey::Application, RuntimeCommand::RequestQuit),
        };
        Ok(Some(command))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_duration_never_reaches_std_duration_constructor() {
        assert_eq!(
            AppAction::SetMinimumRecordingDurationMs(f64::NAN).runtime_command(),
            Err(AppActionError::InvalidMinimumRecordingDuration)
        );
        assert_eq!(
            AppAction::SetMinimumRecordingDurationMs(-1.0).runtime_command(),
            Err(AppActionError::InvalidMinimumRecordingDuration)
        );
    }

    #[test]
    fn hotkey_edits_cannot_silently_fall_back_to_another_key() {
        assert_eq!(
            AppAction::SetSelectedHotkey("Option+Space".to_string()).runtime_command(),
            Err(AppActionError::InvalidHotkey)
        );
        assert!(AppAction::SetSelectedHotkey("61".to_string())
            .runtime_command()
            .is_ok());
    }
}

use crate::app::{AppAction, CommandStatus, ContentState, NavigationTarget, SettingsPresentation};
use crate::ui::StatusKind;

use super::common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, InputKind, ScreenPlan, SectionPlan, TextPlan,
    TextTone, ToggleKind,
};

const MINIMUM_DURATION_MS: f64 = 100.0;
const MAXIMUM_DURATION_MS: f64 = 1_000.0;
const DURATION_STEP_MS: f64 = 50.0;

pub(super) fn project(settings: &SettingsPresentation) -> ScreenPlan {
    let mut blocks = vec![
        BlockPlan::Card(
            CardPlan::new("settings-hotkey", "Push-to-talk key")
                .line(TextPlan::muted(
                    "Hold the key to record, then release to transcribe and paste.",
                ))
                .control(ControlPlan::Input {
                    kind: InputKind::Hotkey,
                    id: "settings-hotkey-input".to_string(),
                    label: "Push-to-talk key".to_string(),
                    value: settings.selected_hotkey.clone(),
                    hint: settings.hotkey_hint.clone().unwrap_or_else(|| {
                        "Choose a preset or focus Custom key and press any key.".to_string()
                    }),
                    enabled: settings.hotkey_hint.is_none(),
                }),
        ),
        BlockPlan::Card(
            CardPlan::new("settings-sound", "Sound effects")
                .line(TextPlan::muted(
                    "Play feedback when recording starts and stops.",
                ))
                .control(ControlPlan::Toggle {
                    id: "settings-sound-toggle".to_string(),
                    label: "Play sounds".to_string(),
                    checked: settings.sound_enabled,
                    enabled: !matches!(settings.command, CommandStatus::Pending { .. }),
                    kind: ToggleKind::SoundEnabled,
                }),
        ),
        duration_card(settings.minimum_recording_duration_ms),
        BlockPlan::Card(
            CardPlan::new("settings-vocabulary", "Custom vocabulary")
                .line(TextPlan::muted(
                    "Words or phrases to improve recognition, one per line.",
                ))
                .control(ControlPlan::Input {
                    kind: InputKind::Vocabulary,
                    id: "settings-vocabulary-input".to_string(),
                    label: "Custom vocabulary".to_string(),
                    value: settings.custom_vocabulary.clone(),
                    hint: "Wrenflow\nAlmaty".to_string(),
                    enabled: !matches!(settings.command, CommandStatus::Pending { .. }),
                }),
        ),
    ];

    if settings.show_microphone_selection {
        blocks.insert(1, microphone_card(settings));
    }
    if settings.show_launch_at_login {
        blocks.insert(2, launch_at_login_card(settings));
    }

    match &settings.command {
        CommandStatus::Pending { .. } => blocks.push(BlockPlan::Status {
            kind: StatusKind::Loading,
            title: "Saving settings".to_string(),
            detail: Some("Applying the latest preference change.".to_string()),
            action: None,
        }),
        CommandStatus::Failed { message } => blocks.push(BlockPlan::Status {
            kind: StatusKind::Error,
            title: "Could not save settings".to_string(),
            detail: Some(message.clone()),
            action: None,
        }),
        CommandStatus::Idle | CommandStatus::Succeeded { .. } => {}
    }

    let mut plan = ScreenPlan::application(NavigationTarget::Settings, "General");
    plan.subtitle = Some("Recording, input and transcription preferences.".to_string());
    plan.sections = vec![SectionPlan::new("Preferences", blocks)];
    plan
}

fn microphone_card(settings: &SettingsPresentation) -> BlockPlan {
    let mut card = CardPlan::new("settings-microphone", "Microphone").line(TextPlan::muted(
        "Choose an input device. The effective device reflects the current system route.",
    ));
    match &settings.microphones {
        ContentState::Loading => {
            card = card.line(TextPlan::muted("Loading microphones…"));
        }
        ContentState::Empty { title, detail } | ContentState::Error { title, detail } => {
            let mut line = TextPlan::body(format!("{title}: {detail}"));
            if matches!(&settings.microphones, ContentState::Error { .. }) {
                line.tone = TextTone::Danger;
            }
            card = card.line(line);
        }
        ContentState::Ready(microphones) => {
            let actions = microphones
                .iter()
                .map(|microphone| {
                    let suffix = if microphone.effective {
                        " · In use"
                    } else if microphone.selected {
                        " · Selected"
                    } else {
                        ""
                    };
                    ActionPlan::dispatch(
                        format!("select-microphone-{}", microphone.id),
                        format!("{}{suffix}", microphone.name),
                        AppAction::SetSelectedMicrophone(microphone.id.clone()),
                    )
                    .enabled(
                        !microphone.selected
                            && !matches!(
                                &settings.audio_devices_command,
                                CommandStatus::Pending { .. }
                            ),
                    )
                })
                .collect();
            card = card.control(ControlPlan::Actions(actions));
        }
    }
    card = card.control(ControlPlan::Actions(vec![ActionPlan::dispatch(
        "reload-microphones",
        "Reload devices",
        AppAction::ReloadAudioDevices,
    )
    .enabled(!matches!(
        &settings.audio_devices_command,
        CommandStatus::Pending { .. }
    ))]));
    match &settings.audio_devices_command {
        CommandStatus::Pending { .. } => {
            card = card.line(TextPlan::muted("Reloading audio devices…"));
        }
        CommandStatus::Failed { message } => {
            let mut line = TextPlan::body(message.clone());
            line.tone = TextTone::Danger;
            card = card.line(line);
        }
        CommandStatus::Idle | CommandStatus::Succeeded { .. } => {}
    }
    BlockPlan::Card(card)
}

fn launch_at_login_card(settings: &SettingsPresentation) -> BlockPlan {
    let launch = &settings.launch_at_login;
    let mut card = CardPlan::new("settings-launch-at-login", "Launch at login").line(
        TextPlan::muted("Open the Wrenflow menu bar app automatically when you sign in."),
    );
    if let Some(reason) = &launch.unavailable_reason {
        card = card.line(TextPlan::muted(reason.clone()));
    }
    if let Some(message) = &launch.error_message {
        let mut line = TextPlan::body(message.clone());
        line.tone = TextTone::Danger;
        card = card.line(line);
    }
    BlockPlan::Card(card.control(ControlPlan::Toggle {
        id: "settings-launch-at-login-toggle".to_string(),
        label: "Open Wrenflow automatically".to_string(),
        checked: launch.enabled,
        enabled: launch.available && !launch.loading,
        kind: ToggleKind::LaunchAtLogin,
    }))
}

fn duration_card(value: f64) -> BlockPlan {
    let value = value.clamp(MINIMUM_DURATION_MS, MAXIMUM_DURATION_MS);
    BlockPlan::Card(
        CardPlan::new("settings-minimum-duration", "Minimum recording duration")
            .line(TextPlan::pair("Duration", format!("{value:.0} ms")))
            .line(TextPlan::muted(
                "Very short key presses are ignored to prevent accidental recordings.",
            ))
            .control(ControlPlan::Actions(vec![
                ActionPlan::dispatch(
                    "decrease-minimum-duration",
                    "Decrease 50 ms",
                    AppAction::SetMinimumRecordingDurationMs(
                        (value - DURATION_STEP_MS).max(MINIMUM_DURATION_MS),
                    ),
                )
                .enabled(value > MINIMUM_DURATION_MS),
                ActionPlan::dispatch(
                    "increase-minimum-duration",
                    "Increase 50 ms",
                    AppAction::SetMinimumRecordingDurationMs(
                        (value + DURATION_STEP_MS).min(MAXIMUM_DURATION_MS),
                    ),
                )
                .enabled(value < MAXIMUM_DURATION_MS),
            ])),
    )
}

#[cfg(test)]
mod tests {
    use crate::app::{
        AppAction, CommandStatus, ContentState, LaunchAtLoginPresentation, SettingsPresentation,
    };
    use crate::screens::common::{BlockPlan, ControlPlan, ScreenIntent, ToggleKind};

    use super::project;

    #[test]
    fn settings_plan_maps_every_mutable_preference_to_app_actions() {
        let presentation = SettingsPresentation {
            selected_hotkey: "Option+Space".to_string(),
            hotkey_hint: None,
            sound_enabled: true,
            custom_vocabulary: "Wrenflow".to_string(),
            minimum_recording_duration_ms: 300.0,
            microphones: ContentState::Ready(Vec::new()),
            show_microphone_selection: false,
            show_launch_at_login: true,
            launch_at_login: LaunchAtLoginPresentation {
                available: true,
                enabled: false,
                loading: false,
                unavailable_reason: None,
                error_message: None,
            },
            command: CommandStatus::Idle,
            audio_devices_command: CommandStatus::Idle,
        };
        let plan = project(&presentation);

        assert!(plan.sections[0].blocks.iter().any(|block| matches!(
            block,
            BlockPlan::Card(card) if card.controls.iter().any(|control| matches!(
                control,
                ControlPlan::Toggle { kind: ToggleKind::LaunchAtLogin, .. }
            ))
        )));
        assert!(plan.sections[0].blocks.iter().any(|block| matches!(
            block,
            BlockPlan::Card(card) if card.controls.iter().any(|control| matches!(
                control,
                ControlPlan::Actions(actions) if actions.iter().any(|action|
                    matches!(action.intent, ScreenIntent::Dispatch(
                        AppAction::SetMinimumRecordingDurationMs(250.0)
                    ))
                )
            ))
        )));
    }
}

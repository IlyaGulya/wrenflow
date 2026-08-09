use crate::app::{AppAction, CommandStatus, ContentState, NavigationTarget, SettingsPresentation};
use crate::ui::StatusKind;
use wrenflow_runtime::ThemePreference;

use super::common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, InputKind, ScreenPlan, SectionPlan, SliderKind,
    TextPlan, TextTone, ToggleKind,
};

const MINIMUM_DURATION_MS: f64 = 100.0;
const MAXIMUM_DURATION_MS: f64 = 1_000.0;
const DURATION_STEP_MS: f64 = 50.0;

pub(super) fn project(settings: &SettingsPresentation) -> ScreenPlan {
    let mut blocks = vec![BlockPlan::Card(
        CardPlan::new("settings-hotkey", "Push-to-talk key").control(ControlPlan::Input {
            kind: InputKind::Hotkey,
            id: "settings-hotkey-input".to_string(),
            label: "Push-to-talk key".to_string(),
            value: settings.selected_hotkey.clone(),
            hint: settings.hotkey_hint.clone().unwrap_or_default(),
            enabled: settings.hotkey_hint.is_none(),
        }),
    )];

    if settings.show_microphone_selection {
        blocks.push(microphone_card(settings));
    }
    if settings.show_launch_at_login {
        blocks.push(launch_at_login_card(settings));
    }

    blocks.extend([
        BlockPlan::Card(CardPlan::new("settings-sound", "Sound effects").control(
            ControlPlan::Toggle {
                id: "settings-sound-toggle".to_string(),
                label: "Play sounds".to_string(),
                checked: settings.sound_enabled,
                enabled: !matches!(settings.command, CommandStatus::Pending { .. }),
                kind: ToggleKind::SoundEnabled,
            },
        )),
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
    ]);

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
    plan.sections = vec![SectionPlan::untitled(blocks)];
    plan
}

pub(super) fn appearance_actions(selected: ThemePreference) -> Vec<ActionPlan> {
    [
        ("system", "System", ThemePreference::System),
        ("light", "Light", ThemePreference::Light),
        ("dark", "Dark", ThemePreference::Dark),
    ]
    .into_iter()
    .map(|(id, label, preference)| {
        let mut action = ActionPlan::dispatch(
            format!("theme-{id}"),
            label,
            AppAction::SetThemePreference(preference),
        );
        action.style = if selected == preference {
            crate::ui::ButtonStyle::Selected
        } else {
            crate::ui::ButtonStyle::Secondary
        };
        action
    })
    .collect()
}

fn microphone_card(settings: &SettingsPresentation) -> BlockPlan {
    let mut card = CardPlan::new("settings-microphone", "Microphone");
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
                    let selected = microphone.effective || microphone.selected;
                    let mut action = ActionPlan::dispatch(
                        format!("select-microphone-{}", microphone.id),
                        microphone.name.clone(),
                        AppAction::SetSelectedMicrophone(microphone.id.clone()),
                    )
                    .enabled(!matches!(
                        &settings.audio_devices_command,
                        CommandStatus::Pending { .. }
                    ));
                    action.style = if selected {
                        crate::ui::ButtonStyle::Selected
                    } else {
                        crate::ui::ButtonStyle::Secondary
                    };
                    action
                })
                .collect();
            card = card.control(ControlPlan::Actions(actions));
        }
    }
    if !matches!(&settings.microphones, ContentState::Ready(_)) {
        card = card.control(ControlPlan::Actions(vec![ActionPlan::dispatch(
            "reload-microphones",
            "Reload devices",
            AppAction::ReloadAudioDevices,
        )
        .enabled(!matches!(
            &settings.audio_devices_command,
            CommandStatus::Pending { .. }
        ))]));
    }
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
        CardPlan::new("settings-minimum-duration", "Minimum recording duration").control(
            ControlPlan::Slider {
                id: "settings-minimum-duration-slider".to_string(),
                label: "Duration".to_string(),
                value,
                minimum: MINIMUM_DURATION_MS,
                maximum: MAXIMUM_DURATION_MS,
                step: DURATION_STEP_MS,
                enabled: true,
                kind: SliderKind::MinimumRecordingDuration,
            },
        ),
    )
}

#[cfg(test)]
mod tests {
    use crate::app::{
        AppAction, CommandStatus, ContentState, LaunchAtLoginPresentation, SettingsPresentation,
    };
    use crate::screens::common::{
        BlockPlan, ControlPlan, ScreenIntent, ScreenLayout, SliderKind, ToggleKind,
    };

    use super::{appearance_actions, project, ThemePreference};

    #[test]
    fn settings_plan_maps_every_mutable_preference_to_app_actions() {
        let presentation = SettingsPresentation {
            selected_hotkey: "Option+Space".to_string(),
            hotkey_hint: None,
            sound_enabled: true,
            theme_preference: ThemePreference::System,
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

        assert_eq!(plan.layout, ScreenLayout::Application);
        assert!(plan.subtitle.is_none());
        assert!(plan.sections[0].title.is_none());
        assert_eq!(
            plan.sections[0]
                .blocks
                .iter()
                .filter_map(|block| match block {
                    BlockPlan::Card(card) => Some(card.title.as_str()),
                    BlockPlan::Status { .. } => None,
                })
                .collect::<Vec<_>>(),
            [
                "Push-to-talk key",
                "Launch at login",
                "Sound effects",
                "Minimum recording duration",
                "Custom vocabulary",
            ]
        );
        assert!(plan.sections[0].blocks.iter().any(|block| matches!(
            block,
            BlockPlan::Card(card) if card.controls.iter().any(|control| matches!(
                control,
                ControlPlan::Toggle { kind: ToggleKind::LaunchAtLogin, .. }
            ))
        )));
        let theme_actions = appearance_actions(ThemePreference::System);
        assert!(theme_actions.iter().any(|action| matches!(
            &action.intent,
            ScreenIntent::Dispatch(AppAction::SetThemePreference(ThemePreference::System))
        )));
        assert_eq!(theme_actions[0].style, crate::ui::ButtonStyle::Selected);
        assert!(plan.sections[0].blocks.iter().any(|block| matches!(
            block,
            BlockPlan::Card(card) if card.controls.iter().any(|control| matches!(
                control,
                ControlPlan::Slider {
                    value: 300.0,
                    minimum: 100.0,
                    maximum: 1_000.0,
                    step: 50.0,
                    kind: SliderKind::MinimumRecordingDuration,
                    ..
                }
            ))
        )));
    }
}

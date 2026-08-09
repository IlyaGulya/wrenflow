use wrenflow_runtime::OnboardingStep;

use crate::app::{
    AppAction, AppPresentation, ContentState, NavigationTarget, OnboardingPresentation,
    PermissionPresentation, PermissionRecoveryPresentation, TranscriptionTestPhase,
    TranscriptionTestPresentation,
};
use crate::ui::StatusKind;

use super::common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, InputKind, ScreenPlan, SectionPlan, TextPlan,
};
use super::models::model_blocks;

pub(super) fn project(presentation: &AppPresentation) -> ScreenPlan {
    match &presentation.onboarding {
        ContentState::Loading => status_plan(
            NavigationTarget::Onboarding,
            "Preparing Wrenflow",
            StatusKind::Loading,
            "Checking microphone and accessibility permissions.",
        ),
        ContentState::Empty { title, detail } => status_plan(
            NavigationTarget::Onboarding,
            title,
            StatusKind::Success,
            detail,
        ),
        ContentState::Error { title, detail } => status_plan(
            NavigationTarget::Onboarding,
            title,
            StatusKind::Error,
            detail,
        ),
        ContentState::Ready(onboarding) => ready_plan(presentation, onboarding),
    }
}

pub(super) fn project_recovery(presentation: &AppPresentation) -> ScreenPlan {
    match &presentation.permission_recovery {
        ContentState::Loading => status_plan(
            NavigationTarget::PermissionRecovery,
            "Checking permissions",
            StatusKind::Loading,
            "Reading current macOS privacy settings.",
        ),
        ContentState::Empty { title, detail } => status_plan(
            NavigationTarget::PermissionRecovery,
            title,
            StatusKind::Success,
            detail,
        ),
        ContentState::Error { title, detail } => status_plan(
            NavigationTarget::PermissionRecovery,
            title,
            StatusKind::Error,
            detail,
        ),
        ContentState::Ready(recovery) => recovery_plan(recovery),
    }
}

fn ready_plan(presentation: &AppPresentation, onboarding: &OnboardingPresentation) -> ScreenPlan {
    let (title, subtitle, mut sections) = match onboarding.step {
        OnboardingStep::Microphone => (
            "Microphone",
            "Wrenflow needs microphone access to record your voice.",
            vec![permission_section(
                "Microphone access",
                onboarding.permissions.microphone,
                PermissionKind::Microphone,
            )],
        ),
        OnboardingStep::Accessibility => (
            "Accessibility",
            "Required for the global hotkey and pasting transcribed text.",
            vec![permission_section(
                "Accessibility access",
                onboarding.permissions.accessibility,
                PermissionKind::Accessibility,
            )],
        ),
        OnboardingStep::Hotkey => (
            "Push-to-talk key",
            "Hold the key to record, then release to transcribe and paste.",
            vec![SectionPlan::untitled(vec![BlockPlan::Card(
                CardPlan::new("onboarding-hotkey", "Hotkey").control(ControlPlan::Input {
                    kind: InputKind::Hotkey,
                    id: "onboarding-hotkey-input".to_string(),
                    label: "Push-to-talk key".to_string(),
                    value: presentation.settings.selected_hotkey.clone(),
                    hint: presentation
                        .settings
                        .hotkey_hint
                        .clone()
                        .unwrap_or_else(|| {
                            "Choose a preset or focus Custom key and press any key.".to_string()
                        }),
                    enabled: presentation.settings.hotkey_hint.is_none(),
                }),
            )])],
        ),
        OnboardingStep::Model => (
            "Transcription model",
            "Choose a local model. Download, activation and errors stay visible in its row.",
            vec![SectionPlan::new(
                "Available models",
                model_blocks(&presentation.models),
            )],
        ),
        OnboardingStep::Vocabulary => (
            "Vocabulary",
            "Add names or terms to improve recognition. Enter one item per line.",
            vec![SectionPlan::untitled(vec![BlockPlan::Card(
                CardPlan::new("onboarding-vocabulary", "Custom vocabulary").control(
                    ControlPlan::Input {
                        kind: InputKind::Vocabulary,
                        id: "onboarding-vocabulary-input".to_string(),
                        label: "Custom vocabulary".to_string(),
                        value: presentation.settings.custom_vocabulary.clone(),
                        hint: "Wrenflow\nAlmaty".to_string(),
                        enabled: !matches!(
                            presentation.settings.command,
                            crate::app::CommandStatus::Pending { .. }
                        ),
                    },
                ),
            )])],
        ),
        OnboardingStep::Complete => (
            "Ready",
            "Hold your hotkey to record, then release to transcribe.",
            vec![SectionPlan::untitled(vec![BlockPlan::Card(
                transcription_test_card(&presentation.transcription_test),
            )])],
        ),
    };

    if let crate::app::CommandStatus::Failed { message } = &onboarding.command {
        sections.insert(
            0,
            SectionPlan::untitled(vec![BlockPlan::Status {
                kind: StatusKind::Error,
                title: "Could not continue setup".to_string(),
                detail: Some(message.clone()),
                action: None,
            }]),
        );
    }
    let command_pending = matches!(
        &onboarding.command,
        crate::app::CommandStatus::Pending { .. }
    );

    let mut plan = ScreenPlan::centered(NavigationTarget::Onboarding, title);
    plan.subtitle = Some(subtitle.to_string());
    plan.progress = Some((onboarding.step_number, onboarding.step_count));
    plan.sections = sections;
    if onboarding.can_go_back {
        plan.footer_actions.push(
            ActionPlan::dispatch("onboarding-back", "Back", AppAction::RetreatOnboarding)
                .enabled(!command_pending),
        );
    }
    plan.footer_actions.push(
        ActionPlan::dispatch(
            format!("onboarding-next-{:?}", onboarding.step).to_lowercase(),
            if onboarding.step == OnboardingStep::Complete {
                "Finish"
            } else {
                "Next"
            },
            if onboarding.step == OnboardingStep::Complete {
                AppAction::SetHasCompletedSetup(true)
            } else {
                AppAction::AdvanceOnboarding
            },
        )
        .enabled(onboarding.can_continue && !command_pending),
    );
    plan
}

fn transcription_test_card(test: &TranscriptionTestPresentation) -> CardPlan {
    let title = match test.phase {
        TranscriptionTestPhase::Transcript => "Test transcription",
        TranscriptionTestPhase::Recording => "Listening…",
        TranscriptionTestPhase::Transcribing => "Transcribing…",
        TranscriptionTestPhase::ModelDownloading
        | TranscriptionTestPhase::ModelLoading
        | TranscriptionTestPhase::ModelWarming
        | TranscriptionTestPhase::LoadingCatalog
        | TranscriptionTestPhase::Starting => "Preparing your test",
        TranscriptionTestPhase::ModelError
        | TranscriptionTestPhase::RuntimeUnavailable
        | TranscriptionTestPhase::PipelineError => "Test unavailable",
        TranscriptionTestPhase::ModelManual | TranscriptionTestPhase::ModelPending => {
            "Finish preparing the model"
        }
        TranscriptionTestPhase::Idle => "Try Wrenflow now",
    };
    let mut message = TextPlan::body(
        test.message
            .clone()
            .unwrap_or_else(|| "Speak while holding your push-to-talk key.".to_string()),
    );
    message.tone = match test.phase {
        TranscriptionTestPhase::Transcript => super::common::TextTone::Success,
        TranscriptionTestPhase::ModelError
        | TranscriptionTestPhase::RuntimeUnavailable
        | TranscriptionTestPhase::PipelineError => super::common::TextTone::Danger,
        _ => super::common::TextTone::Normal,
    };
    let mut card = CardPlan::new("onboarding-complete", title).line(message);
    if let Some(value) = test.progress {
        card = card.control(ControlPlan::Progress {
            id: "onboarding-model-progress".to_string(),
            label: "Model download".to_string(),
            value: value.clamp(0.0, 1.0) as f32,
            detail: Some(format!("{:.0}%", value.clamp(0.0, 1.0) * 100.0)),
        });
    }
    if let Some(value) = test.audio_level {
        card = card.control(ControlPlan::Progress {
            id: "onboarding-audio-level".to_string(),
            label: "Microphone level".to_string(),
            value: value.clamp(0.0, 1.0),
            detail: Some("Live microphone level".to_string()),
        });
    }
    card
}

fn recovery_plan(recovery: &PermissionRecoveryPresentation) -> ScreenPlan {
    let mut blocks = Vec::new();
    if recovery.microphone_missing {
        blocks.extend(permission_section_blocks(
            "Microphone",
            recovery.permissions.microphone,
            PermissionKind::Microphone,
        ));
    }
    if recovery.accessibility_missing {
        blocks.extend(permission_section_blocks(
            "Accessibility",
            recovery.permissions.accessibility,
            PermissionKind::Accessibility,
        ));
    }

    let mut plan =
        ScreenPlan::centered(NavigationTarget::PermissionRecovery, "Permissions required");
    plan.subtitle = Some(
        "Some macOS permissions were revoked. Re-enable them to resume dictation.".to_string(),
    );
    plan.sections = vec![SectionPlan::untitled(blocks)];
    plan
}

#[derive(Clone, Copy)]
enum PermissionKind {
    Microphone,
    Accessibility,
}

fn permission_section(
    title: &str,
    status: PermissionPresentation,
    kind: PermissionKind,
) -> SectionPlan {
    SectionPlan::untitled(permission_section_blocks(title, status, kind))
}

fn permission_section_blocks(
    title: &str,
    status: PermissionPresentation,
    kind: PermissionKind,
) -> Vec<BlockPlan> {
    let (kind_status, detail, action) = match status {
        PermissionPresentation::Granted | PermissionPresentation::NotApplicable => (
            StatusKind::Success,
            "Granted. Wrenflow can continue.".to_string(),
            None,
        ),
        PermissionPresentation::Requesting => (
            StatusKind::Loading,
            "Waiting for macOS to report the permission result.".to_string(),
            None,
        ),
        PermissionPresentation::Unknown => (
            StatusKind::Empty,
            "macOS has not received a permission request yet.".to_string(),
            Some(permission_action(kind, false)),
        ),
        PermissionPresentation::Denied | PermissionPresentation::Restricted => (
            StatusKind::Error,
            "Access is disabled. Open System Settings and enable Wrenflow.".to_string(),
            Some(permission_action(kind, true)),
        ),
    };
    vec![BlockPlan::Status {
        kind: kind_status,
        title: title.to_string(),
        detail: Some(detail),
        action,
    }]
}

fn permission_action(kind: PermissionKind, open_settings: bool) -> ActionPlan {
    let (id, label, action) = match (kind, open_settings) {
        (PermissionKind::Microphone, false) => (
            "request-microphone",
            "Grant microphone access",
            AppAction::RequestMicrophonePermission,
        ),
        (PermissionKind::Microphone, true) => (
            "open-microphone-settings",
            "Open microphone settings",
            AppAction::OpenMicrophoneSettings,
        ),
        (PermissionKind::Accessibility, false) => (
            "request-accessibility",
            "Grant accessibility access",
            AppAction::RequestAccessibilityPermission,
        ),
        (PermissionKind::Accessibility, true) => (
            "open-accessibility-settings",
            "Open accessibility settings",
            AppAction::OpenAccessibilitySettings,
        ),
    };
    ActionPlan::dispatch(id, label, action)
}

fn status_plan(route: NavigationTarget, title: &str, kind: StatusKind, detail: &str) -> ScreenPlan {
    let mut plan = ScreenPlan::centered(route, title);
    plan.sections = vec![SectionPlan::untitled(vec![BlockPlan::Status {
        kind,
        title: title.to_string(),
        detail: Some(detail.to_string()),
        action: None,
    }])];
    plan
}

#[cfg(test)]
mod tests {
    use super::{permission_section_blocks, PermissionKind};
    use crate::app::{AppAction, PermissionPresentation};
    use crate::screens::common::{BlockPlan, ScreenIntent};
    use crate::ui::StatusKind;

    #[test]
    fn denied_permission_routes_to_system_settings_through_app_action() {
        let blocks = permission_section_blocks(
            "Microphone",
            PermissionPresentation::Denied,
            PermissionKind::Microphone,
        );
        let BlockPlan::Status {
            kind,
            action: Some(action),
            ..
        } = &blocks[0]
        else {
            panic!("permission should project an actionable status");
        };
        assert_eq!(*kind, StatusKind::Error);
        assert_eq!(
            action.intent,
            ScreenIntent::Dispatch(AppAction::OpenMicrophoneSettings)
        );
    }

    #[test]
    fn requesting_permission_has_no_duplicate_action() {
        let blocks = permission_section_blocks(
            "Accessibility",
            PermissionPresentation::Requesting,
            PermissionKind::Accessibility,
        );
        assert!(matches!(
            &blocks[0],
            BlockPlan::Status {
                kind: StatusKind::Loading,
                action: None,
                ..
            }
        ));
    }
}

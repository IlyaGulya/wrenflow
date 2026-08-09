use crate::app::{
    AppAction, CommandStatus, ContentState, ModelPresentation, ModelStatusPresentation,
    ModelsPresentation, NavigationTarget,
};
use crate::ui::StatusKind;

use super::common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, ScreenPlan, SectionPlan, TextPlan, TextTone,
};

pub(super) fn project(models: &ModelsPresentation) -> ScreenPlan {
    let mut plan = ScreenPlan::application(NavigationTarget::Models, "Models");
    plan.sections = vec![
        SectionPlan::untitled(vec![BlockPlan::Card(model_summary(models))]),
        SectionPlan::new("Choose model", model_blocks(models))
            .compact()
            .framed(),
    ];
    plan
}

fn model_summary(models: &ModelsPresentation) -> CardPlan {
    let mut card = CardPlan::new("models-summary", "Model status").dense();
    match &models.models {
        ContentState::Ready(items) => {
            let preferred = items
                .iter()
                .find(|model| model.selected)
                .map_or("None", |model| model.display_name.as_str());
            let active = items
                .iter()
                .find(|model| model.active)
                .map_or("None", |model| model.display_name.as_str());
            let installed = items.iter().filter(|model| model.installed).count();
            card = card
                .line(TextPlan::pair("Preferred", preferred))
                .line(TextPlan::pair("Active", active))
                .line(TextPlan::pair("Installed", installed.to_string()))
                .line(TextPlan::muted(
                    "Selecting a card changes your preferred model. Download, activation, progress, and errors are shown directly inside the selected card.",
                ));
        }
        ContentState::Loading => {
            card = card.line(TextPlan::muted("Loading model status…"));
        }
        ContentState::Empty { detail, .. } | ContentState::Error { detail, .. } => {
            card = card.line(TextPlan::muted(detail.clone()));
        }
    }
    card
}

pub(super) fn model_blocks(models: &ModelsPresentation) -> Vec<BlockPlan> {
    let mut blocks = match &models.models {
        ContentState::Loading => vec![status(
            StatusKind::Loading,
            "Loading models",
            "Reading the local model catalog and installed state.",
        )],
        ContentState::Empty { title, detail } => {
            vec![status(StatusKind::Empty, title, detail)]
        }
        ContentState::Error { title, detail } => {
            vec![status(StatusKind::Error, title, detail)]
        }
        ContentState::Ready(items) => items
            .iter()
            .map(|model| BlockPlan::Card(model_card(model)))
            .collect(),
    };

    match &models.activation {
        CommandStatus::Pending { .. } => blocks.push(status(
            StatusKind::Loading,
            "Applying model change",
            "Wrenflow is downloading, loading or warming the selected model.",
        )),
        CommandStatus::Failed { message } => blocks.push(BlockPlan::Status {
            kind: StatusKind::Error,
            title: "Model operation failed".to_string(),
            detail: Some(message.clone()),
            action: Some(
                ActionPlan::dispatch(
                    "retry-model-operation",
                    "Retry selected model",
                    AppAction::ActivateSelectedModel,
                )
                .primary(),
            ),
        }),
        CommandStatus::Idle | CommandStatus::Succeeded { .. } => {}
    }
    blocks
}

fn model_card(model: &ModelPresentation) -> CardPlan {
    let mut card = CardPlan::new(format!("model-{}", model.id), model.display_name.clone())
        .dense()
        .selectable(model.selected)
        .title_badge(model.runtime_label.clone())
        .line(TextPlan::muted(model.subtitle.clone()))
        .line(TextPlan::pair("Family", model.family.clone()))
        .line(TextPlan::pair("Download", model.download_label.clone()));

    if model.installed {
        card = card.line(TextPlan::pair("State", "Installed"));
    }
    if !model.available || !model.runtime_supported {
        let mut line = TextPlan::muted(if !model.available {
            "This model is not available in the current build."
        } else {
            "The current runtime does not support this model."
        });
        line.tone = TextTone::Danger;
        return card
            .line(line)
            .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                format!("select-model-{}", model.id),
                "Unavailable",
                AppAction::SelectLocalModel(model.id.clone()),
            )
            .enabled(false)]));
    }

    if !model.selected {
        if model.recommended {
            card = card.line(TextPlan::pair("Recommendation", "Default"));
        }
        return card
            .line(TextPlan::muted(if model.installed {
                "Installed locally. Select it to make it your preferred model."
            } else {
                "Available, but not selected."
            }))
            .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                format!("select-model-{}", model.id),
                "Select",
                AppAction::SelectLocalModel(model.id.clone()),
            )]));
    }

    card = card.line(TextPlan::pair("Preferred", "Selected"));
    if model.recommended {
        card = card.line(TextPlan::pair("Recommendation", "Default"));
    }
    card = card.line(TextPlan::muted(if model.installed {
        "Selected as preferred. Use the action below when you want to switch."
    } else {
        "Selected as preferred. Download and activate it from this card."
    }));
    match &model.status {
        ModelStatusPresentation::NotDownloaded => card
            .line(TextPlan::muted(format!(
                "{} is not downloaded yet.",
                model.display_name
            )))
            .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                format!("download-model-{}", model.id),
                "Download & activate",
                AppAction::ActivateSelectedModel,
            )
            .primary()])),
        ModelStatusPresentation::Downloading {
            progress,
            speed_bps,
            eta_secs,
        } => card
            .line(TextPlan::muted(format!(
                "{} · {} remaining",
                format_speed(*speed_bps),
                format_duration(*eta_secs)
            )))
            .control(ControlPlan::Progress {
                id: format!("model-progress-{}", model.id),
                label: format!("Downloading {}", model.display_name),
                value: *progress as f32,
                detail: Some(format!("{:.0}%", progress.clamp(0.0, 1.0) * 100.0)),
            })
            .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                format!("cancel-model-{}", model.id),
                "Cancel",
                AppAction::CancelModelOperation,
            )
            .danger()])),
        ModelStatusPresentation::Loading => busy_card(card, model, "Loading model"),
        ModelStatusPresentation::Warming => busy_card(card, model, "Warming model"),
        ModelStatusPresentation::Ready if model.active => {
            let mut line = TextPlan::body("Ready for transcription");
            line.tone = TextTone::Success;
            card.line(line)
        }
        ModelStatusPresentation::Ready => {
            card.control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                format!("activate-model-{}", model.id),
                "Activate",
                AppAction::ActivateSelectedModel,
            )
            .primary()]))
        }
        ModelStatusPresentation::Error { message } => {
            let mut line = TextPlan::body(message.clone());
            line.tone = TextTone::Danger;
            card.line(line)
                .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                    format!("retry-model-{}", model.id),
                    "Retry",
                    AppAction::ActivateSelectedModel,
                )
                .primary()]))
        }
    }
}

fn busy_card(card: CardPlan, model: &ModelPresentation, label: &str) -> CardPlan {
    card.line(TextPlan::muted(label))
        .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
            format!("cancel-model-{}", model.id),
            "Cancel",
            AppAction::CancelModelOperation,
        )
        .danger()]))
}

fn status(kind: StatusKind, title: &str, detail: &str) -> BlockPlan {
    BlockPlan::Status {
        kind,
        title: title.to_string(),
        detail: Some(detail.to_string()),
        action: None,
    }
}

fn format_speed(bytes_per_second: f64) -> String {
    if bytes_per_second >= 1_000_000.0 {
        format!("{:.1} MB/s", bytes_per_second / 1_000_000.0)
    } else if bytes_per_second >= 1_000.0 {
        format!("{:.0} KB/s", bytes_per_second / 1_000.0)
    } else {
        format!("{bytes_per_second:.0} B/s")
    }
}

fn format_duration(seconds: f64) -> String {
    if !seconds.is_finite() || seconds <= 0.0 {
        return "estimating…".to_string();
    }
    if seconds >= 60.0 {
        format!("{:.0} min", seconds / 60.0)
    } else {
        format!("{seconds:.0} sec")
    }
}

#[cfg(test)]
mod tests {
    use crate::app::{
        AppAction, CommandStatus, ContentState, ModelPresentation, ModelStatusPresentation,
        ModelsPresentation,
    };
    use crate::screens::common::{BlockPlan, ControlPlan, ScreenIntent, ScreenLayout};

    use super::project;

    #[test]
    fn downloading_model_projects_progress_and_cancel_action() {
        let presentation = ModelsPresentation {
            models: ContentState::Ready(vec![ModelPresentation {
                id: "turbo".to_string(),
                display_name: "Whisper Turbo".to_string(),
                subtitle: "Fast local model".to_string(),
                download_label: "809 MB".to_string(),
                family: "Whisper".to_string(),
                runtime_label: "ONNX".to_string(),
                recommended: true,
                available: true,
                runtime_supported: true,
                installed: false,
                selected: true,
                active: false,
                status: ModelStatusPresentation::Downloading {
                    progress: 0.5,
                    speed_bps: 2_000_000.0,
                    eta_secs: 30.0,
                },
            }]),
            activation: CommandStatus::Idle,
        };

        let plan = project(&presentation);
        assert_eq!(plan.layout, ScreenLayout::Application);
        assert_eq!(plan.sections.len(), 2);
        assert!(plan.sections[0].title.is_none());
        assert_eq!(plan.sections[1].title.as_deref(), Some("Choose model"));
        assert!(plan.sections[1].compact);
        assert!(plan.sections[1].framed);
        let BlockPlan::Card(summary) = &plan.sections[0].blocks[0] else {
            panic!("model status should project a source-parity summary card");
        };
        assert_eq!(summary.title, "Model status");
        assert!(!summary.title_inside);
        let BlockPlan::Card(card) = &plan.sections[1].blocks[0] else {
            panic!("ready model should project a card");
        };
        assert_eq!(card.selection, Some(true));
        assert_eq!(card.title_badge.as_deref(), Some("ONNX"));
        assert_eq!(
            card.lines
                .iter()
                .filter_map(|line| line.label.as_deref())
                .collect::<Vec<_>>(),
            vec!["Family", "Download", "Preferred", "Recommendation"]
        );
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Progress { value, .. } if (*value - 0.5).abs() < f32::EPSILON
        )));
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions)
                if actions.iter().any(|action| action.intent
                    == ScreenIntent::Dispatch(AppAction::CancelModelOperation))
        )));
    }

    #[test]
    fn selected_model_keeps_flutter_status_copy_before_its_action() {
        let presentation = ModelsPresentation {
            models: ContentState::Ready(vec![ModelPresentation {
                id: "parakeet".to_string(),
                display_name: "Parakeet Realtime".to_string(),
                subtitle: "Fast local dictation".to_string(),
                download_label: "~400 MB".to_string(),
                family: "Parakeet".to_string(),
                runtime_label: "ONNX".to_string(),
                recommended: true,
                available: true,
                runtime_supported: true,
                installed: false,
                selected: true,
                active: false,
                status: ModelStatusPresentation::NotDownloaded,
            }]),
            activation: CommandStatus::Idle,
        };

        let plan = project(&presentation);
        let BlockPlan::Card(card) = &plan.sections[1].blocks[0] else {
            panic!("ready model should project a card");
        };
        assert!(card.lines.iter().any(|line| {
            line.value == "Selected as preferred. Download and activate it from this card."
        }));
        assert!(card
            .lines
            .iter()
            .any(|line| line.value == "Parakeet Realtime is not downloaded yet."));
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions)
                if actions.iter().any(|action| action.label == "Download & activate")
        )));
    }
}

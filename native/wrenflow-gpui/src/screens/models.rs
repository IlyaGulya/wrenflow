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
    plan.subtitle = Some(
        "Select a preferred local transcription model, then download or activate it.".to_string(),
    );
    plan.sections = vec![SectionPlan::new(
        "Local transcription",
        model_blocks(models),
    )];
    plan
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
    let title = if model.recommended {
        format!("{} · Recommended", model.display_name)
    } else {
        model.display_name.clone()
    };
    let mut card = CardPlan::new(format!("model-{}", model.id), title)
        .line(TextPlan::body(model.subtitle.clone()))
        .line(TextPlan::pair("Family", model.family.clone()))
        .line(TextPlan::pair("Runtime", model.runtime_label.clone()))
        .line(TextPlan::pair("Download", model.download_label.clone()));

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
        return card.control(ControlPlan::Actions(vec![ActionPlan::dispatch(
            format!("select-model-{}", model.id),
            "Select",
            AppAction::SelectLocalModel(model.id.clone()),
        )]));
    }

    card = card.line(TextPlan::pair("Preferred", "Selected"));
    match &model.status {
        ModelStatusPresentation::NotDownloaded => {
            card.control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                format!("download-model-{}", model.id),
                "Download and activate",
                AppAction::ActivateSelectedModel,
            )
            .primary()]))
        }
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
    use crate::screens::common::{BlockPlan, ControlPlan, ScreenIntent};

    use super::model_blocks;

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

        let blocks = model_blocks(&presentation);
        let BlockPlan::Card(card) = &blocks[0] else {
            panic!("ready model should project a card");
        };
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
}

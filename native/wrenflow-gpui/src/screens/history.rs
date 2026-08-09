use serde_json::Value;

use crate::app::{
    AppAction, CommandStatus, ContentState, HistoryItemPresentation, HistoryPresentation,
    NavigationTarget,
};
use crate::ui::StatusKind;

use super::common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, ScreenIntent, ScreenPlan, SectionPlan, TextPlan,
    TextTone,
};

pub(super) fn project(history: &HistoryPresentation, confirm_clear_history: bool) -> ScreenPlan {
    let expanded_id = history
        .selected_entry
        .as_ref()
        .map(|entry| entry.id.as_str());
    let mut blocks = match &history.entries {
        ContentState::Loading => vec![status(
            StatusKind::Loading,
            "Loading history",
            "Reading locally stored transcriptions.",
        )],
        ContentState::Empty { title, detail } => {
            vec![status(StatusKind::Empty, title, detail)]
        }
        ContentState::Error { title, detail } => {
            vec![status(StatusKind::Error, title, detail)]
        }
        ContentState::Ready(entries) => entries
            .iter()
            .map(|entry| BlockPlan::Card(history_card(entry, expanded_id == Some(&entry.id))))
            .collect(),
    };

    match &history.mutation {
        CommandStatus::Pending { .. } => blocks.insert(
            0,
            status(
                StatusKind::Loading,
                "Updating history",
                "Applying the requested local history change.",
            ),
        ),
        CommandStatus::Failed { message } => blocks.insert(
            0,
            status(StatusKind::Error, "History action failed", message),
        ),
        CommandStatus::Idle | CommandStatus::Succeeded { .. } => {}
    }

    let has_entries =
        matches!(&history.entries, ContentState::Ready(entries) if !entries.is_empty());
    let mut plan = ScreenPlan::application(NavigationTarget::History, "History");
    plan.subtitle =
        Some("Transcriptions stay on this Mac and can be reviewed or deleted.".to_string());
    plan.sections = vec![SectionPlan::new("Recent transcriptions", blocks)];
    if has_entries {
        plan.footer_actions.push(
            ActionPlan::intent(
                "clear-history",
                "Clear all",
                ScreenIntent::ShowClearHistoryConfirmation,
            )
            .danger(),
        );
    }
    plan.confirm_clear_history = confirm_clear_history;
    plan
}

fn history_card(entry: &HistoryItemPresentation, expanded: bool) -> CardPlan {
    let mut card = CardPlan::new(
        format!("history-{}", entry.id),
        format_timestamp(entry.timestamp),
    )
    .line(TextPlan::body(if expanded {
        entry.transcript.clone()
    } else {
        transcript_preview(&entry.transcript)
    }));

    if expanded {
        if !entry.custom_vocabulary.trim().is_empty() {
            card = card.line(TextPlan::pair(
                "Vocabulary",
                entry.custom_vocabulary.clone(),
            ));
        }
        if let Some(audio_file_name) = &entry.audio_file_name {
            card = card.line(TextPlan::pair("Audio", audio_file_name.clone()));
        }
        for line in metric_lines(&entry.metrics_json) {
            card = card.line(line);
        }
    }

    card.control(ControlPlan::Actions(vec![
        ActionPlan::intent(
            format!("toggle-history-{}", entry.id),
            if expanded {
                "Hide details"
            } else {
                "Show details"
            },
            ScreenIntent::Dispatch(if expanded {
                AppAction::CloseHistoryEntry
            } else {
                AppAction::OpenHistoryEntry(entry.id.clone())
            }),
        ),
        ActionPlan::dispatch(
            format!("delete-history-{}", entry.id),
            "Delete",
            AppAction::DeleteHistoryEntry(entry.id.clone()),
        )
        .danger(),
    ]))
}

fn metric_lines(metrics_json: &str) -> Vec<TextPlan> {
    let Ok(Value::Object(metrics)) = serde_json::from_str::<Value>(metrics_json) else {
        if metrics_json.trim().is_empty() || metrics_json.trim() == "{}" {
            return Vec::new();
        }
        let mut line = TextPlan::pair("Metrics", metrics_json);
        line.tone = TextTone::Monospace;
        return vec![line];
    };

    let mut metrics: Vec<_> = metrics.into_iter().collect();
    metrics.sort_by(|left, right| left.0.cmp(&right.0));
    metrics
        .into_iter()
        .map(|(key, value)| {
            let mut line = TextPlan::pair(key, format_metric(&value));
            line.tone = TextTone::Monospace;
            line
        })
        .collect()
}

fn format_metric(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        _ => value.to_string(),
    }
}

fn transcript_preview(transcript: &str) -> String {
    const PREVIEW_LENGTH: usize = 160;
    let mut preview: String = transcript.chars().take(PREVIEW_LENGTH).collect();
    if transcript.chars().count() > PREVIEW_LENGTH {
        preview.push('…');
    }
    preview
}

fn format_timestamp(timestamp: f64) -> String {
    if timestamp.is_finite() && timestamp >= 0.0 {
        format!("Transcription · {:.0}", timestamp)
    } else {
        "Transcription".to_string()
    }
}

fn status(kind: StatusKind, title: &str, detail: &str) -> BlockPlan {
    BlockPlan::Status {
        kind,
        title: title.to_string(),
        detail: Some(detail.to_string()),
        action: None,
    }
}

#[cfg(test)]
mod tests {
    use crate::app::AppAction;
    use crate::app::{CommandStatus, ContentState, HistoryItemPresentation, HistoryPresentation};
    use crate::screens::common::{BlockPlan, ControlPlan, ScreenIntent};

    use super::project;

    fn entry() -> HistoryItemPresentation {
        HistoryItemPresentation {
            id: "one".to_string(),
            timestamp: 1_700_000_000.0,
            transcript: "A complete transcription".to_string(),
            custom_vocabulary: "Wrenflow".to_string(),
            audio_file_name: Some("one.ogg".to_string()),
            metrics_json: r#"{"duration_ms":1200,"model":"turbo"}"#.to_string(),
        }
    }

    #[test]
    fn expanded_history_row_exposes_detail_metrics_and_delete() {
        let history = HistoryPresentation {
            entries: ContentState::Ready(vec![entry()]),
            selected_entry: Some(entry()),
            mutation: CommandStatus::Idle,
        };
        let plan = project(&history, false);
        let BlockPlan::Card(card) = &plan.sections[0].blocks[0] else {
            panic!("history entry should project a card");
        };
        assert!(card
            .lines
            .iter()
            .any(|line| line.label.as_deref() == Some("Audio")));
        assert!(card
            .lines
            .iter()
            .any(|line| line.label.as_deref() == Some("duration_ms")));
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions) if actions.iter().any(|action|
                action.intent == ScreenIntent::Dispatch(AppAction::CloseHistoryEntry)
            )
        )));
    }

    #[test]
    fn clear_history_requires_local_confirmation_state() {
        let history = HistoryPresentation {
            entries: ContentState::Ready(vec![entry()]),
            selected_entry: None,
            mutation: CommandStatus::Idle,
        };
        let plan = project(&history, true);
        assert!(plan.confirm_clear_history);
        assert_eq!(
            plan.footer_actions[0].intent,
            ScreenIntent::ShowClearHistoryConfirmation
        );
    }
}

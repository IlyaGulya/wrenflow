use crate::app::{
    AboutPresentation, AppAction, DiagnosticPresentation, NavigationTarget, UpdatePresentation,
};
use crate::ui::StatusKind;

use super::common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, ScreenPlan, SectionPlan, TextPlan, TextTone,
};

pub(super) fn project(about: &AboutPresentation) -> ScreenPlan {
    let mut plan = ScreenPlan::application(NavigationTarget::About, "About Wrenflow");
    plan.subtitle = Some("Hold a key to record, then release to transcribe locally.".to_string());
    plan.sections = vec![
        SectionPlan::new(
            "Application",
            vec![BlockPlan::Card(
                CardPlan::new("about-application", "Wrenflow")
                    .line(TextPlan::pair("Version", about.version.clone()))
                    .line(TextPlan::muted(
                        "Menu bar speech-to-text with local transcription.",
                    )),
            )],
        ),
        if about.show_updates {
            SectionPlan::new("Updates", vec![update_block(&about.update)])
        } else {
            SectionPlan::new(
                "Updates",
                vec![BlockPlan::Status {
                    kind: StatusKind::Empty,
                    title: "Update checks hidden".to_string(),
                    detail: Some("This distribution manages updates externally.".to_string()),
                    action: None,
                }],
            )
        },
        SectionPlan::new("Runtime status", diagnostics_blocks(&about.diagnostics)),
    ];
    plan
}

fn update_block(update: &UpdatePresentation) -> BlockPlan {
    match update {
        UpdatePresentation::Unsupported => BlockPlan::Status {
            kind: StatusKind::Empty,
            title: "Updates unavailable".to_string(),
            detail: Some("This build does not provide automatic update checks.".to_string()),
            action: None,
        },
        UpdatePresentation::Idle => BlockPlan::Card(
            CardPlan::new("about-updates", "Check for updates")
                .line(TextPlan::muted(
                    "Compare this build with the latest published Wrenflow release.",
                ))
                .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                    "check-for-updates",
                    "Check now",
                    AppAction::CheckForUpdates,
                )
                .primary()])),
        ),
        UpdatePresentation::Checking => BlockPlan::Status {
            kind: StatusKind::Loading,
            title: "Checking for updates".to_string(),
            detail: Some("Contacting the release service.".to_string()),
            action: None,
        },
        UpdatePresentation::UpToDate => BlockPlan::Status {
            kind: StatusKind::Success,
            title: "Wrenflow is up to date".to_string(),
            detail: Some("You are running the latest available version.".to_string()),
            action: Some(ActionPlan::dispatch(
                "check-for-updates-again",
                "Check again",
                AppAction::CheckForUpdates,
            )),
        },
        UpdatePresentation::Available {
            latest_version,
            release_url,
            download_url,
            published_at_iso,
        } => {
            let mut card = CardPlan::new("about-update-available", "Update available")
                .line(TextPlan::pair("Latest version", latest_version.clone()))
                .line(TextPlan::pair("Release notes", release_url.clone()))
                .line(TextPlan::pair("Download", download_url.clone()));
            if let Some(published_at_iso) = published_at_iso {
                card = card.line(TextPlan::pair("Published", published_at_iso.clone()));
            }
            BlockPlan::Card(card.control(ControlPlan::Actions(vec![
                ActionPlan::dispatch(
                    "open-available-update",
                    "Download update",
                    AppAction::OpenAvailableUpdate,
                )
                .primary(),
            ])))
        }
        UpdatePresentation::Error { message } => BlockPlan::Status {
            kind: StatusKind::Error,
            title: "Could not check for updates".to_string(),
            detail: Some(message.clone()),
            action: Some(
                ActionPlan::dispatch(
                    "retry-update-check",
                    "Try again",
                    AppAction::CheckForUpdates,
                )
                .primary(),
            ),
        },
    }
}

fn diagnostics_blocks(diagnostics: &[DiagnosticPresentation]) -> Vec<BlockPlan> {
    if diagnostics.is_empty() {
        return vec![BlockPlan::Status {
            kind: StatusKind::Empty,
            title: "Diagnostics unavailable".to_string(),
            detail: Some("Runtime diagnostics have not been reported yet.".to_string()),
            action: None,
        }];
    }

    vec![BlockPlan::Card(diagnostics.iter().fold(
        CardPlan::new("about-runtime", "Runtime capabilities"),
        |card, diagnostic| card.line(diagnostic_line(diagnostic)),
    ))]
}

fn diagnostic_line(diagnostic: &DiagnosticPresentation) -> TextPlan {
    let mut line = TextPlan::pair(diagnostic.label.clone(), diagnostic.value.clone());
    line.tone = if diagnostic.healthy {
        TextTone::Success
    } else {
        TextTone::Danger
    };
    line
}

#[cfg(test)]
mod tests {
    use crate::app::{AboutPresentation, AppAction, DiagnosticPresentation, UpdatePresentation};
    use crate::screens::common::{BlockPlan, ControlPlan, ScreenIntent};

    use super::project;

    #[test]
    fn available_update_projects_version_urls_and_typed_open_action() {
        let plan = project(&AboutPresentation {
            version: "0.3.0".to_string(),
            show_updates: true,
            update: UpdatePresentation::Available {
                latest_version: "0.4.0".to_string(),
                release_url: "https://example.test/release".to_string(),
                download_url: "https://example.test/download".to_string(),
                published_at_iso: Some("2026-08-09".to_string()),
            },
            diagnostics: vec![DiagnosticPresentation {
                label: "Runtime".to_string(),
                value: "Ready".to_string(),
                healthy: true,
            }],
        });
        let BlockPlan::Card(card) = &plan.sections[1].blocks[0] else {
            panic!("available update should project a card");
        };
        assert!(card.lines.iter().any(|line| line.value == "0.4.0"));
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions) if actions.iter().any(|action|
                action.intent == ScreenIntent::Dispatch(AppAction::OpenAvailableUpdate)
            )
        )));
    }
}

use wrenflow_runtime::{
    recovery::RecoveryMode,
    support::SupportBundleFailureCode,
    update::{UpdateChannel, UpdateFailureCode},
};

use crate::app::{
    AboutPresentation, AppAction, DiagnosticPresentation, NavigationTarget,
    SupportBundlePresentation, UpdatePresentation,
};
use crate::ui::StatusKind;

use super::common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, ScreenIntent, ScreenPlan, SectionPlan, TextPlan,
    TextTone,
};

pub(super) fn project(about: &AboutPresentation) -> ScreenPlan {
    let mut plan = ScreenPlan::application(NavigationTarget::About, "About Wrenflow");
    plan.subtitle = Some("Hold a key to record, release to transcribe.".to_string());
    plan.brand_version = Some(about.version.clone());
    plan.sections = vec![
        SectionPlan::new(
            "Updates",
            vec![update_block(about.show_updates, &about.update)],
        ),
        SectionPlan::new("Runtime status", diagnostics_blocks(&about.diagnostics)),
        SectionPlan::new("Support", vec![support_block(&about.support_bundle)]).compact(),
        SectionPlan::new("Recovery", vec![recovery_block(&about.recovery)]).compact(),
    ];
    plan
}

fn update_block(show_updates: bool, update: &UpdatePresentation) -> BlockPlan {
    if !show_updates {
        return BlockPlan::Card(
            CardPlan::new("about-updates-unavailable", "Updates unavailable").inline(),
        );
    }

    match update {
        UpdatePresentation::Unsupported => BlockPlan::Card(
            CardPlan::new("about-updates-unavailable", "Updates unavailable").inline(),
        ),
        UpdatePresentation::Idle => BlockPlan::Card(
            CardPlan::new("about-updates", "Check for updates")
                .inline()
                .control(ControlPlan::Actions(vec![
                    ActionPlan::dispatch(
                        "check-for-updates",
                        "Check now",
                        AppAction::CheckForUpdates,
                    )
                    .ghost(),
                    ActionPlan::dispatch(
                        "check-for-beta-updates",
                        "Beta",
                        AppAction::CheckForBetaUpdates,
                    )
                    .ghost(),
                ])),
        ),
        UpdatePresentation::Checking { channel } => status(
            StatusKind::Loading,
            "Checking for updates",
            Some(format!("Checking the {} channel.", channel_label(*channel))),
            None,
        ),
        UpdatePresentation::UpToDate { channel } => BlockPlan::Card(
            CardPlan::new("about-updates-current", "You're up to date")
                .inline()
                .control(ControlPlan::Actions(vec![
                    check_action(*channel, "check-for-updates-again", "Check now").ghost(),
                ])),
        ),
        UpdatePresentation::Available {
            latest_version,
            channel,
            published_at_iso,
            size_bytes,
        } => {
            let mut card = CardPlan::new("about-update-available", "Update available")
                .line(TextPlan::pair("Version", latest_version.clone()))
                .line(TextPlan::pair("Channel", channel_label(*channel)))
                .line(TextPlan::pair("Download", format_bytes(*size_bytes)));
            if let Some(published_at_iso) = published_at_iso {
                card = card.line(TextPlan::pair("Published", published_at_iso.clone()));
            }
            BlockPlan::Card(card.control(ControlPlan::Actions(vec![
                ActionPlan::dispatch(
                    "download-available-update",
                    "Download update",
                    AppAction::DownloadAvailableUpdate,
                )
                .primary(),
            ])))
        }
        UpdatePresentation::Downloading {
            latest_version,
            total_bytes,
        } => status(
            StatusKind::Loading,
            "Downloading update",
            Some(format!(
                "Version {latest_version} · {}. Verification follows the download.",
                format_bytes(*total_bytes)
            )),
            None,
        ),
        UpdatePresentation::ReadyToInstall { latest_version } => status(
            StatusKind::Success,
            "Update verified",
            Some(format!("Version {latest_version} is ready to install atomically.")),
            Some(
                ActionPlan::dispatch(
                    "install-ready-update",
                    "Install and relaunch",
                    AppAction::InstallReadyUpdate,
                )
                .primary(),
            ),
        ),
        UpdatePresentation::Installing { latest_version } => status(
            StatusKind::Loading,
            "Installing update",
            Some(format!("Installing version {latest_version}; Wrenflow will relaunch.")),
            None,
        ),
        UpdatePresentation::RecoveryRequired { code } => status(
            StatusKind::Error,
            "Update recovery required",
            Some(format!(
                "The atomic install did not finish safely ({}). Reinstall the current signed GPUI line.",
                update_failure_code(*code)
            )),
            None,
        ),
        UpdatePresentation::Error {
            code,
            retryable,
            retry_after_seconds,
        } => {
            let mut detail = update_failure_copy(*code).to_string();
            if let Some(seconds) = retry_after_seconds {
                detail.push_str(&format!(" Try again in {seconds} seconds."));
            }
            status(
                StatusKind::Error,
                "Could not update Wrenflow",
                Some(detail),
                retryable.then(|| {
                    ActionPlan::dispatch(
                        "retry-update-check",
                        "Try again",
                        AppAction::CheckForUpdates,
                    )
                    .primary()
                }),
            )
        }
    }
}

fn support_block(support: &SupportBundlePresentation) -> BlockPlan {
    match support {
        SupportBundlePresentation::Idle => BlockPlan::Card(
            CardPlan::new("about-support", "Export diagnostics")
                .line(TextPlan::muted(
                    "Create a redacted local support bundle with fixed diagnostic codes.",
                ))
                .control(ControlPlan::Actions(vec![ActionPlan::dispatch(
                    "export-support-bundle",
                    "Export support bundle",
                    AppAction::ExportSupportBundle,
                )])),
        ),
        SupportBundlePresentation::Exporting => status(
            StatusKind::Loading,
            "Creating support bundle",
            Some("Collecting bounded, redacted diagnostics.".to_string()),
            None,
        ),
        SupportBundlePresentation::Exported {
            suggested_filename,
            size_bytes,
        } => status(
            StatusKind::Success,
            "Support bundle ready",
            Some(format!(
                "{} · {}",
                suggested_filename,
                format_bytes(*size_bytes)
            )),
            Some(ActionPlan::dispatch(
                "export-support-bundle-again",
                "Export again",
                AppAction::ExportSupportBundle,
            )),
        ),
        SupportBundlePresentation::Error { code } => status(
            StatusKind::Error,
            "Could not create support bundle",
            Some(support_failure_copy(*code).to_string()),
            Some(ActionPlan::dispatch(
                "retry-support-export",
                "Try again",
                AppAction::ExportSupportBundle,
            )),
        ),
    }
}

fn recovery_block(recovery: &crate::app::RecoveryPresentation) -> BlockPlan {
    let mode = match recovery.mode {
        RecoveryMode::Normal => "Normal",
        RecoveryMode::Recovered => "Recovered",
        RecoveryMode::Safe => "Safe mode",
    };
    let mut card = CardPlan::new("about-recovery", "Current-format recovery")
        .line(TextPlan::pair("Mode", mode))
        .line(TextPlan::pair(
            "Unclean launches",
            recovery.consecutive_unclean_launches.to_string(),
        ))
        .line(TextPlan::pair(
            "Cleaned temporary items",
            recovery.cleaned_temporary_files.to_string(),
        ));
    if recovery.reinstall_current_line_recommended {
        let mut warning =
            TextPlan::body("Reinstall the current signed GPUI release line before continuing.");
        warning.tone = TextTone::Danger;
        card = card.line(warning);
    }
    if recovery.reset_current_data_available {
        card = card.control(ControlPlan::Actions(vec![ActionPlan::intent(
            "show-reset-current-data-confirmation",
            "Reset current data…",
            ScreenIntent::ShowResetCurrentDataConfirmation,
        )
        .danger()]));
    }
    BlockPlan::Card(card)
}

fn diagnostics_blocks(diagnostics: &[DiagnosticPresentation]) -> Vec<BlockPlan> {
    if diagnostics.is_empty() {
        return vec![status(
            StatusKind::Empty,
            "Diagnostics unavailable",
            Some("Runtime diagnostics have not been reported yet.".to_string()),
            None,
        )];
    }

    vec![BlockPlan::Card(diagnostics.iter().fold(
        CardPlan::new("about-runtime", "Runtime capabilities").hide_title(),
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

fn status(
    kind: StatusKind,
    title: &str,
    detail: Option<String>,
    action: Option<ActionPlan>,
) -> BlockPlan {
    BlockPlan::Status {
        kind,
        title: title.to_string(),
        detail,
        action,
    }
}

fn check_action(channel: UpdateChannel, id: &str, label: &str) -> ActionPlan {
    let action = match channel {
        UpdateChannel::Stable => AppAction::CheckForUpdates,
        UpdateChannel::Beta => AppAction::CheckForBetaUpdates,
    };
    ActionPlan::dispatch(id, label, action)
}

const fn channel_label(channel: UpdateChannel) -> &'static str {
    match channel {
        UpdateChannel::Stable => "Stable",
        UpdateChannel::Beta => "Beta",
    }
}

fn format_bytes(bytes: u64) -> String {
    const KIB: f64 = 1_024.0;
    const MIB: f64 = KIB * 1_024.0;
    const GIB: f64 = MIB * 1_024.0;
    let bytes = bytes as f64;
    if bytes >= GIB {
        format!("{:.1} GB", bytes / GIB)
    } else if bytes >= MIB {
        format!("{:.0} MB", bytes / MIB)
    } else if bytes >= KIB {
        format!("{:.0} KB", bytes / KIB)
    } else {
        format!("{bytes:.0} B")
    }
}

const fn update_failure_code(code: UpdateFailureCode) -> &'static str {
    match code {
        UpdateFailureCode::Offline => "update_offline",
        UpdateFailureCode::RateLimited => "update_rate_limited",
        UpdateFailureCode::ServiceUnavailable => "update_service_unavailable",
        UpdateFailureCode::MalformedMetadata => "update_malformed_metadata",
        UpdateFailureCode::DuplicateRelease => "update_duplicate_release",
        UpdateFailureCode::UnsupportedReleaseLine => "update_unsupported_release_line",
        UpdateFailureCode::UnexpectedHost => "update_unexpected_host",
        UpdateFailureCode::MissingArtifact => "update_missing_artifact",
        UpdateFailureCode::AmbiguousArtifact => "update_ambiguous_artifact",
        UpdateFailureCode::InvalidArtifactMetadata => "update_invalid_artifact_metadata",
        UpdateFailureCode::PartialDownload => "update_partial_download",
        UpdateFailureCode::ArtifactTooLarge => "update_artifact_too_large",
        UpdateFailureCode::ChecksumMismatch => "update_checksum_mismatch",
        UpdateFailureCode::SignatureMismatch => "update_signature_mismatch",
        UpdateFailureCode::NotarizationMissing => "update_notarization_missing",
        UpdateFailureCode::BundleMismatch => "update_bundle_mismatch",
        UpdateFailureCode::SupportMismatch => "update_support_mismatch",
        UpdateFailureCode::SupplyChainMismatch => "update_supply_chain_mismatch",
        UpdateFailureCode::StagingFailed => "update_staging_failed",
        UpdateFailureCode::AtomicSwapFailed => "update_atomic_swap_failed",
        UpdateFailureCode::RecoveryRequired => "update_recovery_required",
        UpdateFailureCode::UnsupportedInstallation => "update_unsupported_installation",
    }
}

const fn update_failure_copy(code: UpdateFailureCode) -> &'static str {
    match code {
        UpdateFailureCode::Offline => "No network connection is available.",
        UpdateFailureCode::RateLimited => "The update service asked Wrenflow to wait.",
        UpdateFailureCode::ServiceUnavailable => "The update service is temporarily unavailable.",
        UpdateFailureCode::MalformedMetadata
        | UpdateFailureCode::DuplicateRelease
        | UpdateFailureCode::UnsupportedReleaseLine
        | UpdateFailureCode::UnexpectedHost
        | UpdateFailureCode::MissingArtifact
        | UpdateFailureCode::AmbiguousArtifact
        | UpdateFailureCode::InvalidArtifactMetadata => {
            "The signed release metadata could not be accepted."
        }
        UpdateFailureCode::PartialDownload => "The update download did not finish.",
        UpdateFailureCode::ArtifactTooLarge => "The update exceeded the allowed size.",
        UpdateFailureCode::ChecksumMismatch
        | UpdateFailureCode::SignatureMismatch
        | UpdateFailureCode::NotarizationMissing
        | UpdateFailureCode::BundleMismatch
        | UpdateFailureCode::SupportMismatch
        | UpdateFailureCode::SupplyChainMismatch => {
            "The update did not pass Wrenflow verification and was not installed."
        }
        UpdateFailureCode::StagingFailed | UpdateFailureCode::AtomicSwapFailed => {
            "The verified update could not be installed atomically."
        }
        UpdateFailureCode::RecoveryRequired => {
            "Update recovery is required before another install."
        }
        UpdateFailureCode::UnsupportedInstallation => {
            "This installation cannot update itself. Reinstall the current signed GPUI line."
        }
    }
}

const fn support_failure_copy(code: SupportBundleFailureCode) -> &'static str {
    match code {
        SupportBundleFailureCode::DiagnosticsUnavailable => {
            "Diagnostics are not available for export yet."
        }
        SupportBundleFailureCode::InvalidDiagnostics => {
            "Diagnostics failed the redaction or schema check."
        }
        SupportBundleFailureCode::SizeLimit => "The support bundle exceeded its size limit.",
        SupportBundleFailureCode::StorageUnavailable => "The support bundle could not be written.",
    }
}

#[cfg(test)]
mod tests {
    use wrenflow_runtime::{
        recovery::RecoveryMode, support::SupportBundleFailureCode, update::UpdateChannel,
    };

    use crate::app::{
        AboutPresentation, AppAction, DiagnosticPresentation, RecoveryPresentation,
        SupportBundlePresentation, UpdatePresentation,
    };
    use crate::screens::common::{BlockPlan, ControlPlan, ScreenIntent, ScreenLayout};

    use super::project;

    fn about(update: UpdatePresentation) -> AboutPresentation {
        AboutPresentation {
            version: "0.3.0".to_string(),
            show_updates: true,
            update,
            support_bundle: SupportBundlePresentation::Idle,
            recovery: RecoveryPresentation {
                mode: RecoveryMode::Normal,
                consecutive_unclean_launches: 0,
                cleaned_temporary_files: 0,
                reset_current_data_available: false,
                reinstall_current_line_recommended: false,
            },
            diagnostics: vec![DiagnosticPresentation {
                label: "Runtime".to_string(),
                value: "Ready".to_string(),
                healthy: true,
            }],
        }
    }

    #[test]
    fn available_update_is_url_free_and_downloads_through_a_typed_action() {
        let plan = project(&about(UpdatePresentation::Available {
            latest_version: "0.4.0".to_string(),
            channel: UpdateChannel::Stable,
            published_at_iso: Some("2026-08-09".to_string()),
            size_bytes: 42 * 1_024 * 1_024,
        }));
        assert_eq!(plan.layout, ScreenLayout::Application);
        assert_eq!(plan.brand_version.as_deref(), Some("0.3.0"));
        assert_eq!(
            plan.sections
                .iter()
                .filter_map(|section| section.title.as_deref())
                .collect::<Vec<_>>(),
            ["Updates", "Runtime status", "Support", "Recovery"]
        );
        let BlockPlan::Card(card) = &plan.sections[0].blocks[0] else {
            panic!("available update should project a card");
        };
        assert!(card.lines.iter().any(|line| line.value == "0.4.0"));
        assert!(!format!("{card:?}").contains("http"));
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions) if actions.iter().any(|action|
                action.intent == ScreenIntent::Dispatch(AppAction::DownloadAvailableUpdate)
            )
        )));
    }

    #[test]
    fn idle_update_projection_keeps_the_flutter_compact_row_geometry() {
        let plan = project(&about(UpdatePresentation::Idle));
        let BlockPlan::Card(card) = &plan.sections[0].blocks[0] else {
            panic!("idle update should project a card");
        };
        assert!(card.inline);
        assert!(card.title_inside);
        assert!(card.lines.is_empty());
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions)
                if actions.iter().any(|action| action.label == "Check now")
                    && actions.iter().any(|action| action.label == "Beta")
        )));
    }

    #[test]
    fn destructive_current_data_reset_requires_a_local_confirmation_intent() {
        let mut presentation = about(UpdatePresentation::Idle);
        presentation.recovery.reset_current_data_available = true;
        let plan = project(&presentation);
        let BlockPlan::Card(card) = &plan.sections[3].blocks[0] else {
            panic!("recovery should project a card");
        };
        assert!(card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions) if actions.iter().any(|action|
                action.intent == ScreenIntent::ShowResetCurrentDataConfirmation
            )
        )));
        assert!(!card.controls.iter().any(|control| matches!(
            control,
            ControlPlan::Actions(actions) if actions.iter().any(|action|
                action.intent == ScreenIntent::Dispatch(AppAction::ResetCurrentData)
            )
        )));
    }

    #[test]
    fn support_failure_uses_closed_copy_and_a_typed_retry() {
        let mut presentation = about(UpdatePresentation::Idle);
        presentation.support_bundle = SupportBundlePresentation::Error {
            code: SupportBundleFailureCode::InvalidDiagnostics,
        };
        let plan = project(&presentation);
        let BlockPlan::Status { detail, action, .. } = &plan.sections[2].blocks[0] else {
            panic!("support failure should project status");
        };
        assert!(detail.as_deref().is_some_and(|copy| !copy.contains('/')));
        assert_eq!(
            action.as_ref().map(|action| &action.intent),
            Some(&ScreenIntent::Dispatch(AppAction::ExportSupportBundle))
        );
    }
}

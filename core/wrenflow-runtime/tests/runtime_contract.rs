use std::time::Duration;

use wrenflow_runtime::{
    start_runtime, AppSessionState, CommandOutcome, OnboardingStep, PermissionStatus,
    PermissionsSnapshot, RuntimeBootstrap, RuntimeCommand, RuntimeError, RuntimeEvent,
    RuntimePhase, SettingsPatch, TranscriptDisposition,
};

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn granted_permissions() -> PermissionsSnapshot {
    PermissionsSnapshot {
        has_snapshot: true,
        microphone: PermissionStatus::Granted,
        accessibility: PermissionStatus::Granted,
    }
}

#[test]
fn starting_without_tokio_is_an_explicit_error() {
    let error = match start_runtime(RuntimeBootstrap::default()) {
        Ok(_) => panic!("runtime unexpectedly started without Tokio"),
        Err(error) => error,
    };
    assert!(matches!(error, RuntimeError::NoAsyncRuntime));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn subscribers_immediately_receive_a_complete_initial_snapshot() -> TestResult {
    let instance = start_runtime(RuntimeBootstrap::default())?;
    let snapshot = instance.handle.snapshot();

    assert_eq!(snapshot.revision, 0);
    assert_eq!(snapshot.phase, RuntimePhase::Running);
    assert!(matches!(snapshot.session, AppSessionState::Initializing));
    assert!(!snapshot.models.models.is_empty());
    assert_eq!(*instance.handle.subscribe_audio_level().borrow(), 0.0);

    instance.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn command_ack_follows_snapshot_publication_and_revisions_are_monotonic() -> TestResult {
    let mut bootstrap = RuntimeBootstrap::default();
    bootstrap.initial_config.has_completed_setup = true;
    let instance = start_runtime(bootstrap)?;
    let mut snapshots = instance.handle.subscribe_snapshots();

    let first = instance
        .handle
        .request(RuntimeCommand::ReportPermissions(granted_permissions()))
        .await?;
    assert_eq!(first, CommandOutcome::Applied { revision: 1 });
    snapshots.changed().await?;
    assert_eq!(snapshots.borrow().revision, 1);
    assert!(matches!(snapshots.borrow().session, AppSessionState::Ready));

    let second = instance
        .handle
        .request(RuntimeCommand::SetTranscriptDisposition(
            TranscriptDisposition::Paste,
        ))
        .await?;
    assert_eq!(second, CommandOutcome::Applied { revision: 2 });
    assert_eq!(instance.handle.snapshot().revision, 2);

    let unchanged = instance
        .handle
        .request(RuntimeCommand::SetTranscriptDisposition(
            TranscriptDisposition::Paste,
        ))
        .await?;
    assert_eq!(unchanged, CommandOutcome::NoChange { revision: 2 });

    instance.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn onboarding_and_settings_use_typed_runtime_state() -> TestResult {
    let instance = start_runtime(RuntimeBootstrap::default())?;

    instance
        .handle
        .request(RuntimeCommand::ReportPermissions(granted_permissions()))
        .await?;
    assert!(matches!(
        instance.handle.snapshot().session,
        AppSessionState::Onboarding {
            step: OnboardingStep::Hotkey
        }
    ));

    instance
        .handle
        .request(RuntimeCommand::AdvanceOnboarding)
        .await?;
    assert!(matches!(
        instance.handle.snapshot().session,
        AppSessionState::Onboarding {
            step: OnboardingStep::Model
        }
    ));

    instance
        .handle
        .request(RuntimeCommand::UpdateSettings(
            SettingsPatch::MinimumRecordingDuration(Duration::from_millis(450)),
        ))
        .await?;
    assert_eq!(
        instance
            .handle
            .snapshot()
            .settings
            .minimum_recording_duration_ms,
        450.0
    );

    instance
        .handle
        .request(RuntimeCommand::UpdateSettings(
            SettingsPatch::HasCompletedSetup(true),
        ))
        .await?;
    assert!(matches!(
        instance.handle.snapshot().session,
        AppSessionState::Ready
    ));

    instance.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn quit_is_an_ordered_event_while_shutdown_is_cooperative() -> TestResult {
    let instance = start_runtime(RuntimeBootstrap::default())?;
    let mut events = instance.handle.subscribe_events();

    instance.handle.request(RuntimeCommand::RequestQuit).await?;
    let event = events.recv().await?;
    assert_eq!(event.sequence, 1);
    assert_eq!(event.event, RuntimeEvent::QuitRequested);
    assert!(matches!(
        instance.handle.snapshot().session,
        AppSessionState::ShuttingDown
    ));

    instance.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unwired_subsystems_fail_honestly_without_advancing_state() -> TestResult {
    let instance = start_runtime(RuntimeBootstrap::default())?;

    let error = match instance
        .handle
        .request(RuntimeCommand::ActivateSelectedModel)
        .await
    {
        Ok(outcome) => panic!("unwired models subsystem returned {outcome:?}"),
        Err(error) => error,
    };
    assert!(matches!(
        error,
        RuntimeError::SubsystemUnavailable("models")
    ));
    assert_eq!(instance.handle.snapshot().revision, 0);

    instance.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ready_session_requires_three_missing_permission_observations() -> TestResult {
    let mut bootstrap = RuntimeBootstrap::default();
    bootstrap.initial_config.has_completed_setup = true;
    let instance = start_runtime(bootstrap)?;
    instance
        .handle
        .request(RuntimeCommand::ReportPermissions(granted_permissions()))
        .await?;

    let missing = PermissionsSnapshot {
        has_snapshot: true,
        microphone: PermissionStatus::Denied,
        accessibility: PermissionStatus::Granted,
    };
    for _ in 0..2 {
        instance
            .handle
            .request(RuntimeCommand::ReportPermissions(missing.clone()))
            .await?;
        assert!(matches!(
            instance.handle.snapshot().session,
            AppSessionState::Ready
        ));
    }
    instance
        .handle
        .request(RuntimeCommand::ReportPermissions(missing))
        .await?;
    assert!(matches!(
        instance.handle.snapshot().session,
        AppSessionState::PermissionRecovery {
            microphone_missing: true,
            accessibility_missing: false
        }
    ));

    instance.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn permission_poll_does_not_reset_later_onboarding_steps() -> TestResult {
    let instance = start_runtime(RuntimeBootstrap::default())?;
    instance
        .handle
        .request(RuntimeCommand::ReportPermissions(granted_permissions()))
        .await?;
    instance
        .handle
        .request(RuntimeCommand::AdvanceOnboarding)
        .await?;
    assert!(matches!(
        instance.handle.snapshot().session,
        AppSessionState::Onboarding {
            step: OnboardingStep::Model
        }
    ));

    instance
        .handle
        .request(RuntimeCommand::ReportPermissions(granted_permissions()))
        .await?;
    assert!(matches!(
        instance.handle.snapshot().session,
        AppSessionState::Onboarding {
            step: OnboardingStep::Model
        }
    ));

    instance.shutdown().await?;
    Ok(())
}

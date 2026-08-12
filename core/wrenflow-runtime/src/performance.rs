//! Private, two-gate signed-app performance workload.
//!
//! This is deliberately not a `RuntimeCommand`: ordinary UI actions cannot
//! construct the prepared request or enter the fixture path.

use std::ffi::OsString;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::{mpsc, oneshot};
use wrenflow_core::history_store::HistoryStore;
use wrenflow_core::model_downloader;
use wrenflow_core::model_management::local_model_by_id;
use wrenflow_domain::config::DEFAULT_SELECTED_LOCAL_MODEL_ID;
use wrenflow_domain::history::HistoryEntry;

use crate::data_paths::CurrentDataPaths;
use crate::diagnostics::{
    current_session_id, emit_diagnostic, new_correlation_id, DiagnosticCategory, DiagnosticCode,
    DiagnosticEvent, DiagnosticLevel,
};
use crate::history::HistoryHandle;
use crate::model::ModelHandle;
use crate::state::{ModelOperationState, TranscriptDisposition};
use crate::store::RuntimeStore;
use crate::RuntimeError;

pub const PERFORMANCE_CONTRACT: &str = "gpui-performance-v1";
pub const PERFORMANCE_ARGUMENT: &str = "--performance-self-test";
pub const PERFORMANCE_INTERACTION: &str = "synthetic-in-process-v1";
pub const PERFORMANCE_FIXTURE_SHA256: &str =
    "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e";
pub const PERFORMANCE_FIXTURE_BYTES: usize = 352_078;
pub const PERFORMANCE_FIXTURE_ID: &str = "whispercpp-jfk-pcm16-v1";
pub const PERFORMANCE_MODEL_REVISION: &str = "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce";

const CONTRACT_ENV: &str = "WRENFLOW_PERFORMANCE_SELF_TEST";
const INTERACTION_ENV: &str = "WRENFLOW_PERFORMANCE_INTERACTION";
const FIXTURE_ENV: &str = "WRENFLOW_PERFORMANCE_FIXTURE";
const DATA_ROOT_ENV: &str = "WRENFLOW_PERFORMANCE_DATA_ROOT";
const REJECTED_REPORT_ENV: &str = "WRENFLOW_PERFORMANCE_REPORT";
const REPORT_NAME: &str = "performance-self-test-v1.json";
const START_SIGNAL_NAME: &str = "performance-start-v1";
const OBSERVER_ACK_NAME: &str = "performance-observer-ack-v1";
const INTERACTION_READY_NAME: &str = "performance-interaction-ready-v1";
const INTERACTION_REPORT_NAME: &str = "performance-interaction-v1.json";
const CYCLE_COUNT: usize = 20;
const HISTORY_COUNT: usize = 50;
// The signed observer may hold the exact two-gate process at its start signal
// while collecting the bounded 30-minute idle phase. The sampler's hard
// cadence deadline is 37.5 minutes plus two seconds, so retain a fail-closed
// margin without approaching the independent 90-minute workload deadline.
const START_TIMEOUT: Duration = Duration::from_secs(45 * 60);
const START_SIGNAL_RECHECK: Duration = Duration::from_secs(2);
const MODEL_TIMEOUT: Duration = Duration::from_secs(45 * 60);
const TOTAL_TIMEOUT: Duration = Duration::from_secs(90 * 60);
const CYCLE_SETTLE: Duration = Duration::from_secs(1);
const INTERACTION_TIMEOUT: Duration = Duration::from_secs(3 * 60);
const OBSERVER_ACK_TIMEOUT: Duration = Duration::from_secs(60);
const INTERACTION_REPORT_MAX_BYTES: u64 = 64 * 1024;
const INTERACTION_PULSE_COUNT: usize = 20;
const INTERACTION_KEY_CODE: u16 = 96;
const INTERACTION_HOLD_REQUESTED_MS: u64 = 60_000;
const INTERACTION_HOLD_MAX_MS: f64 = 65_000.0;
const INTERACTION_DISPOSITION_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PerformanceGateError {
    GateMismatch,
    UnsafeFixture,
    UnsafeDataRoot,
    FixtureDigest,
    FixtureFormat,
    RootOverrideUnavailable,
    SyntheticSourceUnavailable,
}

impl PerformanceGateError {
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::GateMismatch => "performance_gate_mismatch",
            Self::UnsafeFixture => "performance_fixture_unsafe",
            Self::UnsafeDataRoot => "performance_data_root_unsafe",
            Self::FixtureDigest => "performance_fixture_digest",
            Self::FixtureFormat => "performance_fixture_format",
            Self::RootOverrideUnavailable => "performance_root_override_unavailable",
            Self::SyntheticSourceUnavailable => "performance_synthetic_source_unavailable",
        }
    }
}

#[derive(Clone)]
struct FixtureMetadata {
    samples: Arc<Vec<f32>>,
}

/// Opaque validated input. Its fields cannot be constructed by the app UI.
pub struct PerformanceSelfTestRequest {
    data_root: PathBuf,
    report_path: PathBuf,
    start_signal_path: PathBuf,
    observer_ack_path: PathBuf,
    fixture: FixtureMetadata,
    interaction_paths: Option<PerformanceInteractionPaths>,
}

/// Opaque canonical paths made available only from a successfully prepared
/// two-gate request. The native shell can clone these without gaining access
/// to the fixture or production data-root override.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PerformanceInteractionPaths {
    ready_signal_path: PathBuf,
    report_path: PathBuf,
}

impl PerformanceInteractionPaths {
    #[must_use]
    pub fn ready_path(&self) -> &Path {
        &self.ready_signal_path
    }

    #[must_use]
    pub fn report_path(&self) -> &Path {
        &self.report_path
    }
}

impl PerformanceSelfTestRequest {
    /// Return the private interaction handshake only when the optional exact
    /// selector was validated together with both existing launch gates.
    #[must_use]
    pub fn interaction_driver_paths(&self) -> Option<PerformanceInteractionPaths> {
        self.interaction_paths.clone()
    }
}

#[derive(Clone, Debug, Default)]
struct ProcessInputs {
    contract: Option<OsString>,
    interaction: Option<OsString>,
    fixture: Option<OsString>,
    data_root: Option<OsString>,
    rejected_report: Option<OsString>,
    unknown_performance_env: bool,
}

impl ProcessInputs {
    fn production() -> Self {
        let unknown_performance_env = std::env::vars_os().any(|(key, _)| {
            key.to_str().is_some_and(|key| {
                key.starts_with("WRENFLOW_PERFORMANCE_")
                    && !matches!(
                        key,
                        CONTRACT_ENV
                            | INTERACTION_ENV
                            | FIXTURE_ENV
                            | DATA_ROOT_ENV
                            | REJECTED_REPORT_ENV
                    )
            })
        });
        Self {
            contract: std::env::var_os(CONTRACT_ENV),
            interaction: std::env::var_os(INTERACTION_ENV),
            fixture: std::env::var_os(FIXTURE_ENV),
            data_root: std::env::var_os(DATA_ROOT_ENV),
            rejected_report: std::env::var_os(REJECTED_REPORT_ENV),
            unknown_performance_env,
        }
    }

    fn any_present(&self) -> bool {
        self.contract.is_some()
            || self.interaction.is_some()
            || self.fixture.is_some()
            || self.data_root.is_some()
            || self.rejected_report.is_some()
            || self.unknown_performance_env
    }
}

/// Validate both independent gates and install the disposable data root before
/// diagnostics, recovery, updater or the runtime can resolve a production path.
pub fn prepare_performance_self_test(
    arguments: &[String],
) -> Result<Option<PerformanceSelfTestRequest>, PerformanceGateError> {
    let inputs = ProcessInputs::production();
    if !has_performance_surface(arguments, &inputs) {
        return Ok(None);
    }
    validate_gate(arguments, &inputs)?;
    let interaction_selected = inputs
        .interaction
        .as_ref()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value == PERFORMANCE_INTERACTION);

    let fixture = inputs
        .fixture
        .and_then(|value| value.into_string().ok())
        .map(PathBuf::from)
        .ok_or(PerformanceGateError::GateMismatch)?;
    let data_root = inputs
        .data_root
        .and_then(|value| value.into_string().ok())
        .map(PathBuf::from)
        .ok_or(PerformanceGateError::GateMismatch)?;
    validate_fixture_path(&fixture)?;
    validate_empty_root(&data_root)?;
    let fixture = read_fixture(&fixture)?;
    crate::data_paths::install_current_data_base_override(data_root.clone())
        .map_err(|()| PerformanceGateError::RootOverrideUnavailable)?;
    if interaction_selected {
        crate::pipeline::install_performance_synthetic_recording(fixture.samples.clone())
            .map_err(|()| PerformanceGateError::SyntheticSourceUnavailable)?;
    }
    let interaction_paths = interaction_selected.then(|| PerformanceInteractionPaths {
        ready_signal_path: data_root.join(INTERACTION_READY_NAME),
        report_path: data_root.join(INTERACTION_REPORT_NAME),
    });
    Ok(Some(PerformanceSelfTestRequest {
        report_path: data_root.join(REPORT_NAME),
        start_signal_path: data_root.join(START_SIGNAL_NAME),
        observer_ack_path: data_root.join(OBSERVER_ACK_NAME),
        data_root,
        fixture,
        interaction_paths,
    }))
}

fn has_performance_surface(arguments: &[String], inputs: &ProcessInputs) -> bool {
    arguments
        .iter()
        .any(|argument| argument.starts_with("--performance-"))
        || inputs.any_present()
}

fn validate_gate(arguments: &[String], inputs: &ProcessInputs) -> Result<(), PerformanceGateError> {
    let exact_arguments = arguments.len() == 2
        && arguments
            .get(1)
            .is_some_and(|argument| argument == PERFORMANCE_ARGUMENT);
    let exact_contract =
        inputs.contract.as_ref().and_then(|value| value.to_str()) == Some(PERFORMANCE_CONTRACT);
    let valid_interaction = inputs
        .interaction
        .as_ref()
        .is_none_or(|value| value.to_str() == Some(PERFORMANCE_INTERACTION));
    if !exact_arguments
        || !exact_contract
        || !valid_interaction
        || inputs.fixture.is_none()
        || inputs.data_root.is_none()
        || inputs.rejected_report.is_some()
        || inputs.unknown_performance_env
    {
        return Err(PerformanceGateError::GateMismatch);
    }
    Ok(())
}

fn validate_fixture_path(path: &Path) -> Result<(), PerformanceGateError> {
    if !path.is_absolute() {
        return Err(PerformanceGateError::UnsafeFixture);
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| PerformanceGateError::UnsafeFixture)?;
    if metadata.file_type().is_symlink()
        || !metadata.file_type().is_file()
        || metadata.len() != PERFORMANCE_FIXTURE_BYTES as u64
    {
        return Err(PerformanceGateError::UnsafeFixture);
    }
    Ok(())
}

fn validate_empty_root(path: &Path) -> Result<(), PerformanceGateError> {
    if !path.is_absolute() {
        return Err(PerformanceGateError::UnsafeDataRoot);
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| PerformanceGateError::UnsafeDataRoot)?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
        return Err(PerformanceGateError::UnsafeDataRoot);
    }
    let mut entries = fs::read_dir(path).map_err(|_| PerformanceGateError::UnsafeDataRoot)?;
    if entries.next().is_some() {
        return Err(PerformanceGateError::UnsafeDataRoot);
    }
    Ok(())
}

fn read_fixture(path: &Path) -> Result<FixtureMetadata, PerformanceGateError> {
    let bytes = fs::read(path).map_err(|_| PerformanceGateError::UnsafeFixture)?;
    if bytes.len() != PERFORMANCE_FIXTURE_BYTES {
        return Err(PerformanceGateError::UnsafeFixture);
    }
    let digest = format!("{:x}", Sha256::digest(&bytes));
    if digest != PERFORMANCE_FIXTURE_SHA256 {
        return Err(PerformanceGateError::FixtureDigest);
    }
    let samples = parse_pcm16_mono_16khz(&bytes)?;
    Ok(FixtureMetadata {
        samples: Arc::new(samples),
    })
}

fn parse_pcm16_mono_16khz(bytes: &[u8]) -> Result<Vec<f32>, PerformanceGateError> {
    if bytes.get(0..4) != Some(b"RIFF") || bytes.get(8..12) != Some(b"WAVE") {
        return Err(PerformanceGateError::FixtureFormat);
    }
    let mut offset = 12_usize;
    let mut format = None;
    let mut data = None;
    while offset.saturating_add(8) <= bytes.len() {
        let id = bytes
            .get(offset..offset + 4)
            .ok_or(PerformanceGateError::FixtureFormat)?;
        let length_bytes = bytes
            .get(offset + 4..offset + 8)
            .ok_or(PerformanceGateError::FixtureFormat)?;
        let length = u32::from_le_bytes([
            length_bytes[0],
            length_bytes[1],
            length_bytes[2],
            length_bytes[3],
        ]) as usize;
        let start = offset + 8;
        let end = start
            .checked_add(length)
            .ok_or(PerformanceGateError::FixtureFormat)?;
        let chunk = bytes
            .get(start..end)
            .ok_or(PerformanceGateError::FixtureFormat)?;
        if id == b"fmt " {
            if chunk.len() < 16 {
                return Err(PerformanceGateError::FixtureFormat);
            }
            format = Some((
                u16::from_le_bytes([chunk[0], chunk[1]]),
                u16::from_le_bytes([chunk[2], chunk[3]]),
                u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]),
                u16::from_le_bytes([chunk[14], chunk[15]]),
            ));
        } else if id == b"data" {
            data = Some(chunk);
        }
        offset = end.saturating_add(length % 2);
    }
    if format != Some((1, 1, 16_000, 16)) {
        return Err(PerformanceGateError::FixtureFormat);
    }
    let data = data.ok_or(PerformanceGateError::FixtureFormat)?;
    if data.len() != 352_000 {
        return Err(PerformanceGateError::FixtureFormat);
    }
    let samples = data
        .chunks_exact(2)
        .map(|sample| f32::from(i16::from_le_bytes([sample[0], sample[1]])) / 32_768.0)
        .collect::<Vec<_>>();
    if samples.len() != 176_000 {
        return Err(PerformanceGateError::FixtureFormat);
    }
    Ok(samples)
}

pub(crate) struct PerformanceRuntimeRequest {
    pub(crate) request: PerformanceSelfTestRequest,
    pub(crate) completion: oneshot::Sender<Result<(), RuntimeError>>,
}

pub(crate) fn channel() -> (
    mpsc::Sender<PerformanceRuntimeRequest>,
    mpsc::Receiver<PerformanceRuntimeRequest>,
) {
    mpsc::channel(1)
}

pub(crate) fn start(
    mut receiver: mpsc::Receiver<PerformanceRuntimeRequest>,
    models: Option<ModelHandle>,
    history: Option<HistoryHandle>,
    store: RuntimeStore,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let Some(request) = receiver.recv().await else {
            return;
        };
        let result = execute(request.request, models, history, store).await;
        let _ = request.completion.send(result);
    })
}

async fn execute(
    request: PerformanceSelfTestRequest,
    models: Option<ModelHandle>,
    history: Option<HistoryHandle>,
    store: RuntimeStore,
) -> Result<(), RuntimeError> {
    emit_marker(DiagnosticCode::PerformanceSelfTestStarted);
    emit_marker(DiagnosticCode::PerformanceSelfTestFixtureVerified);
    let started_at = unix_ms();
    let result = tokio::time::timeout(
        TOTAL_TIMEOUT,
        execute_bounded(&request, models, history, store, started_at),
    )
    .await;
    match result {
        Ok(Ok(report)) => {
            write_report(&request.report_path, &report)?;
            emit_marker(DiagnosticCode::PerformanceSelfTestCompleted);
            Ok(())
        }
        Ok(Err(code)) => {
            let report = failure_report(&request, started_at, code);
            let _ = write_report(&request.report_path, &report);
            emit_marker(DiagnosticCode::PerformanceSelfTestFailed);
            Err(performance_error(code.as_str()))
        }
        Err(_) => {
            let report = failure_report(&request, started_at, PerformanceFailureCode::TimedOut);
            let _ = write_report(&request.report_path, &report);
            emit_marker(DiagnosticCode::PerformanceSelfTestTimedOut);
            Err(performance_error(PerformanceFailureCode::TimedOut.as_str()))
        }
    }
}

async fn execute_bounded(
    request: &PerformanceSelfTestRequest,
    models: Option<ModelHandle>,
    history: Option<HistoryHandle>,
    store: RuntimeStore,
    process_started_at: u64,
) -> Result<PerformanceReport, PerformanceFailureCode> {
    let models = models.ok_or(PerformanceFailureCode::RuntimeUnavailable)?;
    let history = history.ok_or(PerformanceFailureCode::RuntimeUnavailable)?;
    require_missing_observer_ack(&request.observer_ack_path)?;
    let ready_at = unix_ms_after(process_started_at);
    emit_marker(DiagnosticCode::PerformanceSelfTestReady);
    wait_for_start_signal(&request.start_signal_path).await?;
    let started_at = unix_ms_after(ready_at);

    for index in 0..HISTORY_COUNT {
        history
            .insert_acknowledged(HistoryEntry {
                id: format!("performance-{index:02}"),
                timestamp: index as f64,
                transcript: String::new(),
                custom_vocabulary: String::new(),
                audio_file_name: None,
                metrics_json: "{}".to_string(),
            })
            .await
            .map_err(|_| PerformanceFailureCode::HistoryInsert)?;
    }
    let paths = CurrentDataPaths::under(&request.data_root);
    verify_history(&paths.history)?;
    let history_ready_at = unix_ms_after(started_at);
    emit_marker(DiagnosticCode::PerformanceSelfTestHistoryReady);

    let model_timings = activate_model(&models, &store, history_ready_at).await?;
    let transcription = models.transcription();
    transcription
        .transcribe(request.fixture.samples.as_ref().clone(), String::new())
        .await
        .map_err(|_| PerformanceFailureCode::Warmup)?;
    let warmup_completed_at = unix_ms_after(model_timings.model_ready_at_unix_ms);

    let mut cycle_ms = Vec::with_capacity(CYCLE_COUNT);
    for _ in 0..CYCLE_COUNT {
        let correlation = new_correlation_id();
        emit_diagnostic(
            DiagnosticEvent::new(
                DiagnosticCategory::Transcription,
                DiagnosticLevel::Info,
                DiagnosticCode::TranscriptionStarted,
            )
            .correlated(&correlation),
        );
        let started = Instant::now();
        transcription
            .transcribe(request.fixture.samples.as_ref().clone(), String::new())
            .await
            .map_err(|_| PerformanceFailureCode::Transcription)?;
        cycle_ms.push(started.elapsed().as_secs_f64() * 1_000.0);
        emit_diagnostic(
            DiagnosticEvent::new(
                DiagnosticCategory::Transcription,
                DiagnosticLevel::Info,
                DiagnosticCode::TranscriptionCompleted,
            )
            .correlated(&correlation),
        );
        tokio::time::sleep(CYCLE_SETTLE).await;
    }

    wait_for_observer_ack(&request.observer_ack_path).await?;

    if let Some(paths) = &request.interaction_paths {
        wait_for_paste_disposition(&store).await?;
        require_missing_interaction_report(&paths.report_path)?;
        publish_interaction_ready(&paths.ready_signal_path)?;
        wait_for_interaction_report(&paths.report_path).await?;
    }

    let completed_at = unix_ms_after(warmup_completed_at);
    let timeline = SelfTestTimeline {
        process_started_at_unix_ms: process_started_at,
        ready_at_unix_ms: ready_at,
        started_at_unix_ms: started_at,
        history_ready_at_unix_ms: history_ready_at,
        activation_started_at_unix_ms: model_timings.activation_started_at_unix_ms,
        loading_started_at_unix_ms: model_timings.loading_started_at_unix_ms,
        model_ready_at_unix_ms: model_timings.model_ready_at_unix_ms,
        warmup_completed_at_unix_ms: warmup_completed_at,
        completed_at_unix_ms: completed_at,
    };
    Ok(PerformanceReport::passed(timeline, model_timings, cycle_ms))
}

async fn wait_for_paste_disposition(store: &RuntimeStore) -> Result<(), PerformanceFailureCode> {
    let deadline = Instant::now() + INTERACTION_DISPOSITION_TIMEOUT;
    loop {
        if store.snapshot().transcript_disposition == TranscriptDisposition::Paste {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(PerformanceFailureCode::InteractionDisposition);
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn require_missing_interaction_report(path: &Path) -> Result<(), PerformanceFailureCode> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(PerformanceFailureCode::UnsafeInteractionReport),
    }
}

fn publish_interaction_ready(path: &Path) -> Result<(), PerformanceFailureCode> {
    let parent = path
        .parent()
        .ok_or(PerformanceFailureCode::InteractionReadyPublish)?;
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        _ => return Err(PerformanceFailureCode::InteractionReadyPublish),
    }
    let temporary = parent.join(format!(
        ".{INTERACTION_READY_NAME}.tmp-{}",
        std::process::id()
    ));
    let result = (|| {
        let file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|_| PerformanceFailureCode::InteractionReadyPublish)?;
        file.sync_all()
            .map_err(|_| PerformanceFailureCode::InteractionReadyPublish)?;
        fs::rename(&temporary, path)
            .map_err(|_| PerformanceFailureCode::InteractionReadyPublish)?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| PerformanceFailureCode::InteractionReadyPublish)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

async fn wait_for_interaction_report(path: &Path) -> Result<(), PerformanceFailureCode> {
    let deadline = Instant::now() + INTERACTION_TIMEOUT;
    loop {
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink()
                    || !metadata.file_type().is_file()
                    || metadata.len() == 0
                    || metadata.len() > INTERACTION_REPORT_MAX_BYTES
                {
                    return Err(PerformanceFailureCode::UnsafeInteractionReport);
                }
                let data =
                    fs::read(path).map_err(|_| PerformanceFailureCode::UnsafeInteractionReport)?;
                let report: InteractionReport = serde_json::from_slice(&data)
                    .map_err(|_| PerformanceFailureCode::InvalidInteractionReport)?;
                return validate_interaction_report(&report);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(PerformanceFailureCode::UnsafeInteractionReport),
        }
        if Instant::now() >= deadline {
            return Err(PerformanceFailureCode::InteractionTimeout);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct InteractionReport {
    schema_version: u16,
    classification: InteractionClassification,
    source: InteractionSource,
    key_code: u16,
    pulses: InteractionPulses,
    hold: InteractionHold,
    tcc_or_microphone_evidence: bool,
    passed: bool,
    #[serde(default)]
    failure_code: Option<InteractionFailureCode>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum InteractionClassification {
    PostEventTapSynthetic,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum InteractionSource {
    SignedWrenflowTypedHotkeyCallback,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct InteractionPulses {
    requested: usize,
    completed: usize,
    overlay_ms: Vec<f64>,
    paste_dispatch_ms: Vec<f64>,
    generation_uptime_ms: Vec<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct InteractionHold {
    requested_ms: u64,
    observed_ms: f64,
    overlay_ms: f64,
    paste_dispatch_ms: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum InteractionFailureCode {
    UnsafeInteractionPath,
    InteractionReadyTimeout,
    InteractionTargetUnavailable,
    TypedHotkeyDownFailed,
    TypedHotkeyUpFailed,
    InteractionHoldTooShort,
    InteractionCycleTimeout,
    InteractionIncomplete,
}

fn validate_interaction_report(report: &InteractionReport) -> Result<(), PerformanceFailureCode> {
    let pulses = &report.pulses;
    let hold = &report.hold;
    let pulses_valid = pulses.requested == INTERACTION_PULSE_COUNT
        && pulses.completed == INTERACTION_PULSE_COUNT
        && positive_finite_samples(&pulses.overlay_ms, INTERACTION_PULSE_COUNT)
        && positive_finite_samples(&pulses.paste_dispatch_ms, INTERACTION_PULSE_COUNT)
        && positive_finite_samples(&pulses.generation_uptime_ms, INTERACTION_PULSE_COUNT);
    let hold_valid = hold.requested_ms == INTERACTION_HOLD_REQUESTED_MS
        && hold.observed_ms.is_finite()
        && hold.observed_ms >= INTERACTION_HOLD_REQUESTED_MS as f64
        && hold.observed_ms <= INTERACTION_HOLD_MAX_MS
        && positive_finite(hold.overlay_ms)
        && positive_finite(hold.paste_dispatch_ms);
    if report.schema_version != 1
        || report.classification != InteractionClassification::PostEventTapSynthetic
        || report.source != InteractionSource::SignedWrenflowTypedHotkeyCallback
        || report.key_code != INTERACTION_KEY_CODE
        || !pulses_valid
        || !hold_valid
        || report.tcc_or_microphone_evidence
        || !report.passed
        || report.failure_code.is_some()
    {
        return Err(PerformanceFailureCode::InvalidInteractionReport);
    }
    Ok(())
}

fn positive_finite_samples(samples: &[f64], exact_count: usize) -> bool {
    samples.len() == exact_count && samples.iter().copied().all(positive_finite)
}

fn positive_finite(value: f64) -> bool {
    value.is_finite() && value > 0.0
}

async fn wait_for_start_signal(path: &Path) -> Result<(), PerformanceFailureCode> {
    let deadline = Instant::now() + START_TIMEOUT;
    loop {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_file() && metadata.len() == 0 => return Ok(()),
            Ok(_) => return Err(PerformanceFailureCode::UnsafeStartSignal),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(PerformanceFailureCode::UnsafeStartSignal),
        }
        if Instant::now() >= deadline {
            return Err(PerformanceFailureCode::StartTimeout);
        }
        // This private gate remains absent for the complete 30-minute idle
        // phase. A bounded low-rate recheck avoids manufacturing ten wakeups
        // per second in the very residency measurement it controls.
        tokio::time::sleep(START_SIGNAL_RECHECK).await;
    }
}

fn require_missing_observer_ack(path: &Path) -> Result<(), PerformanceFailureCode> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(PerformanceFailureCode::UnsafeObserverAck),
    }
}

async fn wait_for_observer_ack(path: &Path) -> Result<(), PerformanceFailureCode> {
    wait_for_observer_ack_with_timeout(path, OBSERVER_ACK_TIMEOUT).await
}

async fn wait_for_observer_ack_with_timeout(
    path: &Path,
    timeout: Duration,
) -> Result<(), PerformanceFailureCode> {
    let deadline = Instant::now() + timeout;
    loop {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_file() && metadata.len() == 0 => return Ok(()),
            Ok(_) => return Err(PerformanceFailureCode::UnsafeObserverAck),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(PerformanceFailureCode::UnsafeObserverAck),
        }
        if Instant::now() >= deadline {
            return Err(PerformanceFailureCode::ObserverAckTimeout);
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

struct ModelTimings {
    activation_started_at_unix_ms: u64,
    loading_started_at_unix_ms: u64,
    model_ready_at_unix_ms: u64,
    download_ms: f64,
    cold_load_ms: f64,
}

async fn activate_model(
    models: &ModelHandle,
    store: &RuntimeStore,
    history_ready_at: u64,
) -> Result<ModelTimings, PerformanceFailureCode> {
    let descriptor = local_model_by_id(DEFAULT_SELECTED_LOCAL_MODEL_ID)
        .ok_or(PerformanceFailureCode::ModelIdentity)?;
    if descriptor.revision != PERFORMANCE_MODEL_REVISION {
        return Err(PerformanceFailureCode::ModelIdentity);
    }
    let directory = crate::model::model_dir_for(DEFAULT_SELECTED_LOCAL_MODEL_ID)
        .ok_or(PerformanceFailureCode::ModelIdentity)?;
    if model_downloader::is_model_present(&descriptor, &directory) {
        return Err(PerformanceFailureCode::ModelRootNotEmpty);
    }

    let activation_started = Instant::now();
    let activation_started_at_unix_ms = unix_ms_after(history_ready_at);
    models
        .activate_selected()
        .await
        .map_err(|_| PerformanceFailureCode::ModelActivation)?;
    let deadline = Instant::now() + MODEL_TIMEOUT;
    let mut loading_started: Option<(Instant, u64)> = None;
    loop {
        let snapshot = store.snapshot();
        let state = snapshot
            .models
            .model_states
            .iter()
            .find(|state| state.model_id == DEFAULT_SELECTED_LOCAL_MODEL_ID)
            .map(|state| &state.state);
        match state {
            Some(ModelOperationState::Loading | ModelOperationState::Warming) => {
                if loading_started.is_none() {
                    loading_started =
                        Some((Instant::now(), unix_ms_after(activation_started_at_unix_ms)));
                }
            }
            Some(ModelOperationState::Ready)
                if snapshot.models.active_model_id.as_deref()
                    == Some(DEFAULT_SELECTED_LOCAL_MODEL_ID) =>
            {
                let (loading_started, loading_started_at_unix_ms) =
                    loading_started.ok_or(PerformanceFailureCode::ModelTransition)?;
                if !models.transcription().is_ready()
                    || !model_downloader::is_model_present(&descriptor, &directory)
                {
                    return Err(PerformanceFailureCode::ModelActivation);
                }
                let completed = Instant::now();
                let model_ready_at_unix_ms = unix_ms_after(loading_started_at_unix_ms);
                return Ok(ModelTimings {
                    activation_started_at_unix_ms,
                    loading_started_at_unix_ms,
                    model_ready_at_unix_ms,
                    download_ms: loading_started
                        .duration_since(activation_started)
                        .as_secs_f64()
                        * 1_000.0,
                    cold_load_ms: completed.duration_since(loading_started).as_secs_f64() * 1_000.0,
                });
            }
            Some(ModelOperationState::Error { .. }) => {
                return Err(PerformanceFailureCode::ModelActivation);
            }
            Some(ModelOperationState::NotDownloaded | ModelOperationState::Downloading { .. })
            | None => {}
            Some(ModelOperationState::Ready) => {}
        }
        if Instant::now() >= deadline {
            return Err(PerformanceFailureCode::ModelTimeout);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn verify_history(path: &Path) -> Result<(), PerformanceFailureCode> {
    let store = HistoryStore::open(path).map_err(|_| PerformanceFailureCode::HistoryIntegrity)?;
    store
        .integrity_check()
        .map_err(|_| PerformanceFailureCode::HistoryIntegrity)?;
    if store
        .schema_version()
        .map_err(|_| PerformanceFailureCode::HistoryIntegrity)?
        != 1
        || store
            .load_all()
            .map_err(|_| PerformanceFailureCode::HistoryIntegrity)?
            .len()
            != HISTORY_COUNT
    {
        return Err(PerformanceFailureCode::HistoryIntegrity);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PerformanceFailureCode {
    RuntimeUnavailable,
    UnsafeStartSignal,
    StartTimeout,
    UnsafeObserverAck,
    ObserverAckTimeout,
    HistoryInsert,
    HistoryIntegrity,
    ModelIdentity,
    ModelRootNotEmpty,
    ModelActivation,
    ModelTransition,
    ModelTimeout,
    Warmup,
    Transcription,
    InteractionDisposition,
    InteractionReadyPublish,
    UnsafeInteractionReport,
    InvalidInteractionReport,
    InteractionTimeout,
    TimedOut,
}

impl PerformanceFailureCode {
    const fn as_str(self) -> &'static str {
        match self {
            Self::RuntimeUnavailable => "runtime_unavailable",
            Self::UnsafeStartSignal => "unsafe_start_signal",
            Self::StartTimeout => "start_timeout",
            Self::UnsafeObserverAck => "unsafe_observer_ack",
            Self::ObserverAckTimeout => "observer_ack_timeout",
            Self::HistoryInsert => "history_insert_failed",
            Self::HistoryIntegrity => "history_integrity_failed",
            Self::ModelIdentity => "model_identity_failed",
            Self::ModelRootNotEmpty => "model_root_not_empty",
            Self::ModelActivation => "model_activation_failed",
            Self::ModelTransition => "model_transition_failed",
            Self::ModelTimeout => "model_timeout",
            Self::Warmup => "model_warmup_failed",
            Self::Transcription => "transcription_failed",
            Self::InteractionDisposition => "interaction_paste_disposition_unacknowledged",
            Self::InteractionReadyPublish => "interaction_ready_publish_failed",
            Self::UnsafeInteractionReport => "unsafe_interaction_report",
            Self::InvalidInteractionReport => "invalid_interaction_report",
            Self::InteractionTimeout => "interaction_timeout",
            Self::TimedOut => "timed_out",
        }
    }
}

#[derive(Serialize)]
struct PerformanceReport {
    schema_version: u16,
    contract: &'static str,
    fixture: FixtureReport,
    process: ProcessReport,
    session_id: String,
    model: ModelReport,
    requested: CountReport,
    completed: CountReport,
    history: HistoryReport,
    timings: TimingReport,
    quit_requested: bool,
    passed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure_code: Option<&'static str>,
}

#[derive(Serialize)]
struct FixtureReport {
    id: &'static str,
    sha256: &'static str,
    bytes: usize,
    channels: u16,
    sample_rate_hz: u32,
    bits_per_sample: u16,
    duration_ms: u64,
}

#[derive(Serialize)]
struct ProcessReport {
    pid: u32,
}

#[derive(Serialize)]
struct ModelReport {
    id: &'static str,
    revision: &'static str,
    engine_instances: u8,
    warmed: bool,
    downloaded: bool,
}

#[derive(Serialize)]
struct CountReport {
    cycles: usize,
    history_rows: usize,
}

#[derive(Serialize)]
struct HistoryReport {
    schema_version: u16,
    integrity_ok: bool,
}

#[derive(Serialize)]
struct TimingReport {
    ready_at_unix_ms: u64,
    started_at_unix_ms: u64,
    history_ready_at_unix_ms: u64,
    activation_started_at_unix_ms: u64,
    loading_started_at_unix_ms: u64,
    model_ready_at_unix_ms: u64,
    warmup_completed_at_unix_ms: u64,
    completed_at_unix_ms: u64,
    model_download_ms: f64,
    model_cold_load_ms: f64,
    total_ms: f64,
    cycles_ms: Vec<f64>,
}

#[derive(Clone, Copy)]
struct SelfTestTimeline {
    process_started_at_unix_ms: u64,
    ready_at_unix_ms: u64,
    started_at_unix_ms: u64,
    history_ready_at_unix_ms: u64,
    activation_started_at_unix_ms: u64,
    loading_started_at_unix_ms: u64,
    model_ready_at_unix_ms: u64,
    warmup_completed_at_unix_ms: u64,
    completed_at_unix_ms: u64,
}

impl PerformanceReport {
    fn passed(timeline: SelfTestTimeline, model: ModelTimings, cycles_ms: Vec<f64>) -> Self {
        Self {
            schema_version: 1,
            contract: "gpui-performance-self-test-v1",
            fixture: fixture_report(),
            process: ProcessReport {
                pid: std::process::id(),
            },
            session_id: current_session_id().unwrap_or_else(|| "session-unavailable".to_string()),
            model: ModelReport {
                id: DEFAULT_SELECTED_LOCAL_MODEL_ID,
                revision: PERFORMANCE_MODEL_REVISION,
                engine_instances: 1,
                warmed: true,
                downloaded: true,
            },
            requested: CountReport {
                cycles: CYCLE_COUNT,
                history_rows: HISTORY_COUNT,
            },
            completed: CountReport {
                cycles: CYCLE_COUNT,
                history_rows: HISTORY_COUNT,
            },
            history: HistoryReport {
                schema_version: 1,
                integrity_ok: true,
            },
            timings: TimingReport {
                ready_at_unix_ms: timeline.ready_at_unix_ms,
                started_at_unix_ms: timeline.started_at_unix_ms,
                history_ready_at_unix_ms: timeline.history_ready_at_unix_ms,
                activation_started_at_unix_ms: timeline.activation_started_at_unix_ms,
                loading_started_at_unix_ms: timeline.loading_started_at_unix_ms,
                model_ready_at_unix_ms: timeline.model_ready_at_unix_ms,
                warmup_completed_at_unix_ms: timeline.warmup_completed_at_unix_ms,
                completed_at_unix_ms: timeline.completed_at_unix_ms,
                model_download_ms: model.download_ms,
                model_cold_load_ms: model.cold_load_ms,
                total_ms: timeline
                    .completed_at_unix_ms
                    .saturating_sub(timeline.process_started_at_unix_ms)
                    as f64,
                cycles_ms,
            },
            quit_requested: true,
            passed: true,
            failure_code: None,
        }
    }
}

fn failure_report(
    request: &PerformanceSelfTestRequest,
    started_at: u64,
    code: PerformanceFailureCode,
) -> PerformanceReport {
    let completed_at = unix_ms();
    let history_path = CurrentDataPaths::under(&request.data_root).history;
    let history_rows = HistoryStore::open(&history_path)
        .and_then(|store| store.load_all())
        .map(|entries| entries.len())
        .unwrap_or(0);
    PerformanceReport {
        schema_version: 1,
        contract: "gpui-performance-self-test-v1",
        fixture: fixture_report(),
        process: ProcessReport {
            pid: std::process::id(),
        },
        session_id: current_session_id().unwrap_or_else(|| "session-unavailable".to_string()),
        model: ModelReport {
            id: DEFAULT_SELECTED_LOCAL_MODEL_ID,
            revision: PERFORMANCE_MODEL_REVISION,
            engine_instances: 1,
            warmed: false,
            downloaded: false,
        },
        requested: CountReport {
            cycles: CYCLE_COUNT,
            history_rows: HISTORY_COUNT,
        },
        completed: CountReport {
            cycles: 0,
            history_rows,
        },
        history: HistoryReport {
            schema_version: 1,
            integrity_ok: false,
        },
        timings: TimingReport {
            ready_at_unix_ms: 0,
            started_at_unix_ms: started_at,
            history_ready_at_unix_ms: 0,
            activation_started_at_unix_ms: 0,
            loading_started_at_unix_ms: 0,
            model_ready_at_unix_ms: 0,
            warmup_completed_at_unix_ms: 0,
            completed_at_unix_ms: completed_at,
            model_download_ms: 0.0,
            model_cold_load_ms: 0.0,
            total_ms: completed_at.saturating_sub(started_at) as f64,
            cycles_ms: Vec::new(),
        },
        quit_requested: true,
        passed: false,
        failure_code: Some(code.as_str()),
    }
}

fn fixture_report() -> FixtureReport {
    FixtureReport {
        id: PERFORMANCE_FIXTURE_ID,
        sha256: PERFORMANCE_FIXTURE_SHA256,
        bytes: PERFORMANCE_FIXTURE_BYTES,
        channels: 1,
        sample_rate_hz: 16_000,
        bits_per_sample: 16,
        duration_ms: 11_000,
    }
}

fn write_report(path: &Path, report: &PerformanceReport) -> Result<(), RuntimeError> {
    let data = serde_json::to_vec_pretty(report).map_err(|_| performance_error("report_encode"))?;
    let parent = path
        .parent()
        .ok_or_else(|| performance_error("report_parent"))?;
    let temporary = parent.join(format!(".{REPORT_NAME}.tmp-{}", std::process::id()));
    let mut file = File::create(&temporary).map_err(|_| performance_error("report_create"))?;
    file.write_all(&data)
        .and_then(|()| file.write_all(b"\n"))
        .and_then(|()| file.sync_all())
        .map_err(|_| performance_error("report_write"))?;
    fs::rename(&temporary, path).map_err(|_| performance_error("report_publish"))?;
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| performance_error("report_sync"))?;
    Ok(())
}

fn emit_marker(code: DiagnosticCode) {
    emit_diagnostic(DiagnosticEvent::new(
        DiagnosticCategory::Lifecycle,
        DiagnosticLevel::Info,
        code,
    ));
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn unix_ms_after(previous: u64) -> u64 {
    unix_ms().max(previous.saturating_add(1))
}

fn performance_error(code: &str) -> RuntimeError {
    RuntimeError::ServiceFailed {
        service: "performance_self_test",
        message: code.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_signal_timeout_contains_the_full_idle_sampler_deadline() {
        let idle_sampler_deadline = Duration::from_secs((1_800 * 5 / 4) + 2);
        assert!(START_TIMEOUT > idle_sampler_deadline);
        assert!(TOTAL_TIMEOUT > START_TIMEOUT);
        assert!(START_SIGNAL_RECHECK <= Duration::from_secs(2));

        let source = include_str!("performance.rs");
        let Some((_, wait)) = source.split_once("async fn wait_for_start_signal") else {
            panic!("performance start gate exists");
        };
        let Some((wait, _)) = wait.split_once("fn require_missing_observer_ack") else {
            panic!("performance start gate has a bounded source region");
        };
        assert!(wait.contains("fs::symlink_metadata(path)"));
        assert!(wait.contains("tokio::time::sleep(START_SIGNAL_RECHECK)"));
    }

    #[tokio::test]
    async fn observer_ack_is_missing_first_zero_byte_and_bounded() {
        let root = tempfile::tempdir().unwrap_or_else(|error| panic!("temp root: {error}"));
        let ack = root.path().join(OBSERVER_ACK_NAME);
        assert_eq!(require_missing_observer_ack(&ack), Ok(()));

        fs::write(&ack, []).unwrap_or_else(|error| panic!("write preexisting ack: {error}"));
        assert_eq!(
            require_missing_observer_ack(&ack),
            Err(PerformanceFailureCode::UnsafeObserverAck)
        );
        fs::remove_file(&ack).unwrap_or_else(|error| panic!("remove preexisting ack: {error}"));

        assert_eq!(
            wait_for_observer_ack_with_timeout(&ack, Duration::from_millis(30)).await,
            Err(PerformanceFailureCode::ObserverAckTimeout)
        );
        fs::write(&ack, b"not-empty").unwrap_or_else(|error| panic!("write nonempty ack: {error}"));
        assert_eq!(
            wait_for_observer_ack_with_timeout(&ack, Duration::from_millis(30)).await,
            Err(PerformanceFailureCode::UnsafeObserverAck)
        );
        fs::remove_file(&ack).unwrap_or_else(|error| panic!("remove nonempty ack: {error}"));

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.path().join("missing-target"), &ack)
                .unwrap_or_else(|error| panic!("create ack symlink: {error}"));
            assert_eq!(
                wait_for_observer_ack_with_timeout(&ack, Duration::from_millis(30)).await,
                Err(PerformanceFailureCode::UnsafeObserverAck)
            );
            fs::remove_file(&ack).unwrap_or_else(|error| panic!("remove ack symlink: {error}"));
        }

        fs::write(&ack, []).unwrap_or_else(|error| panic!("write valid ack: {error}"));
        assert_eq!(
            wait_for_observer_ack_with_timeout(&ack, Duration::from_millis(30)).await,
            Ok(())
        );
    }

    fn inputs(contract: Option<&str>, fixture: bool, root: bool) -> ProcessInputs {
        ProcessInputs {
            contract: contract.map(OsString::from),
            interaction: None,
            fixture: fixture.then(|| OsString::from("/fixture.wav")),
            data_root: root.then(|| OsString::from("/data")),
            rejected_report: None,
            unknown_performance_env: false,
        }
    }

    fn valid_pcm_fixture() -> Vec<u8> {
        let data_len = 352_000_u32;
        let riff_len = 36_u32.saturating_add(data_len);
        let mut bytes = Vec::with_capacity(data_len as usize + 44);
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&riff_len.to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&16_000_u32.to_le_bytes());
        bytes.extend_from_slice(&32_000_u32.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&16_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_len.to_le_bytes());
        bytes.resize(data_len as usize + 44, 0);
        bytes
    }

    #[test]
    fn both_exact_gates_are_required_and_auxiliary_output_is_rejected() {
        let exact = vec!["wrenflow".to_string(), PERFORMANCE_ARGUMENT.to_string()];
        assert_eq!(
            validate_gate(&exact, &inputs(None, true, true)),
            Err(PerformanceGateError::GateMismatch)
        );
        assert_eq!(
            validate_gate(
                &["wrenflow".to_string()],
                &inputs(Some(PERFORMANCE_CONTRACT), true, true)
            ),
            Err(PerformanceGateError::GateMismatch)
        );
        assert_eq!(
            validate_gate(&exact, &inputs(Some("wrong"), true, true)),
            Err(PerformanceGateError::GateMismatch)
        );
        assert_eq!(
            validate_gate(
                &[
                    "wrenflow".to_string(),
                    PERFORMANCE_ARGUMENT.to_string(),
                    PERFORMANCE_ARGUMENT.to_string()
                ],
                &inputs(Some(PERFORMANCE_CONTRACT), true, true)
            ),
            Err(PerformanceGateError::GateMismatch)
        );
        let mut legacy = inputs(Some(PERFORMANCE_CONTRACT), true, true);
        legacy.rejected_report = Some(OsString::from("/tmp/report"));
        assert_eq!(
            validate_gate(&exact, &legacy),
            Err(PerformanceGateError::GateMismatch)
        );
        assert_eq!(
            validate_gate(&exact, &inputs(Some(PERFORMANCE_CONTRACT), true, true)),
            Ok(())
        );

        let mut interaction = inputs(Some(PERFORMANCE_CONTRACT), true, true);
        interaction.interaction = Some(OsString::from(PERFORMANCE_INTERACTION));
        assert_eq!(validate_gate(&exact, &interaction), Ok(()));

        interaction.interaction = Some(OsString::from("wrong"));
        assert_eq!(
            validate_gate(&exact, &interaction),
            Err(PerformanceGateError::GateMismatch)
        );

        let mut selector_alone = ProcessInputs::default();
        selector_alone.interaction = Some(OsString::from(PERFORMANCE_INTERACTION));
        assert_eq!(
            validate_gate(&["wrenflow".to_string()], &selector_alone),
            Err(PerformanceGateError::GateMismatch)
        );
    }

    #[test]
    fn ordinary_launch_has_no_performance_surface_but_wrong_auxiliary_inputs_do() {
        let normal = vec!["wrenflow".to_string()];
        assert!(!has_performance_surface(&normal, &ProcessInputs::default()));
        assert!(has_performance_surface(
            &[
                "wrenflow".to_string(),
                "--performance-self-test=wrong".to_string()
            ],
            &ProcessInputs::default(),
        ));
        let mut unknown = ProcessInputs::default();
        unknown.unknown_performance_env = true;
        assert!(has_performance_surface(&normal, &unknown));
        assert_eq!(
            validate_gate(&normal, &unknown),
            Err(PerformanceGateError::GateMismatch)
        );

        let mut interaction = ProcessInputs::default();
        interaction.interaction = Some(OsString::from(PERFORMANCE_INTERACTION));
        assert!(has_performance_surface(&normal, &interaction));
        assert_eq!(
            validate_gate(&normal, &interaction),
            Err(PerformanceGateError::GateMismatch)
        );
    }

    #[test]
    fn wav_parser_accepts_only_the_pinned_audio_shape() {
        let mut fixture = valid_pcm_fixture();
        assert_eq!(
            parse_pcm16_mono_16khz(&fixture).map(|samples| samples.len()),
            Ok(176_000)
        );
        fixture[22] = 2;
        assert_eq!(
            parse_pcm16_mono_16khz(&fixture),
            Err(PerformanceGateError::FixtureFormat)
        );
    }

    #[test]
    fn disposable_root_must_exist_and_remain_empty() {
        let root = tempfile::tempdir().unwrap_or_else(|error| panic!("temp root: {error}"));
        assert_eq!(validate_empty_root(root.path()), Ok(()));
        std::fs::write(root.path().join("occupied"), b"x")
            .unwrap_or_else(|error| panic!("write occupied root: {error}"));
        assert_eq!(
            validate_empty_root(root.path()),
            Err(PerformanceGateError::UnsafeDataRoot)
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlink_fixture_and_data_root_are_rejected() {
        use std::os::unix::fs::symlink;

        let fixture = tempfile::tempdir().unwrap_or_else(|error| panic!("temp fixture: {error}"));
        let target = fixture.path().join("target");
        std::fs::write(&target, valid_pcm_fixture())
            .unwrap_or_else(|error| panic!("write fixture: {error}"));
        let fixture_link = fixture.path().join("fixture-link");
        symlink(&target, &fixture_link).unwrap_or_else(|error| panic!("link fixture: {error}"));
        assert_eq!(
            validate_fixture_path(&fixture_link),
            Err(PerformanceGateError::UnsafeFixture)
        );

        let root_target = fixture.path().join("root-target");
        std::fs::create_dir(&root_target).unwrap_or_else(|error| panic!("create root: {error}"));
        let root_link = fixture.path().join("root-link");
        symlink(&root_target, &root_link).unwrap_or_else(|error| panic!("link root: {error}"));
        assert_eq!(
            validate_empty_root(&root_link),
            Err(PerformanceGateError::UnsafeDataRoot)
        );
    }

    #[test]
    fn report_contract_has_exact_counts_and_no_content_fields() {
        let report = PerformanceReport::passed(
            SelfTestTimeline {
                process_started_at_unix_ms: 1,
                ready_at_unix_ms: 10,
                started_at_unix_ms: 20,
                history_ready_at_unix_ms: 30,
                activation_started_at_unix_ms: 40,
                loading_started_at_unix_ms: 50,
                model_ready_at_unix_ms: 60,
                warmup_completed_at_unix_ms: 70,
                completed_at_unix_ms: 80,
            },
            ModelTimings {
                activation_started_at_unix_ms: 40,
                loading_started_at_unix_ms: 50,
                model_ready_at_unix_ms: 60,
                download_ms: 0.5,
                cold_load_ms: 0.5,
            },
            vec![1.0; CYCLE_COUNT],
        );
        let timeline = [
            report.timings.ready_at_unix_ms,
            report.timings.started_at_unix_ms,
            report.timings.history_ready_at_unix_ms,
            report.timings.activation_started_at_unix_ms,
            report.timings.loading_started_at_unix_ms,
            report.timings.model_ready_at_unix_ms,
            report.timings.warmup_completed_at_unix_ms,
            report.timings.completed_at_unix_ms,
        ];
        assert!(timeline.windows(2).all(|pair| pair[0] < pair[1]));
        let encoded = serde_json::to_string(&report).unwrap_or_default();
        assert!(encoded.contains("\"cycles\":20"));
        assert!(encoded.contains("\"history_rows\":50"));
        assert!(encoded.contains(PERFORMANCE_FIXTURE_SHA256));
        assert!(!encoded.contains("transcript"));
        assert!(!encoded.contains("audio_file"));
        assert!(!encoded.contains("device"));
        assert!(!encoded.contains("path"));
    }

    #[test]
    fn verified_model_ready_endpoint_follows_full_presence_verification() {
        let source = include_str!("performance.rs");
        let Some(function) = source.split("async fn activate_model").nth(1) else {
            panic!("activate_model source must exist");
        };
        let Some(verification) = function.find("!model_downloader::is_model_present") else {
            panic!("activate_model must verify the complete model before reporting readiness");
        };
        let Some(completed) = function.find("let completed = Instant::now();") else {
            panic!("activate_model must capture its verified-ready monotonic endpoint");
        };
        let Some(model_ready) = function.find("let model_ready_at_unix_ms") else {
            panic!("activate_model must capture its verified-ready wall endpoint");
        };
        assert!(verification < completed);
        assert!(completed < model_ready);
    }

    #[test]
    fn failure_report_zeros_absolute_transition_timestamps() {
        let root = tempfile::tempdir().unwrap_or_else(|error| panic!("temp root: {error}"));
        let request = PerformanceSelfTestRequest {
            data_root: root.path().to_path_buf(),
            report_path: root.path().join(REPORT_NAME),
            start_signal_path: root.path().join(START_SIGNAL_NAME),
            observer_ack_path: root.path().join(OBSERVER_ACK_NAME),
            fixture: FixtureMetadata {
                samples: Arc::new(Vec::new()),
            },
            interaction_paths: None,
        };
        let report = failure_report(&request, 10, PerformanceFailureCode::TimedOut);
        let transition_timestamps = [
            report.timings.history_ready_at_unix_ms,
            report.timings.activation_started_at_unix_ms,
            report.timings.loading_started_at_unix_ms,
            report.timings.model_ready_at_unix_ms,
            report.timings.warmup_completed_at_unix_ms,
        ];
        assert!(transition_timestamps
            .into_iter()
            .all(|timestamp| timestamp == 0));
    }

    fn valid_interaction_report_json() -> serde_json::Value {
        serde_json::json!({
            "schema_version": 1,
            "classification": "post_event_tap_synthetic",
            "source": "signed_wrenflow_typed_hotkey_callback",
            "key_code": 96,
            "pulses": {
                "requested": 20,
                "completed": 20,
                "overlay_ms": vec![1.0; 20],
                "paste_dispatch_ms": vec![2.0; 20],
                "generation_uptime_ms": (1..=20).map(f64::from).collect::<Vec<_>>()
            },
            "hold": {
                "requested_ms": 60_000,
                "observed_ms": 60_001.0,
                "overlay_ms": 1.0,
                "paste_dispatch_ms": 2.0
            },
            "tcc_or_microphone_evidence": false,
            "passed": true,
            "failure_code": null
        })
    }

    fn parse_interaction_report(value: &serde_json::Value) -> InteractionReport {
        serde_json::from_value(value.clone())
            .unwrap_or_else(|error| panic!("parse report: {error}"))
    }

    #[test]
    fn strict_interaction_report_accepts_only_the_sanitized_exact_contract() {
        let valid = valid_interaction_report_json();
        assert_eq!(
            validate_interaction_report(&parse_interaction_report(&valid)),
            Ok(())
        );

        let mut unknown = valid.clone();
        unknown["path"] = serde_json::json!("/private/customer");
        assert!(serde_json::from_value::<InteractionReport>(unknown).is_err());

        let mut legacy_classification = valid.clone();
        legacy_classification["classification"] = serde_json::json!("synthetic_in_process");
        assert!(serde_json::from_value::<InteractionReport>(legacy_classification).is_err());

        let mut legacy_source = valid.clone();
        legacy_source["source"] = serde_json::json!("signed_wrenflow_cgeventpost");
        assert!(serde_json::from_value::<InteractionReport>(legacy_source).is_err());

        let mut tcc = valid.clone();
        tcc["tcc_or_microphone_evidence"] = serde_json::json!(true);
        assert_eq!(
            validate_interaction_report(&parse_interaction_report(&tcc)),
            Err(PerformanceFailureCode::InvalidInteractionReport)
        );

        let mut wrong_count = valid.clone();
        wrong_count["pulses"]["overlay_ms"] = serde_json::json!(vec![1.0; 19]);
        assert_eq!(
            validate_interaction_report(&parse_interaction_report(&wrong_count)),
            Err(PerformanceFailureCode::InvalidInteractionReport)
        );

        let mut short_hold = valid.clone();
        short_hold["hold"]["observed_ms"] = serde_json::json!(59_999.0);
        assert_eq!(
            validate_interaction_report(&parse_interaction_report(&short_hold)),
            Err(PerformanceFailureCode::InvalidInteractionReport)
        );

        let mut long_hold = valid.clone();
        long_hold["hold"]["observed_ms"] = serde_json::json!(65_001.0);
        assert_eq!(
            validate_interaction_report(&parse_interaction_report(&long_hold)),
            Err(PerformanceFailureCode::InvalidInteractionReport)
        );

        let mut failed = valid;
        failed["passed"] = serde_json::json!(false);
        failed["failure_code"] = serde_json::json!("interaction_cycle_timeout");
        assert_eq!(
            validate_interaction_report(&parse_interaction_report(&failed)),
            Err(PerformanceFailureCode::InvalidInteractionReport)
        );
    }

    #[test]
    fn interaction_paths_remain_opaque_and_clone_to_exact_canonical_names() {
        let root = PathBuf::from("/private/tmp/performance-root");
        let request = PerformanceSelfTestRequest {
            data_root: root.clone(),
            report_path: root.join(REPORT_NAME),
            start_signal_path: root.join(START_SIGNAL_NAME),
            observer_ack_path: root.join(OBSERVER_ACK_NAME),
            fixture: FixtureMetadata {
                samples: Arc::new(vec![0.0]),
            },
            interaction_paths: Some(PerformanceInteractionPaths {
                ready_signal_path: root.join(INTERACTION_READY_NAME),
                report_path: root.join(INTERACTION_REPORT_NAME),
            }),
        };
        let paths = request
            .interaction_driver_paths()
            .expect("interaction paths");
        assert_eq!(request.observer_ack_path, root.join(OBSERVER_ACK_NAME));
        assert_eq!(
            paths.ready_path(),
            root.join(INTERACTION_READY_NAME).as_path()
        );
        assert_eq!(
            paths.report_path(),
            root.join(INTERACTION_REPORT_NAME).as_path()
        );
    }

    #[test]
    fn interaction_ready_signal_is_atomically_published_as_a_regular_empty_file() {
        let root = tempfile::tempdir().unwrap_or_else(|error| panic!("temp root: {error}"));
        let ready = root.path().join(INTERACTION_READY_NAME);
        assert_eq!(publish_interaction_ready(&ready), Ok(()));
        let metadata =
            fs::symlink_metadata(&ready).unwrap_or_else(|error| panic!("signal: {error}"));
        assert!(metadata.file_type().is_file());
        assert!(!metadata.file_type().is_symlink());
        assert_eq!(metadata.len(), 0);
        assert_eq!(
            publish_interaction_ready(&ready),
            Err(PerformanceFailureCode::InteractionReadyPublish)
        );

        let report = root.path().join(INTERACTION_REPORT_NAME);
        assert_eq!(require_missing_interaction_report(&report), Ok(()));
        fs::write(&report, b"{}").unwrap_or_else(|error| panic!("write premature report: {error}"));
        assert_eq!(
            require_missing_interaction_report(&report),
            Err(PerformanceFailureCode::UnsafeInteractionReport)
        );
    }
}

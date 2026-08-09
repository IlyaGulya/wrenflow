//! Current-line launch recovery and crash-loop protection.
//!
//! The marker contains only closed state and counters. It deliberately omits
//! process arguments, paths, transcript/audio data and panic payloads.

use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::data_paths::{current_data_paths, CurrentDataPaths};
use crate::diagnostics::{
    emit_diagnostic, DiagnosticCategory, DiagnosticCode, DiagnosticEvent, DiagnosticLevel,
};

const RECOVERY_SCHEMA_VERSION: u16 = 1;
const MARKER_FILE: &str = "launch-state.json";
const CRASH_WINDOW: Duration = Duration::from_secs(5 * 60);
const CRASH_LOOP_THRESHOLD: u8 = 3;
const MAX_CLEANUP_FILES: usize = 10_000;

static PRODUCTION_RECOVERY: OnceLock<Mutex<Option<LaunchRecovery>>> = OnceLock::new();

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryMode {
    #[default]
    Normal,
    Recovered,
    Safe,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CleanupSummary {
    pub recording_temporary_files: u16,
    pub model_partial_files: u16,
    pub settings_temporary_files: u16,
    pub update_partial_files: u16,
}

impl CleanupSummary {
    #[must_use]
    pub const fn total(self) -> u16 {
        self.recording_temporary_files
            .saturating_add(self.model_partial_files)
            .saturating_add(self.settings_temporary_files)
            .saturating_add(self.update_partial_files)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecoverySnapshot {
    pub mode: RecoveryMode,
    pub consecutive_unclean_launches: u8,
    pub cleanup: CleanupSummary,
    pub reset_current_data_available: bool,
    pub reinstall_current_line_recommended: bool,
}

impl RecoverySnapshot {
    #[must_use]
    pub const fn safe_mode(&self) -> bool {
        matches!(self.mode, RecoveryMode::Safe)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum RecoveryError {
    #[error("recovery storage operation failed ({0:?})")]
    Storage(std::io::ErrorKind),
    #[error("recovery state serialization failed")]
    Serialization,
    #[error("recovery helper request was invalid")]
    InvalidRequest,
    #[error("recovery requires an installed production bundle")]
    UnsupportedInstallation,
    #[error("recovery helper command failed")]
    CommandFailed,
}

impl From<std::io::Error> for RecoveryError {
    fn from(error: std::io::Error) -> Self {
        Self::Storage(error.kind())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum LaunchPhase {
    Starting,
    Running,
    Clean,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LaunchMarker {
    schema_version: u16,
    phase: LaunchPhase,
    started_at_unix_ms: u64,
    crash_window_started_at_unix_ms: u64,
    consecutive_unclean_launches: u8,
}

struct LaunchRecovery {
    marker_path: PathBuf,
    marker: LaunchMarker,
    snapshot: RecoverySnapshot,
}

/// Begin the process-wide launch transaction once the single-instance guard
/// has accepted this process. Repeated calls return the same closed snapshot.
pub fn begin_production_recovery() -> Result<RecoverySnapshot, RecoveryError> {
    let state = PRODUCTION_RECOVERY.get_or_init(|| Mutex::new(None));
    let mut state = state
        .lock()
        .map_err(|_| RecoveryError::Storage(std::io::ErrorKind::Other))?;
    if let Some(recovery) = state.as_ref() {
        return Ok(recovery.snapshot.clone());
    }
    let paths = current_data_paths();
    let recovery = LaunchRecovery::begin(&paths, now_unix_ms())?;
    let snapshot = recovery.snapshot.clone();
    *state = Some(recovery);
    Ok(snapshot)
}

/// Mark that both the Rust runtime and native shell have reached their usable
/// state. The launch remains intentionally unclean until orderly shutdown.
pub fn mark_production_launch_ready() -> Result<(), RecoveryError> {
    update_production_phase(LaunchPhase::Running)
}

/// Mark orderly shutdown. An injected panic, SIGKILL or power interruption
/// cannot execute this transition and is therefore visible on next launch.
pub fn mark_production_launch_clean() -> Result<(), RecoveryError> {
    update_production_phase(LaunchPhase::Clean)
}

#[must_use]
pub fn production_recovery_snapshot() -> RecoverySnapshot {
    PRODUCTION_RECOVERY
        .get()
        .and_then(|state| state.lock().ok())
        .and_then(|state| state.as_ref().map(|recovery| recovery.snapshot.clone()))
        .unwrap_or_default()
}

/// Schedule an explicit current-line reset after the caller has shown product
/// confirmation. Only the current `gpui-v1` root is moved to Trash; legacy
/// data and TCC decisions are not arguments and cannot enter this helper.
pub fn schedule_current_data_reset() -> Result<(), RecoveryError> {
    let executable = std::env::current_exe().map_err(|_| RecoveryError::UnsupportedInstallation)?;
    Command::new(executable)
        .arg("--wrenflow-reset-current-data-helper")
        .arg(std::process::id().to_string())
        .spawn()
        .map_err(|_| RecoveryError::CommandFailed)?;
    Ok(())
}

pub fn run_reset_helper_from_args<I, S>(arguments: I) -> Option<Result<(), RecoveryError>>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let arguments = arguments
        .into_iter()
        .map(|argument| argument.as_ref().to_string())
        .collect::<Vec<_>>();
    let position = arguments
        .iter()
        .position(|argument| argument == "--wrenflow-reset-current-data-helper")?;
    let result = (|| {
        if arguments.len() != position + 2 {
            return Err(RecoveryError::InvalidRequest);
        }
        let pid = arguments[position + 1]
            .parse::<u32>()
            .map_err(|_| RecoveryError::InvalidRequest)?;
        run_reset_helper(pid)
    })();
    Some(result)
}

#[cfg(target_os = "macos")]
fn run_reset_helper(pid: u32) -> Result<(), RecoveryError> {
    wait_for_process_exit(pid)?;
    let root = current_data_paths().root;
    if root.exists() {
        let status = Command::new("/usr/bin/trash")
            .arg(&root)
            .status()
            .map_err(|_| RecoveryError::CommandFailed)?;
        if !status.success() {
            return Err(RecoveryError::CommandFailed);
        }
    }
    let app = installed_app_from_current_executable()?;
    Command::new("/usr/bin/open")
        .arg(app)
        .spawn()
        .map_err(|_| RecoveryError::CommandFailed)?;
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn run_reset_helper(_pid: u32) -> Result<(), RecoveryError> {
    Err(RecoveryError::UnsupportedInstallation)
}

fn wait_for_process_exit(pid: u32) -> Result<(), RecoveryError> {
    for _ in 0..300 {
        let running = Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .output()
            .is_ok_and(|output| output.status.success());
        if !running {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    Err(RecoveryError::CommandFailed)
}

fn installed_app_from_current_executable() -> Result<PathBuf, RecoveryError> {
    let executable = std::env::current_exe().map_err(|_| RecoveryError::UnsupportedInstallation)?;
    let app = executable
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .filter(|path| path.file_name().and_then(|name| name.to_str()) == Some("Wrenflow.app"))
        .ok_or(RecoveryError::UnsupportedInstallation)?;
    if app == Path::new("/Applications/Wrenflow.app") {
        return Ok(app);
    }
    let user_app = dirs::home_dir()
        .map(|home| home.join("Applications/Wrenflow.app"))
        .ok_or(RecoveryError::UnsupportedInstallation)?;
    if app == user_app {
        Ok(app)
    } else {
        Err(RecoveryError::UnsupportedInstallation)
    }
}

fn update_production_phase(phase: LaunchPhase) -> Result<(), RecoveryError> {
    let Some(state) = PRODUCTION_RECOVERY.get() else {
        return Ok(());
    };
    let mut state = state
        .lock()
        .map_err(|_| RecoveryError::Storage(std::io::ErrorKind::Other))?;
    let Some(recovery) = state.as_mut() else {
        return Ok(());
    };
    recovery.marker.phase = phase;
    atomic_write_json(&recovery.marker_path, &recovery.marker)
}

impl LaunchRecovery {
    fn begin(paths: &CurrentDataPaths, now: u64) -> Result<Self, RecoveryError> {
        std::fs::create_dir_all(&paths.recovery)?;
        set_private_directory(&paths.recovery)?;
        let marker_path = paths.recovery.join(MARKER_FILE);
        let previous = read_marker(&marker_path);
        let cleanup = cleanup_interrupted_writes(paths)?;

        let (consecutive_unclean_launches, crash_window_started_at_unix_ms, previous_unclean) =
            previous.as_ref().map_or((0, now, false), |previous| {
                if matches!(previous.phase, LaunchPhase::Clean) {
                    (0, now, false)
                } else if now.saturating_sub(previous.crash_window_started_at_unix_ms)
                    <= duration_millis(CRASH_WINDOW)
                {
                    (
                        previous.consecutive_unclean_launches.saturating_add(1),
                        previous.crash_window_started_at_unix_ms,
                        true,
                    )
                } else {
                    (1, now, true)
                }
            });
        let mode = if consecutive_unclean_launches >= CRASH_LOOP_THRESHOLD {
            RecoveryMode::Safe
        } else if previous_unclean || cleanup.total() > 0 {
            RecoveryMode::Recovered
        } else {
            RecoveryMode::Normal
        };
        let snapshot = RecoverySnapshot {
            mode,
            consecutive_unclean_launches,
            cleanup,
            reset_current_data_available: !matches!(mode, RecoveryMode::Normal),
            reinstall_current_line_recommended: matches!(mode, RecoveryMode::Safe),
        };
        let marker = LaunchMarker {
            schema_version: RECOVERY_SCHEMA_VERSION,
            phase: LaunchPhase::Starting,
            started_at_unix_ms: now,
            crash_window_started_at_unix_ms,
            consecutive_unclean_launches,
        };
        atomic_write_json(&marker_path, &marker)?;

        if previous_unclean {
            emit_diagnostic(DiagnosticEvent::new(
                DiagnosticCategory::Lifecycle,
                DiagnosticLevel::Warning,
                DiagnosticCode::UncleanLaunchRecovered,
            ));
        }
        if matches!(mode, RecoveryMode::Safe) {
            emit_diagnostic(DiagnosticEvent::new(
                DiagnosticCategory::Lifecycle,
                DiagnosticLevel::Error,
                DiagnosticCode::CrashLoopSafeMode,
            ));
        }
        if cleanup.total() > 0 {
            emit_diagnostic(DiagnosticEvent::new(
                DiagnosticCategory::Lifecycle,
                DiagnosticLevel::Info,
                DiagnosticCode::InterruptedWriteCleaned,
            ));
        }

        Ok(Self {
            marker_path,
            marker,
            snapshot,
        })
    }
}

fn read_marker(path: &Path) -> Option<LaunchMarker> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() > 4 * 1024 {
        quarantine_invalid_marker(path);
        return None;
    }
    let marker: LaunchMarker = match serde_json::from_slice(&bytes) {
        Ok(marker) => marker,
        Err(_) => {
            quarantine_invalid_marker(path);
            return None;
        }
    };
    if marker.schema_version != RECOVERY_SCHEMA_VERSION
        || marker.started_at_unix_ms < marker.crash_window_started_at_unix_ms
    {
        quarantine_invalid_marker(path);
        return None;
    }
    Some(marker)
}

fn quarantine_invalid_marker(path: &Path) {
    let quarantine = path.with_file_name("launch-state.invalid");
    let _ = std::fs::remove_file(&quarantine);
    let _ = std::fs::rename(path, quarantine);
}

fn cleanup_interrupted_writes(paths: &CurrentDataPaths) -> Result<CleanupSummary, RecoveryError> {
    let mut summary = CleanupSummary::default();
    if let Ok(entries) = std::fs::read_dir(&paths.root) {
        for entry in entries.flatten().take(MAX_CLEANUP_FILES) {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("config.json.tmp-")
                && entry.file_type().is_ok_and(|t| t.is_file())
                && std::fs::remove_file(entry.path()).is_ok()
            {
                summary.settings_temporary_files =
                    summary.settings_temporary_files.saturating_add(1);
            }
        }
    }
    cleanup_directory_files(
        &paths.recordings,
        1,
        &|name| name.starts_with(".recording_") && name.contains(".ogg.tmp-"),
        &mut summary.recording_temporary_files,
    )?;
    cleanup_directory_files(
        &paths.models,
        8,
        &|name| name.ends_with(".part"),
        &mut summary.model_partial_files,
    )?;
    cleanup_directory_files(
        &paths.updates,
        2,
        &|name| name.ends_with(".partial") || name.ends_with(".download"),
        &mut summary.update_partial_files,
    )?;
    Ok(summary)
}

fn cleanup_directory_files(
    directory: &Path,
    depth: u8,
    matches: &dyn Fn(&str) -> bool,
    count: &mut u16,
) -> Result<(), RecoveryError> {
    if depth == 0 || !directory.exists() {
        return Ok(());
    }
    for entry in std::fs::read_dir(directory)?.take(MAX_CLEANUP_FILES) {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            cleanup_directory_files(&entry.path(), depth - 1, matches, count)?;
            continue;
        }
        let name = entry.file_name();
        if matches(&name.to_string_lossy()) && std::fs::remove_file(entry.path()).is_ok() {
            *count = count.saturating_add(1);
        }
    }
    Ok(())
}

fn atomic_write_json(path: &Path, value: &LaunchMarker) -> Result<(), RecoveryError> {
    let bytes = serde_json::to_vec(value).map_err(|_| RecoveryError::Serialization)?;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    set_private_directory(parent)?;
    let temporary = path.with_file_name(format!("{MARKER_FILE}.tmp-{}", std::process::id()));
    let result = (|| -> Result<(), RecoveryError> {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temporary)?;
        set_private_file(&file)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}

#[cfg(unix)]
fn set_private_directory(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
}

#[cfg(not(unix))]
fn set_private_directory(_path: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file(file: &File) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn set_private_file(_file: &File) -> std::io::Result<()> {
    Ok(())
}

fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

const fn duration_millis(duration: Duration) -> u64 {
    duration.as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(fixture: &tempfile::TempDir) -> CurrentDataPaths {
        CurrentDataPaths::under(fixture.path())
    }

    fn endurance_fixture() -> tempfile::TempDir {
        if let Some(root) = std::env::var_os("WRENFLOW_ENDURANCE_DISPOSABLE_ROOT") {
            let root = PathBuf::from(root);
            assert!(root.is_absolute() && root.is_dir() && !root.is_symlink());
            tempfile::Builder::new()
                .prefix("recovery-")
                .tempdir_in(root)
                .unwrap()
        } else {
            tempfile::Builder::new()
                .prefix("wrenflow-gpui-v1-recovery-")
                .tempdir()
                .unwrap()
        }
    }

    fn regular_file_count(root: &Path) -> usize {
        let Ok(entries) = std::fs::read_dir(root) else {
            return 0;
        };
        entries
            .flatten()
            .map(|entry| {
                if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                    regular_file_count(&entry.path())
                } else if entry.file_type().is_ok_and(|kind| kind.is_file()) {
                    1
                } else {
                    0
                }
            })
            .sum()
    }

    #[test]
    fn three_unclean_launches_enter_safe_mode_without_payloads() {
        let fixture = tempfile::tempdir().unwrap();
        let paths = paths(&fixture);
        let first = LaunchRecovery::begin(&paths, 1_000).unwrap();
        assert_eq!(first.snapshot.mode, RecoveryMode::Normal);
        let second = LaunchRecovery::begin(&paths, 2_000).unwrap();
        assert_eq!(second.snapshot.mode, RecoveryMode::Recovered);
        let third = LaunchRecovery::begin(&paths, 3_000).unwrap();
        assert_eq!(third.snapshot.mode, RecoveryMode::Recovered);
        let fourth = LaunchRecovery::begin(&paths, 4_000).unwrap();
        assert_eq!(fourth.snapshot.mode, RecoveryMode::Safe);
        assert_eq!(fourth.snapshot.consecutive_unclean_launches, 3);

        let marker = std::fs::read_to_string(paths.recovery.join(MARKER_FILE)).unwrap();
        assert!(!marker.contains("transcript"));
        assert!(!marker.contains("audio"));
        assert!(!marker.contains(fixture.path().to_string_lossy().as_ref()));
    }

    #[test]
    fn clean_shutdown_resets_crash_loop() {
        let fixture = tempfile::tempdir().unwrap();
        let paths = paths(&fixture);
        let mut launch = LaunchRecovery::begin(&paths, 1_000).unwrap();
        launch.marker.phase = LaunchPhase::Clean;
        atomic_write_json(&launch.marker_path, &launch.marker).unwrap();
        let next = LaunchRecovery::begin(&paths, 2_000).unwrap();
        assert_eq!(next.snapshot.mode, RecoveryMode::Normal);
        assert_eq!(next.snapshot.consecutive_unclean_launches, 0);
    }

    #[test]
    fn next_launch_removes_only_strict_temporary_patterns() {
        let fixture = tempfile::tempdir().unwrap();
        let paths = paths(&fixture);
        std::fs::create_dir_all(&paths.root).unwrap();
        std::fs::create_dir_all(&paths.recordings).unwrap();
        std::fs::create_dir_all(paths.models.join("model")).unwrap();
        std::fs::create_dir_all(&paths.updates).unwrap();
        std::fs::write(paths.root.join("config.json.tmp-1"), b"partial").unwrap();
        std::fs::write(paths.root.join("config.json"), b"current").unwrap();
        std::fs::write(paths.root.join("history.sqlite-wal"), b"sqlite recovery").unwrap();
        std::fs::write(
            paths.recordings.join(".recording_1_1.ogg.tmp-1"),
            b"partial",
        )
        .unwrap();
        std::fs::write(paths.recordings.join("recording_1_1.ogg"), b"complete").unwrap();
        std::fs::write(paths.models.join("model/weights.onnx.part"), b"partial").unwrap();
        std::fs::write(paths.models.join("model/weights.onnx"), b"verified").unwrap();
        std::fs::write(paths.updates.join("Wrenflow.dmg.partial"), b"partial").unwrap();

        let summary = cleanup_interrupted_writes(&paths).unwrap();
        assert_eq!(summary.total(), 4);
        assert_eq!(
            std::fs::read(paths.root.join("config.json")).unwrap(),
            b"current"
        );
        assert_eq!(
            std::fs::read(paths.recordings.join("recording_1_1.ogg")).unwrap(),
            b"complete"
        );
        assert_eq!(
            std::fs::read(paths.models.join("model/weights.onnx")).unwrap(),
            b"verified"
        );
        assert_eq!(
            std::fs::read(paths.root.join("history.sqlite-wal")).unwrap(),
            b"sqlite recovery"
        );
    }

    #[test]
    fn twenty_interrupted_launches_clean_only_bounded_temporary_state() {
        const CYCLES: u64 = 20;

        let fixture = endurance_fixture();
        let paths = paths(&fixture);
        std::fs::create_dir_all(&paths.recordings).unwrap();
        std::fs::create_dir_all(paths.models.join("model")).unwrap();
        std::fs::create_dir_all(&paths.updates).unwrap();
        std::fs::write(&paths.config, b"current-settings").unwrap();
        std::fs::write(&paths.history, b"current-history").unwrap();
        std::fs::write(paths.root.join("history.sqlite-wal"), b"sqlite-recovery").unwrap();
        std::fs::write(paths.recordings.join("complete.ogg"), b"complete-recording").unwrap();
        std::fs::write(paths.models.join("model/weights.onnx"), b"verified-model").unwrap();
        std::fs::write(paths.updates.join("Wrenflow-0.4.0.dmg"), b"verified-update").unwrap();

        let mut initial = LaunchRecovery::begin(&paths, 1_000).unwrap();
        initial.marker.phase = LaunchPhase::Clean;
        atomic_write_json(&initial.marker_path, &initial.marker).unwrap();
        let stable_file_count = regular_file_count(&paths.root);

        for cycle in 0..CYCLES {
            let started_at = 2_000 + cycle * 2_000;
            let abandoned = LaunchRecovery::begin(&paths, started_at).unwrap();
            assert_eq!(abandoned.snapshot.mode, RecoveryMode::Normal);

            std::fs::write(paths.root.join("config.json.tmp-20"), b"partial-settings").unwrap();
            std::fs::write(
                paths.recordings.join(".recording_20_20.ogg.tmp-20"),
                b"partial-recording",
            )
            .unwrap();
            std::fs::write(
                paths.models.join("model/weights.onnx.part"),
                b"partial-model",
            )
            .unwrap();
            std::fs::write(
                paths.updates.join("Wrenflow-0.5.0.dmg.partial"),
                b"partial-update",
            )
            .unwrap();
            drop(abandoned);

            let mut recovered = LaunchRecovery::begin(&paths, started_at + 1_000).unwrap();
            assert_eq!(recovered.snapshot.mode, RecoveryMode::Recovered);
            assert_eq!(recovered.snapshot.cleanup.total(), 4);
            assert_eq!(recovered.snapshot.cleanup.recording_temporary_files, 1);
            assert_eq!(recovered.snapshot.cleanup.model_partial_files, 1);
            assert_eq!(recovered.snapshot.cleanup.settings_temporary_files, 1);
            assert_eq!(recovered.snapshot.cleanup.update_partial_files, 1);

            assert_eq!(std::fs::read(&paths.config).unwrap(), b"current-settings");
            assert_eq!(std::fs::read(&paths.history).unwrap(), b"current-history");
            assert_eq!(
                std::fs::read(paths.root.join("history.sqlite-wal")).unwrap(),
                b"sqlite-recovery"
            );
            assert_eq!(
                std::fs::read(paths.recordings.join("complete.ogg")).unwrap(),
                b"complete-recording"
            );
            assert_eq!(
                std::fs::read(paths.models.join("model/weights.onnx")).unwrap(),
                b"verified-model"
            );
            assert_eq!(
                std::fs::read(paths.updates.join("Wrenflow-0.4.0.dmg")).unwrap(),
                b"verified-update"
            );
            assert_eq!(regular_file_count(&paths.root), stable_file_count);

            recovered.marker.phase = LaunchPhase::Clean;
            atomic_write_json(&recovered.marker_path, &recovered.marker).unwrap();
        }
    }

    #[test]
    fn corrupt_marker_is_quarantined_and_fails_open_to_normal_launch() {
        let fixture = tempfile::tempdir().unwrap();
        let paths = paths(&fixture);
        std::fs::create_dir_all(&paths.recovery).unwrap();
        std::fs::write(paths.recovery.join(MARKER_FILE), b"{private transcript").unwrap();
        let launch = LaunchRecovery::begin(&paths, 1_000).unwrap();
        assert_eq!(launch.snapshot.mode, RecoveryMode::Normal);
        assert!(paths.recovery.join("launch-state.invalid").exists());
    }

    #[test]
    fn reset_helper_rejects_paths_and_extra_scope_arguments() {
        let error = run_reset_helper_from_args([
            "wrenflow",
            "--wrenflow-reset-current-data-helper",
            "42",
            "/Users/private/Library/Application Support/Wrenflow",
        ])
        .unwrap()
        .unwrap_err();
        assert!(matches!(error, RecoveryError::InvalidRequest));
    }
}

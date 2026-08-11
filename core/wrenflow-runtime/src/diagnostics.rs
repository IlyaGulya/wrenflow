//! Privacy-safe production diagnostics shared by the GPUI runtime and shell.
//!
//! The boundary is deliberately restrictive: callers select stable enum
//! values and may attach only an opaque, process-local correlation ID. Free
//! form product data never enters a diagnostic record.

#[cfg(target_vendor = "apple")]
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, Once, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

pub const DIAGNOSTIC_SUBSYSTEM: &str = "me.gulya.wrenflow";
pub const DIAGNOSTIC_SCHEMA_VERSION: u16 = 1;

const EVENTS_FILE: &str = "events.ndjson";
const CRASHES_FILE: &str = "crashes.ndjson";
const EVENT_FILE_BYTES: u64 = 512 * 1024;
const CRASH_FILE_BYTES: u64 = 128 * 1024;
const EVENT_ARCHIVES: usize = 3;
const CRASH_ARCHIVES: usize = 2;
const EVENT_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const CRASH_RETENTION: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const MAX_RECORD_BYTES: usize = 4 * 1024;
const MAX_EXPORT_BYTES: usize = 2 * 1024 * 1024;

static DIAGNOSTICS: OnceLock<Diagnostics> = OnceLock::new();
static INITIALIZE: Once = Once::new();
static SESSION_SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticCategory {
    Lifecycle,
    Permissions,
    Hotkey,
    Recording,
    Transcription,
    Models,
    History,
    Updates,
    Bridge,
}

impl DiagnosticCategory {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Lifecycle => "lifecycle",
            Self::Permissions => "permissions",
            Self::Hotkey => "hotkey",
            Self::Recording => "recording",
            Self::Transcription => "transcription",
            Self::Models => "models",
            Self::History => "history",
            Self::Updates => "updates",
            Self::Bridge => "bridge",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticLevel {
    Trace,
    Debug,
    Info,
    Warning,
    Error,
}

impl DiagnosticLevel {
    const fn enabled_in_this_build(self) -> bool {
        cfg!(debug_assertions) || matches!(self, Self::Info | Self::Warning | Self::Error)
    }

    #[cfg(target_vendor = "apple")]
    const fn os_log_value(self) -> u8 {
        match self {
            Self::Trace => 0,
            Self::Debug => 1,
            Self::Info => 2,
            Self::Warning => 3,
            Self::Error => 4,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticCode {
    Startup,
    MenuBarReady,
    Shutdown,
    RuntimeLog,
    RecordingStarted,
    RecordingAudioReady,
    RecordingStopped,
    TranscriptionStarted,
    TranscriptionCompleted,
    PipelineFailed,
    RustPanic,
    SwiftShellFailure,
    SwiftShellInstallFailed,
    SwiftLoginItemFailed,
    SwiftUninstallEvidenceFailed,
    SwiftBridgeDecodeFailed,
    SwiftAccessibilityFailed,
    SwiftSingleInstanceIdentityFailed,
    PermissionStateObserved,
    LaunchAtLoginObserved,
    HotkeyPressed,
    HotkeyReleased,
    ModelActivationRequested,
    ModelCancellationRequested,
    HistoryDeleteRequested,
    HistoryClearRequested,
    UpdateStatusObserved,
    UpdateStatusPublishFailed,
    ShellCapabilitiesObserved,
    ShellCapabilitiesPublishFailed,
    AudioDevicesRefreshFailed,
    ModelInventoryRefreshFailed,
    SettingsWriteFailed,
    GpuiStartupFailed,
    GpuiWindowCreateFailed,
    GpuiWindowRemoveFailed,
    GpuiWindowLayoutFailed,
    GpuiAppAccessFailed,
    ShellRequestReceiverUnavailable,
    AppKitShellInstallFailed,
    TrayPublishFailed,
    RuntimeShutdownFailed,
    AccessibilityActionUnknown,
    AccessibilityActionRejected,
    AccessibilitySnapshotFailed,
    AccessibilityTreePublishFailed,
    ShellCommandRejected,
    AppModelLagged,
    ErrorToastPublishFailed,
    UncleanLaunchRecovered,
    CrashLoopSafeMode,
    RecoveryStateWriteFailed,
    InterruptedWriteCleaned,
    UpdateArtifactVerified,
    UpdatePrepared,
    UpdateCompleted,
    UpdateFailed,
    SupportBundleCreated,
    SupportBundleFailed,
    SupportBundleStatusObserved,
    PerformanceSelfTestStarted,
    PerformanceSelfTestFixtureVerified,
    PerformanceSelfTestReady,
    PerformanceSelfTestHistoryReady,
    PerformanceSelfTestCompleted,
    PerformanceSelfTestFailed,
    PerformanceSelfTestTimedOut,
}

impl DiagnosticCode {
    const fn is_crash(self) -> bool {
        matches!(self, Self::RustPanic | Self::SwiftShellFailure)
    }
}

/// Opaque for one launch and unsuitable as a persistent device identifier.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CorrelationId(String);

impl CorrelationId {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug)]
pub struct DiagnosticEvent {
    category: DiagnosticCategory,
    level: DiagnosticLevel,
    code: DiagnosticCode,
    correlation: Option<CorrelationId>,
    source: Option<SafeSource>,
}

impl DiagnosticEvent {
    #[must_use]
    pub const fn new(
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        code: DiagnosticCode,
    ) -> Self {
        Self {
            category,
            level,
            code,
            correlation: None,
            source: None,
        }
    }

    #[must_use]
    pub fn correlated(mut self, correlation: &CorrelationId) -> Self {
        self.correlation = Some(correlation.clone());
        self
    }

    pub(crate) fn with_source(mut self, target: &str, line: Option<u32>) -> Self {
        self.source = Some(SafeSource::new(target, line));
        self
    }

    fn with_location(mut self, file: &str, line: u32) -> Self {
        self.source = Some(SafeSource::location(file, line));
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagnosticExportFile {
    pub name: String,
    pub contents: String,
}

/// In-memory, bounded input for the support-bundle implementation in `.9.3`.
/// It intentionally exposes no path to the user's home directory.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagnosticExport {
    pub schema_version: u16,
    pub generated_at_unix_ms: u64,
    pub files: Vec<DiagnosticExportFile>,
}

#[derive(Debug, thiserror::Error)]
pub enum DiagnosticError {
    #[error("diagnostic storage operation failed ({0:?})")]
    Storage(std::io::ErrorKind),
    #[error("diagnostic record serialization failed")]
    Serialization,
}

impl From<std::io::Error> for DiagnosticError {
    fn from(error: std::io::Error) -> Self {
        Self::Storage(error.kind())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct SafeSource {
    target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    line: Option<u32>,
}

impl SafeSource {
    fn new(target: &str, line: Option<u32>) -> Self {
        let sanitized: String = target
            .chars()
            .take(128)
            .map(|character| {
                if character.is_ascii_alphanumeric() || matches!(character, '_' | ':' | '-') {
                    character
                } else {
                    '_'
                }
            })
            .collect();
        if sanitized.starts_with("wrenflow_") {
            Self {
                target: sanitized,
                line,
            }
        } else {
            Self {
                target: "dependency".to_string(),
                line: None,
            }
        }
    }

    fn location(file: &str, line: u32) -> Self {
        let basename = Path::new(file)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown");
        let basename: String = basename
            .chars()
            .take(96)
            .map(|character| {
                if character.is_ascii_alphanumeric() || matches!(character, '_' | '-') {
                    character
                } else {
                    '_'
                }
            })
            .collect();
        Self {
            target: format!("source::{basename}"),
            line: Some(line),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct DiagnosticRecord {
    schema_version: u16,
    timestamp_unix_ms: u64,
    session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    correlation_id: Option<String>,
    category: DiagnosticCategory,
    level: DiagnosticLevel,
    code: DiagnosticCode,
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<SafeSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    startup: Option<StartupMetadata>,
}

impl DiagnosticRecord {
    fn is_export_safe(&self) -> bool {
        let valid_session = self
            .session_id
            .strip_prefix("s-")
            .is_some_and(|suffix| suffix.len() == 16 && suffix.bytes().all(is_lower_hex));
        let valid_correlation = self.correlation_id.as_ref().is_none_or(|correlation| {
            correlation
                .strip_prefix(&format!("{}-", self.session_id))
                .is_some_and(|suffix| suffix.len() == 8 && suffix.bytes().all(is_lower_hex))
        });
        let valid_source = self.source.as_ref().is_none_or(|source| {
            source.target == "dependency"
                || ((source.target.starts_with("wrenflow_")
                    || source.target.starts_with("source::"))
                    && source.target.len() <= 128
                    && source.target.bytes().all(|byte| {
                        byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b':' | b'-')
                    }))
        });
        let valid_startup = self.startup.as_ref().is_none_or(|startup| {
            startup.remote_telemetry == "disabled"
                && matches!(startup.os_family.as_str(), "macos" | "ios")
                && matches!(startup.architecture.as_str(), "aarch64" | "x86_64")
                && matches!(startup.build_profile.as_str(), "debug" | "release")
                && startup.app_version.len() <= 32
                && startup
                    .app_version
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+'))
        });
        self.schema_version == DIAGNOSTIC_SCHEMA_VERSION
            && valid_session
            && valid_correlation
            && valid_source
            && valid_startup
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct StartupMetadata {
    app_version: String,
    os_family: String,
    architecture: String,
    build_profile: String,
    remote_telemetry: String,
}

struct Diagnostics {
    session_id: String,
    correlation_sequence: AtomicU64,
    sink: Mutex<FileSink>,
}

impl Diagnostics {
    fn production() -> Self {
        Self::new(
            crate::data_paths::current_data_paths().diagnostics,
            new_session_id(),
        )
    }

    fn new(directory: PathBuf, session_id: String) -> Self {
        Self {
            session_id,
            correlation_sequence: AtomicU64::new(1),
            sink: Mutex::new(FileSink::new(directory)),
        }
    }

    fn correlation_id(&self) -> CorrelationId {
        let sequence = self.correlation_sequence.fetch_add(1, Ordering::Relaxed);
        CorrelationId(format!("{}-{sequence:08x}", self.session_id))
    }

    fn record(&self, event: DiagnosticEvent) -> Result<Vec<u8>, DiagnosticError> {
        self.record_with_metadata(event, None)
    }

    fn record_with_metadata(
        &self,
        event: DiagnosticEvent,
        startup: Option<StartupMetadata>,
    ) -> Result<Vec<u8>, DiagnosticError> {
        if !event.level.enabled_in_this_build() {
            return Ok(Vec::new());
        }
        let record = DiagnosticRecord {
            schema_version: DIAGNOSTIC_SCHEMA_VERSION,
            timestamp_unix_ms: now_unix_ms(),
            session_id: self.session_id.clone(),
            correlation_id: event.correlation.map(|value| value.0),
            category: event.category,
            level: event.level,
            code: event.code,
            source: event.source,
            startup,
        };
        let mut encoded =
            serde_json::to_vec(&record).map_err(|_| DiagnosticError::Serialization)?;
        if encoded.len() > MAX_RECORD_BYTES {
            return Err(DiagnosticError::Serialization);
        }
        encoded.push(b'\n');
        emit_os_log(record.category, record.level, &encoded);
        let mut sink = self
            .sink
            .lock()
            .map_err(|_| DiagnosticError::Storage(std::io::ErrorKind::Other))?;
        sink.write(record.code.is_crash(), &encoded)?;
        Ok(encoded)
    }

    fn export(&self) -> Result<DiagnosticExport, DiagnosticError> {
        let mut sink = self
            .sink
            .lock()
            .map_err(|_| DiagnosticError::Storage(std::io::ErrorKind::Other))?;
        sink.purge(SystemTime::now())?;
        let files = sink.read_export()?;
        Ok(DiagnosticExport {
            schema_version: DIAGNOSTIC_SCHEMA_VERSION,
            generated_at_unix_ms: now_unix_ms(),
            files,
        })
    }
}

struct FileSink {
    directory: PathBuf,
    writes_since_purge: usize,
}

impl FileSink {
    const fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            writes_since_purge: 0,
        }
    }

    fn write(&mut self, crash: bool, record: &[u8]) -> Result<(), DiagnosticError> {
        self.prepare_directory()?;
        if self.writes_since_purge == 0 {
            self.purge(SystemTime::now())?;
        }
        self.writes_since_purge = (self.writes_since_purge + 1) % 64;

        let (name, maximum, archives) = if crash {
            (CRASHES_FILE, CRASH_FILE_BYTES, CRASH_ARCHIVES)
        } else {
            (EVENTS_FILE, EVENT_FILE_BYTES, EVENT_ARCHIVES)
        };
        let path = self.directory.join(name);
        let length = path.metadata().map(|metadata| metadata.len()).unwrap_or(0);
        if length.saturating_add(record.len() as u64) > maximum {
            self.rotate(name, archives)?;
        }
        let mut file = open_private_append(&path)?;
        file.write_all(record)?;
        file.flush()?;
        if crash {
            file.sync_data()?;
        }
        Ok(())
    }

    fn prepare_directory(&self) -> Result<(), DiagnosticError> {
        std::fs::create_dir_all(&self.directory)?;
        set_private_directory_permissions(&self.directory)?;
        Ok(())
    }

    fn rotate(&self, name: &str, archives: usize) -> Result<(), DiagnosticError> {
        let oldest = archive_path(&self.directory, name, archives);
        remove_if_exists(&oldest)?;
        for index in (1..archives).rev() {
            let source = archive_path(&self.directory, name, index);
            let destination = archive_path(&self.directory, name, index + 1);
            rename_if_exists(&source, &destination)?;
        }
        rename_if_exists(
            &self.directory.join(name),
            &archive_path(&self.directory, name, 1),
        )?;
        Ok(())
    }

    fn purge(&mut self, now: SystemTime) -> Result<(), DiagnosticError> {
        if !self.directory.exists() {
            return Ok(());
        }
        for (name, retention, archives) in [
            (EVENTS_FILE, EVENT_RETENTION, EVENT_ARCHIVES),
            (CRASHES_FILE, CRASH_RETENTION, CRASH_ARCHIVES),
        ] {
            for index in 0..=archives {
                let path = if index == 0 {
                    self.directory.join(name)
                } else {
                    archive_path(&self.directory, name, index)
                };
                let Ok(metadata) = path.metadata() else {
                    continue;
                };
                let modified = metadata.modified().unwrap_or(UNIX_EPOCH);
                if now.duration_since(modified).unwrap_or_default() > retention {
                    remove_if_exists(&path)?;
                }
            }
        }
        self.writes_since_purge = 0;
        Ok(())
    }

    fn read_export(&self) -> Result<Vec<DiagnosticExportFile>, DiagnosticError> {
        let mut files = Vec::new();
        let mut remaining = MAX_EXPORT_BYTES;
        for name in export_file_names() {
            if remaining == 0 {
                break;
            }
            let path = self.directory.join(&name);
            let Ok(mut file) = File::open(path) else {
                continue;
            };
            let mut bytes = Vec::new();
            std::io::Read::by_ref(&mut file)
                .take(remaining as u64)
                .read_to_end(&mut bytes)?;
            remaining = remaining.saturating_sub(bytes.len());
            let contents = String::from_utf8_lossy(&bytes).into_owned();
            // Only records written by the restrictive schema are exported.
            let contents = contents
                .lines()
                .filter_map(|line| serde_json::from_str::<DiagnosticRecord>(line).ok())
                .filter(DiagnosticRecord::is_export_safe)
                .filter_map(|record| serde_json::to_string(&record).ok())
                .collect::<Vec<String>>()
                .join("\n");
            if !contents.is_empty() {
                files.push(DiagnosticExportFile { name, contents });
            }
        }
        Ok(files)
    }
}

pub(crate) fn initialize() {
    INITIALIZE.call_once(|| {
        let diagnostics = DIAGNOSTICS.get_or_init(Diagnostics::production);
        let startup = StartupMetadata {
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            os_family: std::env::consts::OS.to_string(),
            architecture: std::env::consts::ARCH.to_string(),
            build_profile: if cfg!(debug_assertions) {
                "debug"
            } else {
                "release"
            }
            .to_string(),
            remote_telemetry: "disabled".to_string(),
        };
        let _ = diagnostics.record_with_metadata(
            DiagnosticEvent::new(
                DiagnosticCategory::Lifecycle,
                DiagnosticLevel::Info,
                DiagnosticCode::Startup,
            ),
            Some(startup),
        );
        // The Flutter-era tail file is outside the current data contract and
        // may contain unbounded private text. Never read it; remove only this
        // exact legacy filename.
        let _ = std::fs::remove_file("/tmp/wrenflow.log");
    });
}

/// Initialize the process-wide production sink before fallible app startup.
/// This is intentionally separate from `start_runtime` so GPUI/AppKit bootstrap
/// failures also leave a fixed-code record.
pub fn initialize_production_diagnostics() {
    initialize();
}

/// Return the opaque per-launch identifier used by closed diagnostic records.
/// It is safe for aggregate evidence and never encodes a path or device ID.
#[must_use]
pub fn current_session_id() -> Option<String> {
    DIAGNOSTICS
        .get()
        .map(|diagnostics| diagnostics.session_id.clone())
}

#[must_use]
pub fn new_correlation_id() -> CorrelationId {
    DIAGNOSTICS.get().map_or_else(
        || {
            let sequence = SESSION_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            CorrelationId(format!("s-uninitialized-{sequence:08x}"))
        },
        Diagnostics::correlation_id,
    )
}

pub fn emit_diagnostic(event: DiagnosticEvent) {
    if let Some(diagnostics) = DIAGNOSTICS.get() {
        let _ = diagnostics.record(event);
    }
}

pub fn collect_diagnostics() -> Result<DiagnosticExport, DiagnosticError> {
    DIAGNOSTICS.get_or_init(Diagnostics::production).export()
}

/// Fixed-code Swift/AppKit failure bridge. No C string crosses this boundary,
/// so `localizedDescription`, paths and product content cannot be logged by
/// accident. Swift codes are part of the diagnostics schema contract.
#[unsafe(no_mangle)]
pub extern "C" fn wrenflow_diagnostics_report_shell_failure(code: u8) {
    let (category, code) = swift_failure_code(code);
    emit_diagnostic(DiagnosticEvent::new(category, DiagnosticLevel::Error, code));
}

pub(crate) fn emit_legacy_record(record: &log::Record<'_>) {
    let category = category_for_target(record.target());
    let level = match record.level() {
        log::Level::Error => DiagnosticLevel::Error,
        log::Level::Warn => DiagnosticLevel::Warning,
        log::Level::Info => DiagnosticLevel::Info,
        log::Level::Debug => DiagnosticLevel::Debug,
        log::Level::Trace => DiagnosticLevel::Trace,
    };
    // record.args() is intentionally not formatted. Existing call sites may
    // contain paths, device names, transcript text or third-party errors.
    emit_diagnostic(
        DiagnosticEvent::new(category, level, DiagnosticCode::RuntimeLog)
            .with_source(record.target(), record.line()),
    );
}

pub(crate) fn capture_panic(info: &std::panic::PanicHookInfo<'_>) {
    let mut event = DiagnosticEvent::new(
        DiagnosticCategory::Lifecycle,
        DiagnosticLevel::Error,
        DiagnosticCode::RustPanic,
    );
    if let Some(location) = info.location() {
        event = event.with_location(location.file(), location.line());
    }
    // Panic payload and thread name are untrusted and deliberately omitted.
    emit_diagnostic(event);
}

fn category_for_target(target: &str) -> DiagnosticCategory {
    let target = target.to_ascii_lowercase();
    if target.contains("permission") {
        DiagnosticCategory::Permissions
    } else if target.contains("hotkey") {
        DiagnosticCategory::Hotkey
    } else if target.contains("audio") || target.contains("recording") {
        DiagnosticCategory::Recording
    } else if target.contains("transcri") || target.contains("whisper") {
        DiagnosticCategory::Transcription
    } else if target.contains("model") {
        DiagnosticCategory::Models
    } else if target.contains("history") {
        DiagnosticCategory::History
    } else if target.contains("update") {
        DiagnosticCategory::Updates
    } else if target.contains("shell") || target.contains("bridge") {
        DiagnosticCategory::Bridge
    } else {
        DiagnosticCategory::Lifecycle
    }
}

fn swift_failure_code(value: u8) -> (DiagnosticCategory, DiagnosticCode) {
    match value {
        1 => (
            DiagnosticCategory::Bridge,
            DiagnosticCode::SwiftShellInstallFailed,
        ),
        2 => (
            DiagnosticCategory::Lifecycle,
            DiagnosticCode::SwiftLoginItemFailed,
        ),
        3 => (
            DiagnosticCategory::Lifecycle,
            DiagnosticCode::SwiftUninstallEvidenceFailed,
        ),
        4 => (
            DiagnosticCategory::Bridge,
            DiagnosticCode::SwiftBridgeDecodeFailed,
        ),
        5 => (
            DiagnosticCategory::Bridge,
            DiagnosticCode::SwiftAccessibilityFailed,
        ),
        6 => (
            DiagnosticCategory::Lifecycle,
            DiagnosticCode::SwiftSingleInstanceIdentityFailed,
        ),
        _ => (
            DiagnosticCategory::Bridge,
            DiagnosticCode::SwiftShellFailure,
        ),
    }
}

fn new_session_id() -> String {
    let sequence = SESSION_SEQUENCE.fetch_add(1, Ordering::Relaxed) as u128;
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    // Ephemeral launch correlation only; never persisted as a device identity.
    format!("s-{:016x}", (timestamp ^ sequence) as u64)
}

fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn is_lower_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
}

fn export_file_names() -> Vec<String> {
    // Reserve the bounded export budget for crash evidence before ordinary
    // events; a full event ring must never starve panic recovery evidence.
    let mut names = vec![CRASHES_FILE.to_string()];
    names.extend((1..=CRASH_ARCHIVES).map(|index| archive_name(CRASHES_FILE, index)));
    names.push(EVENTS_FILE.to_string());
    names.extend((1..=EVENT_ARCHIVES).map(|index| archive_name(EVENTS_FILE, index)));
    names
}

fn archive_name(name: &str, index: usize) -> String {
    let (stem, extension) = name.rsplit_once('.').unwrap_or((name, ""));
    if extension.is_empty() {
        format!("{stem}.{index}")
    } else {
        format!("{stem}.{index}.{extension}")
    }
}

fn archive_path(directory: &Path, name: &str, index: usize) -> PathBuf {
    directory.join(archive_name(name, index))
}

fn remove_if_exists(path: &Path) -> Result<(), DiagnosticError> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn rename_if_exists(source: &Path, destination: &Path) -> Result<(), DiagnosticError> {
    match std::fs::rename(source, destination) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn open_private_append(path: &Path) -> Result<File, DiagnosticError> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let file = options.open(path)?;
    set_private_file_permissions(&file)?;
    Ok(file)
}

#[cfg(unix)]
fn set_private_file_permissions(file: &File) -> Result<(), DiagnosticError> {
    use std::os::unix::fs::PermissionsExt as _;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_private_file_permissions(_file: &File) -> Result<(), DiagnosticError> {
    Ok(())
}

#[cfg(unix)]
fn set_private_directory_permissions(path: &Path) -> Result<(), DiagnosticError> {
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_private_directory_permissions(_path: &Path) -> Result<(), DiagnosticError> {
    Ok(())
}

#[cfg(target_vendor = "apple")]
fn emit_os_log(category: DiagnosticCategory, level: DiagnosticLevel, encoded: &[u8]) {
    unsafe extern "C" {
        fn wrenflow_os_log_write(
            subsystem: *const std::ffi::c_char,
            category: *const std::ffi::c_char,
            level: u8,
            message: *const std::ffi::c_char,
        );
    }

    let Ok(subsystem) = CString::new(DIAGNOSTIC_SUBSYSTEM) else {
        return;
    };
    let Ok(category) = CString::new(category.as_str()) else {
        return;
    };
    let Ok(message) = CString::new(encoded) else {
        return;
    };
    // SAFETY: all pointers remain valid for the duration of the synchronous C
    // wrapper call, and the level is mapped to a closed numeric range.
    unsafe {
        wrenflow_os_log_write(
            subsystem.as_ptr(),
            category.as_ptr(),
            level.os_log_value(),
            message.as_ptr(),
        );
    }
}

#[cfg(not(target_vendor = "apple"))]
fn emit_os_log(_category: DiagnosticCategory, _level: DiagnosticLevel, encoded: &[u8]) {
    if cfg!(debug_assertions) {
        eprint!("{}", String::from_utf8_lossy(encoded));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn diagnostics_at(path: &Path) -> Diagnostics {
        Diagnostics::new(path.to_path_buf(), "s-0000000000000001".to_string())
    }

    #[test]
    fn secret_fixtures_never_cross_the_structured_boundary() {
        let fixture = tempfile::tempdir().unwrap();
        let diagnostics = diagnostics_at(fixture.path());
        let correlation = diagnostics.correlation_id();
        let private_fixtures = [
            "private transcript raven flies at midnight",
            "custom vocabulary ultra-secret-term",
            "audio /Users/alice/Library/Application Support/Wrenflow/recording.ogg",
            "device Built-in Microphone 7F:AA:BB",
            "credential Bearer ghp_0123456789abcdef",
            "alice@example.com",
        ];

        let encoded = diagnostics
            .record(
                DiagnosticEvent::new(
                    DiagnosticCategory::Transcription,
                    DiagnosticLevel::Error,
                    DiagnosticCode::PipelineFailed,
                )
                .correlated(&correlation),
            )
            .unwrap();
        let encoded = String::from_utf8(encoded).unwrap();
        for private in private_fixtures {
            assert!(!encoded.contains(private));
        }
        assert!(encoded.contains(correlation.as_str()));
        assert!(encoded.contains("pipeline_failed"));
    }

    #[test]
    fn source_locations_keep_only_basename_and_line() {
        let fixture = tempfile::tempdir().unwrap();
        let diagnostics = diagnostics_at(fixture.path());
        let encoded = diagnostics
            .record(
                DiagnosticEvent::new(
                    DiagnosticCategory::Lifecycle,
                    DiagnosticLevel::Error,
                    DiagnosticCode::RustPanic,
                )
                .with_location("/Users/alice/private/project/main.rs", 42),
            )
            .unwrap();
        let encoded = String::from_utf8(encoded).unwrap();
        assert!(encoded.contains("source::main_rs"));
        assert!(encoded.contains("\"line\":42"));
        assert!(!encoded.contains("/Users/alice"));
        assert!(!encoded.contains("private/project"));
    }

    #[test]
    fn rotation_is_bounded_and_files_are_private() {
        let fixture = tempfile::tempdir().unwrap();
        let mut sink = FileSink::new(fixture.path().to_path_buf());
        let record = vec![b'x'; 64 * 1024];
        for _ in 0..64 {
            sink.write(false, &record).unwrap();
        }
        let files = std::fs::read_dir(fixture.path())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<_>>();
        assert!(files.len() <= EVENT_ARCHIVES + 1);
        assert!(files
            .iter()
            .all(|path| path.metadata().unwrap().len() <= EVENT_FILE_BYTES));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                fixture.path().metadata().unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert!(files
                .iter()
                .all(|path| path.metadata().unwrap().permissions().mode() & 0o777 == 0o600));
        }
    }

    #[test]
    fn retention_purges_expired_files_deterministically() {
        let fixture = tempfile::tempdir().unwrap();
        let mut sink = FileSink::new(fixture.path().to_path_buf());
        sink.write(false, b"{}\n").unwrap();
        let path = fixture.path().join(EVENTS_FILE);
        let old = SystemTime::now() - EVENT_RETENTION - Duration::from_secs(1);
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(old))
            .unwrap();
        sink.purge(SystemTime::now()).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn storage_failure_is_bounded_and_non_panicking() {
        let fixture = tempfile::tempdir().unwrap();
        let occupied = fixture.path().join("occupied");
        std::fs::write(&occupied, b"file").unwrap();
        let diagnostics = diagnostics_at(&occupied);
        let result = diagnostics.record(DiagnosticEvent::new(
            DiagnosticCategory::Lifecycle,
            DiagnosticLevel::Error,
            DiagnosticCode::RuntimeLog,
        ));
        assert!(matches!(result, Err(DiagnosticError::Storage(_))));
    }

    #[test]
    fn support_export_is_allowlisted_bounded_and_schema_validated() {
        let fixture = tempfile::tempdir().unwrap();
        let diagnostics = diagnostics_at(fixture.path());
        diagnostics
            .record(DiagnosticEvent::new(
                DiagnosticCategory::Lifecycle,
                DiagnosticLevel::Info,
                DiagnosticCode::Startup,
            ))
            .unwrap();
        let mut events = OpenOptions::new()
            .append(true)
            .open(fixture.path().join(EVENTS_FILE))
            .unwrap();
        writeln!(
            events,
            "{{\"schema_version\":1,\"timestamp_unix_ms\":1,\"session_id\":\"s-0000000000000001\",\"category\":\"lifecycle\",\"level\":\"info\",\"code\":\"startup\",\"secret\":\"private transcript\"}}"
        )
        .unwrap();
        writeln!(events, "{{\"secret\":\"malformed private transcript\"}}").unwrap();
        std::fs::write(fixture.path().join("private.txt"), b"must not export").unwrap();
        let export = diagnostics.export().unwrap();
        assert_eq!(export.files.len(), 1);
        assert_eq!(export.files[0].name, EVENTS_FILE);
        assert!(!export.files[0].contents.contains("must not export"));
        assert!(!export.files[0].contents.contains("private transcript"));
        assert!(!export.files[0].contents.contains("\"secret\""));
        assert!(export.files[0].contents.len() <= MAX_EXPORT_BYTES);
    }

    #[test]
    fn recording_and_transcription_stages_share_one_opaque_correlation() {
        let fixture = tempfile::tempdir().unwrap();
        let diagnostics = diagnostics_at(fixture.path());
        let correlation = diagnostics.correlation_id();
        for (category, code) in [
            (
                DiagnosticCategory::Recording,
                DiagnosticCode::RecordingStarted,
            ),
            (
                DiagnosticCategory::Recording,
                DiagnosticCode::RecordingStopped,
            ),
            (
                DiagnosticCategory::Transcription,
                DiagnosticCode::TranscriptionStarted,
            ),
            (
                DiagnosticCategory::Transcription,
                DiagnosticCode::TranscriptionCompleted,
            ),
        ] {
            diagnostics
                .record(
                    DiagnosticEvent::new(category, DiagnosticLevel::Info, code)
                        .correlated(&correlation),
                )
                .unwrap();
        }
        let records = std::fs::read_to_string(fixture.path().join(EVENTS_FILE)).unwrap();
        assert_eq!(records.matches(correlation.as_str()).count(), 4);
    }

    #[test]
    fn categories_and_codes_serialize_to_stable_names() {
        let fixture = tempfile::tempdir().unwrap();
        let diagnostics = diagnostics_at(fixture.path());
        let encoded = diagnostics
            .record(DiagnosticEvent::new(
                DiagnosticCategory::Bridge,
                DiagnosticLevel::Warning,
                DiagnosticCode::SwiftShellFailure,
            ))
            .unwrap();
        let value: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["category"], "bridge");
        assert_eq!(value["level"], "warning");
        assert_eq!(value["code"], "swift_shell_failure");
    }

    #[test]
    fn swift_ffi_codes_are_closed_and_contain_no_dynamic_text() {
        assert_eq!(
            swift_failure_code(2),
            (
                DiagnosticCategory::Lifecycle,
                DiagnosticCode::SwiftLoginItemFailed
            )
        );
        assert_eq!(
            swift_failure_code(6),
            (
                DiagnosticCategory::Lifecycle,
                DiagnosticCode::SwiftSingleInstanceIdentityFailed
            )
        );
        assert_eq!(
            swift_failure_code(u8::MAX),
            (
                DiagnosticCategory::Bridge,
                DiagnosticCode::SwiftShellFailure
            )
        );
    }
}

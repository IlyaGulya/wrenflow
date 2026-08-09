//! Deterministic, local-only support bundle generation.
//!
//! The bundle consumes the structured diagnostics export instead of reading
//! logs, history, recordings or model/config files directly.

use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::diagnostics::{
    collect_diagnostics, emit_diagnostic, DiagnosticCategory, DiagnosticCode, DiagnosticEvent,
    DiagnosticExport, DiagnosticExportFile, DiagnosticLevel,
};
use crate::recovery::RecoverySnapshot;

pub const SUPPORT_BUNDLE_SCHEMA_VERSION: u16 = 1;
pub const SUPPORT_BUNDLE_EXTENSION: &str = "wrenflow-support.json";
const MAX_SUPPORT_BUNDLE_BYTES: usize = 3 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SupportUpdateState {
    #[default]
    Idle,
    Checking,
    Available,
    Downloading,
    ReadyToInstall,
    Installing,
    RecoveryRequired,
    Failed,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SupportContext {
    pub recovery: RecoverySnapshot,
    pub update_state: SupportUpdateState,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SupportBundle {
    pub schema_version: u16,
    pub generated_at_unix_ms: u64,
    pub app_version: String,
    pub os_family: String,
    pub architecture: String,
    pub remote_telemetry: String,
    pub recovery: RecoverySnapshot,
    pub update_state: SupportUpdateState,
    pub diagnostics: Vec<DiagnosticExportFile>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SupportBundleArtifact {
    pub suggested_filename: String,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SupportBundleFailureCode {
    DiagnosticsUnavailable,
    InvalidDiagnostics,
    SizeLimit,
    StorageUnavailable,
}

#[derive(Debug, thiserror::Error)]
pub enum SupportBundleError {
    #[error("diagnostic export failed")]
    Diagnostics,
    #[error("support bundle contains an invalid diagnostic record")]
    InvalidDiagnostic,
    #[error("support bundle exceeds its fixed size limit")]
    TooLarge,
    #[error("support bundle serialization failed")]
    Serialization,
    #[error("support bundle storage operation failed ({0:?})")]
    Storage(std::io::ErrorKind),
}

impl From<std::io::Error> for SupportBundleError {
    fn from(error: std::io::Error) -> Self {
        Self::Storage(error.kind())
    }
}

impl SupportBundleError {
    #[must_use]
    pub const fn code(&self) -> SupportBundleFailureCode {
        match self {
            Self::Diagnostics => SupportBundleFailureCode::DiagnosticsUnavailable,
            Self::InvalidDiagnostic | Self::Serialization => {
                SupportBundleFailureCode::InvalidDiagnostics
            }
            Self::TooLarge => SupportBundleFailureCode::SizeLimit,
            Self::Storage(_) => SupportBundleFailureCode::StorageUnavailable,
        }
    }
}

/// Build the in-memory bundle consumed by an explicit local export effect.
/// Nothing is uploaded, and no path from the local machine enters the result.
pub fn collect_support_bundle(
    context: SupportContext,
) -> Result<SupportBundle, SupportBundleError> {
    let diagnostics = collect_diagnostics().map_err(|_| SupportBundleError::Diagnostics)?;
    support_bundle_from_export(context, diagnostics)
}

/// Encode a stable JSON document suitable for an explicit local save
/// destination. Field and diagnostic-file ordering are deterministic.
pub fn encode_support_bundle(context: SupportContext) -> Result<Vec<u8>, SupportBundleError> {
    let bundle = collect_support_bundle(context)?;
    encode_bundle(&bundle)
}

pub fn prepare_support_bundle(
    context: SupportContext,
) -> Result<SupportBundleArtifact, SupportBundleError> {
    let bundle = collect_support_bundle(context)?;
    let suggested_filename = format!(
        "Wrenflow-Support-{}.{}",
        bundle.generated_at_unix_ms, SUPPORT_BUNDLE_EXTENSION
    );
    let bytes = encode_bundle(&bundle)?;
    Ok(SupportBundleArtifact {
        suggested_filename,
        bytes,
    })
}

/// Export after an explicit user action without requiring a native save-panel
/// bridge. The closed artifact name is placed in the user's Downloads folder;
/// the full local path is never added to the bundle or diagnostics.
pub fn export_support_bundle_to_downloads(
    context: SupportContext,
) -> Result<SupportBundleArtifact, SupportBundleError> {
    let artifact = prepare_support_bundle(context)?;
    let downloads =
        dirs::download_dir().ok_or(SupportBundleError::Storage(std::io::ErrorKind::NotFound))?;
    if !downloads.is_dir() || downloads.is_symlink() {
        return Err(SupportBundleError::Storage(
            std::io::ErrorKind::PermissionDenied,
        ));
    }
    let destination = downloads.join(&artifact.suggested_filename);
    let result = atomic_write_private(&destination, &artifact.bytes);
    emit_diagnostic(DiagnosticEvent::new(
        DiagnosticCategory::Lifecycle,
        if result.is_ok() {
            DiagnosticLevel::Info
        } else {
            DiagnosticLevel::Error
        },
        if result.is_ok() {
            DiagnosticCode::SupportBundleCreated
        } else {
            DiagnosticCode::SupportBundleFailed
        },
    ));
    result?;
    Ok(artifact)
}

pub fn write_support_bundle(
    destination: &Path,
    context: SupportContext,
) -> Result<(), SupportBundleError> {
    let result =
        encode_support_bundle(context).and_then(|bytes| atomic_write_private(destination, &bytes));
    emit_diagnostic(DiagnosticEvent::new(
        DiagnosticCategory::Lifecycle,
        if result.is_ok() {
            DiagnosticLevel::Info
        } else {
            DiagnosticLevel::Error
        },
        if result.is_ok() {
            DiagnosticCode::SupportBundleCreated
        } else {
            DiagnosticCode::SupportBundleFailed
        },
    ));
    result
}

fn support_bundle_from_export(
    context: SupportContext,
    export: DiagnosticExport,
) -> Result<SupportBundle, SupportBundleError> {
    let mut diagnostics = export
        .files
        .into_iter()
        .filter_map(sanitize_diagnostic_file)
        .collect::<Result<Vec<_>, _>>()?;
    diagnostics.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(SupportBundle {
        schema_version: SUPPORT_BUNDLE_SCHEMA_VERSION,
        generated_at_unix_ms: export.generated_at_unix_ms,
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        os_family: std::env::consts::OS.to_string(),
        architecture: std::env::consts::ARCH.to_string(),
        remote_telemetry: "disabled".to_string(),
        recovery: context.recovery,
        update_state: context.update_state,
        diagnostics,
    })
}

fn sanitize_diagnostic_file(
    file: DiagnosticExportFile,
) -> Option<Result<DiagnosticExportFile, SupportBundleError>> {
    if !is_allowed_diagnostic_name(&file.name) {
        return None;
    }
    let mut records = Vec::new();
    for line in file.contents.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let record = match serde_json::from_str::<BundleDiagnosticRecord>(line) {
            Ok(record) if record.is_safe() => record,
            _ => continue,
        };
        let encoded = match serde_json::to_string(&record) {
            Ok(encoded) => encoded,
            Err(_) => return Some(Err(SupportBundleError::Serialization)),
        };
        records.push(encoded);
    }
    if records.is_empty() {
        return None;
    }
    Some(Ok(DiagnosticExportFile {
        name: file.name,
        contents: records.join("\n"),
    }))
}

fn is_allowed_diagnostic_name(name: &str) -> bool {
    matches!(
        name,
        "events.ndjson"
            | "events.1.ndjson"
            | "events.2.ndjson"
            | "events.3.ndjson"
            | "crashes.ndjson"
            | "crashes.1.ndjson"
            | "crashes.2.ndjson"
    )
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BundleDiagnosticRecord {
    schema_version: u16,
    timestamp_unix_ms: u64,
    session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    correlation_id: Option<String>,
    category: DiagnosticCategory,
    level: DiagnosticLevel,
    code: DiagnosticCode,
    #[serde(skip_serializing_if = "Option::is_none")]
    source: Option<BundleSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    startup: Option<BundleStartup>,
}

impl BundleDiagnosticRecord {
    fn is_safe(&self) -> bool {
        let session = self
            .session_id
            .strip_prefix("s-")
            .is_some_and(|value| value.len() == 16 && value.bytes().all(is_lower_hex));
        let correlation = self.correlation_id.as_ref().is_none_or(|value| {
            value
                .strip_prefix(&format!("{}-", self.session_id))
                .is_some_and(|suffix| suffix.len() == 8 && suffix.bytes().all(is_lower_hex))
        });
        let source = self.source.as_ref().is_none_or(BundleSource::is_safe);
        let startup = self.startup.as_ref().is_none_or(BundleStartup::is_safe);
        self.schema_version == 1 && session && correlation && source && startup
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BundleSource {
    target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    line: Option<u32>,
}

impl BundleSource {
    fn is_safe(&self) -> bool {
        (self.target == "dependency"
            || self.target.starts_with("wrenflow_")
            || self.target.starts_with("source::"))
            && self.target.len() <= 128
            && self
                .target
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b':' | b'-'))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BundleStartup {
    app_version: String,
    os_family: String,
    architecture: String,
    build_profile: String,
    remote_telemetry: String,
}

impl BundleStartup {
    fn is_safe(&self) -> bool {
        self.remote_telemetry == "disabled"
            && matches!(self.os_family.as_str(), "macos" | "ios")
            && matches!(self.architecture.as_str(), "aarch64" | "x86_64")
            && matches!(self.build_profile.as_str(), "debug" | "release")
            && self.app_version.len() <= 32
            && self
                .app_version
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+'))
    }
}

fn encode_bundle(bundle: &SupportBundle) -> Result<Vec<u8>, SupportBundleError> {
    let mut bytes =
        serde_json::to_vec_pretty(bundle).map_err(|_| SupportBundleError::Serialization)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_SUPPORT_BUNDLE_BYTES {
        return Err(SupportBundleError::TooLarge);
    }
    Ok(bytes)
}

fn atomic_write_private(destination: &Path, bytes: &[u8]) -> Result<(), SupportBundleError> {
    let parent = destination.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let temporary = destination.with_file_name(format!(
        ".{}.tmp-{}",
        destination
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("wrenflow-support"),
        std::process::id()
    ));
    let result = (|| -> Result<(), SupportBundleError> {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temporary)?;
        set_private_file(&file)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, destination)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
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

fn is_lower_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn safe_record() -> String {
        serde_json::json!({
            "schema_version": 1,
            "timestamp_unix_ms": 42,
            "session_id": "s-0000000000000001",
            "category": "lifecycle",
            "level": "error",
            "code": "rust_panic"
        })
        .to_string()
    }

    fn export(contents: String) -> DiagnosticExport {
        DiagnosticExport {
            schema_version: 1,
            generated_at_unix_ms: 42,
            files: vec![DiagnosticExportFile {
                name: "events.ndjson".to_string(),
                contents,
            }],
        }
    }

    #[test]
    fn bundle_is_deterministic_and_contains_no_paths_or_product_content() {
        let context = SupportContext {
            recovery: RecoverySnapshot::default(),
            update_state: SupportUpdateState::Failed,
        };
        let first = support_bundle_from_export(context.clone(), export(safe_record())).unwrap();
        let second = support_bundle_from_export(context, export(safe_record())).unwrap();
        let first = encode_bundle(&first).unwrap();
        let second = encode_bundle(&second).unwrap();
        assert_eq!(first, second);
        let text = String::from_utf8(first).unwrap();
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("private transcript"));
        assert!(!text.contains("recording.ogg"));
        assert!(text.contains("\"remote_telemetry\": \"disabled\""));
    }

    #[test]
    fn defense_in_depth_drops_unknown_secret_fields_and_unlisted_files() {
        let malicious = format!(
            "{}\n{}",
            safe_record(),
            serde_json::json!({
                "schema_version": 1,
                "timestamp_unix_ms": 43,
                "session_id": "s-0000000000000001",
                "category": "history",
                "level": "error",
                "code": "runtime_log",
                "transcript": "private transcript raven"
            })
        );
        let mut export = export(malicious);
        export.files.push(DiagnosticExportFile {
            name: "history.sqlite".to_string(),
            contents: "private transcript raven".to_string(),
        });
        let bundle = support_bundle_from_export(SupportContext::default(), export).unwrap();
        let encoded = String::from_utf8(encode_bundle(&bundle).unwrap()).unwrap();
        assert!(!encoded.contains("private transcript raven"));
        assert!(!encoded.contains("history.sqlite"));
        assert_eq!(bundle.diagnostics.len(), 1);
        assert_eq!(bundle.diagnostics[0].contents.lines().count(), 1);
    }

    #[test]
    fn support_file_is_atomic_private_and_bounded() {
        let fixture = tempfile::tempdir().unwrap();
        let destination = fixture.path().join(SUPPORT_BUNDLE_EXTENSION);
        let bundle =
            support_bundle_from_export(SupportContext::default(), export(safe_record())).unwrap();
        let bytes = encode_bundle(&bundle).unwrap();
        atomic_write_private(&destination, &bytes).unwrap();
        assert_eq!(std::fs::read(&destination).unwrap(), bytes);
        assert!(bytes.len() < MAX_SUPPORT_BUNDLE_BYTES);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                destination.metadata().unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn artifact_name_is_closed_and_contains_no_local_path() {
        let bundle =
            support_bundle_from_export(SupportContext::default(), export(safe_record())).unwrap();
        let artifact = SupportBundleArtifact {
            suggested_filename: format!(
                "Wrenflow-Support-{}.{}",
                bundle.generated_at_unix_ms, SUPPORT_BUNDLE_EXTENSION
            ),
            bytes: encode_bundle(&bundle).unwrap(),
        };
        assert_eq!(
            artifact.suggested_filename,
            "Wrenflow-Support-42.wrenflow-support.json"
        );
        assert!(!artifact.suggested_filename.contains('/'));
    }
}

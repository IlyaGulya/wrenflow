//! Authenticated current-line GPUI updater.
//!
//! GitHub is release discovery and transport only. A candidate is accepted
//! only when its API-provided SHA-256 digest, exact asset identity, notarized
//! Developer ID signature, bundle/support contract and embedded supply-chain
//! pins all agree. No URL from the feed is ever exposed as an open-browser
//! action.

use std::collections::BTreeSet;
use std::fs::{File, OpenOptions};
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::Mutex;

use reqwest::{header, StatusCode, Url};
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use crate::data_paths::current_data_paths;
use crate::diagnostics::{
    emit_diagnostic, DiagnosticCategory, DiagnosticCode, DiagnosticEvent, DiagnosticLevel,
};

pub const UPDATE_FEED_URL: &str =
    "https://api.github.com/repos/IlyaGulya/wrenflow/releases?per_page=20";
pub const MINIMUM_GPUI_VERSION: &str = "0.3.0";
const RELEASE_ASSET_NAME: &str = "Wrenflow.dmg";
const MAX_FEED_BYTES: usize = 2 * 1024 * 1024;
const MAX_RELEASES: usize = 50;
const MAX_DMG_BYTES: u64 = 512 * 1024 * 1024;
const MAX_RETAINED_DMGS: usize = 1;
const EXPECTED_BUNDLE_ID: &str = "me.gulya.wrenflow";
const EXPECTED_TEAM_ID: &str = "T4LV8K9BGV";
const EXPECTED_ARCH: &str = "arm64";
const EXPECTED_MIN_MACOS: &str = "14.0";
const TRANSACTION_FILE: &str = "update-transaction.json";
const TRANSACTION_SCHEMA_VERSION: u16 = 1;
const PINNED_SUPPLY_CHAIN: &str = include_str!("../../../supply-chain/pins.json");

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateChannel {
    #[default]
    Stable,
    Beta,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateFailureCode {
    Offline,
    RateLimited,
    ServiceUnavailable,
    MalformedMetadata,
    DuplicateRelease,
    UnsupportedReleaseLine,
    UnexpectedHost,
    MissingArtifact,
    AmbiguousArtifact,
    InvalidArtifactMetadata,
    PartialDownload,
    ArtifactTooLarge,
    ChecksumMismatch,
    SignatureMismatch,
    NotarizationMissing,
    BundleMismatch,
    SupportMismatch,
    SupplyChainMismatch,
    StagingFailed,
    AtomicSwapFailed,
    RecoveryRequired,
    UnsupportedInstallation,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpdateError {
    pub code: UpdateFailureCode,
    pub retryable: bool,
    pub retry_after_seconds: Option<u64>,
}

impl UpdateError {
    const fn permanent(code: UpdateFailureCode) -> Self {
        Self {
            code,
            retryable: false,
            retry_after_seconds: None,
        }
    }

    const fn retryable(code: UpdateFailureCode) -> Self {
        Self {
            code,
            retryable: true,
            retry_after_seconds: None,
        }
    }
}

impl std::fmt::Display for UpdateError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "update failed ({:?})", self.code)
    }
}

impl std::error::Error for UpdateError {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateCheckOutcome {
    UpToDate,
    Available(UpdateCandidate),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpdateCandidate {
    pub version: String,
    pub channel: UpdateChannel,
    pub published_at_iso: Option<String>,
    pub size_bytes: u64,
    release_id: u64,
    asset_id: u64,
    sha256: String,
    download_url: Url,
}

impl UpdateCandidate {
    #[must_use]
    pub fn sha256(&self) -> &str {
        &self.sha256
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DownloadedUpdate {
    pub candidate: UpdateCandidate,
    pub dmg_path: PathBuf,
}

#[derive(Default)]
pub struct UpdateSession {
    candidate: Mutex<Option<UpdateCandidate>>,
    downloaded: Mutex<Option<DownloadedUpdate>>,
    prepared: Mutex<Option<PreparedUpdate>>,
}

impl UpdateSession {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn check(
        &self,
        current_version: &str,
        channel: UpdateChannel,
    ) -> Result<UpdateCheckOutcome, UpdateError> {
        let outcome = check_for_update(current_version, channel).await?;
        let candidate = match &outcome {
            UpdateCheckOutcome::Available(candidate) => Some(candidate.clone()),
            UpdateCheckOutcome::UpToDate => None,
        };
        *self
            .candidate
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))? = candidate;
        *self
            .downloaded
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))? = None;
        *self
            .prepared
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))? = None;
        Ok(outcome)
    }

    pub async fn download_available(&self) -> Result<DownloadedUpdate, UpdateError> {
        let candidate = self
            .candidate
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?
            .clone()
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::MissingArtifact))?;
        let downloaded = download_update(candidate).await?;
        *self
            .downloaded
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))? =
            Some(downloaded.clone());
        Ok(downloaded)
    }

    pub fn prepare_downloaded(&self) -> Result<PreparedUpdate, UpdateError> {
        let downloaded = self
            .downloaded
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?
            .take()
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::PartialDownload))?;
        let prepared = prepare_update(downloaded)?;
        *self
            .prepared
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))? =
            Some(prepared.clone());
        Ok(prepared)
    }

    pub fn schedule_prepared(&self) -> Result<String, UpdateError> {
        let mut slot = self
            .prepared
            .lock()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        let prepared = slot
            .take()
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::RecoveryRequired))?;
        if let Err(error) = schedule_prepared_update(&prepared) {
            *slot = Some(prepared);
            return Err(error);
        }
        Ok(prepared.version)
    }
}

#[cfg(target_os = "macos")]
pub fn current_installed_version() -> Result<String, UpdateError> {
    let (_, _, installed_app) = installed_app_location()?;
    bundle_version(&installed_app)
}

#[cfg(not(target_os = "macos"))]
pub fn current_installed_version() -> Result<String, UpdateError> {
    Err(UpdateError::permanent(
        UpdateFailureCode::UnsupportedInstallation,
    ))
}

#[derive(Clone, Debug, Deserialize)]
struct FeedRelease {
    id: u64,
    tag_name: String,
    draft: bool,
    prerelease: bool,
    published_at: Option<String>,
    assets: Vec<FeedAsset>,
}

#[derive(Clone, Debug, Deserialize)]
struct FeedAsset {
    id: u64,
    name: String,
    content_type: String,
    size: u64,
    digest: Option<String>,
    browser_download_url: String,
}

/// Explicit checks only: the updater never polls in the background and sends
/// no telemetry, device identifier or product content.
pub async fn check_for_update(
    current_version: &str,
    channel: UpdateChannel,
) -> Result<UpdateCheckOutcome, UpdateError> {
    let client = update_http_client()?;
    let response = client
        .get(UPDATE_FEED_URL)
        .header(header::ACCEPT, "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .map_err(|_| offline_error())?;
    let status = response.status();
    if !status.is_success() {
        return Err(http_status_error(status, response.headers()));
    }
    let bytes = read_bounded_response(response, MAX_FEED_BYTES).await?;
    select_release(&bytes, current_version, channel)
}

pub async fn download_update(candidate: UpdateCandidate) -> Result<DownloadedUpdate, UpdateError> {
    let client = update_http_client()?;
    if !is_expected_release_asset_url(&candidate.download_url, &candidate.version) {
        return Err(UpdateError::permanent(UpdateFailureCode::UnexpectedHost));
    }
    let response = client
        .get(candidate.download_url.clone())
        .header(header::ACCEPT, "application/octet-stream")
        .send()
        .await
        .map_err(|_| offline_error())?;
    if !response.status().is_success() {
        return Err(http_status_error(response.status(), response.headers()));
    }
    if !is_allowed_download_redirect(response.url()) {
        return Err(UpdateError::permanent(UpdateFailureCode::UnexpectedHost));
    }
    if response
        .content_length()
        .is_some_and(|length| length != candidate.size_bytes)
    {
        return Err(UpdateError::permanent(UpdateFailureCode::PartialDownload));
    }

    let paths = current_data_paths();
    std::fs::create_dir_all(&paths.updates)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    set_private_directory(&paths.updates)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    purge_downloaded_dmgs(&paths.updates, Some(&candidate.version))?;
    let destination = paths.updates.join(format!(
        "Wrenflow-{}.dmg",
        safe_version_filename(&candidate.version)?
    ));
    let mut writer = DownloadWriter::new(&destination, &candidate)?;
    let mut response = response;
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::PartialDownload))?
    {
        writer.write_chunk(&chunk)?;
    }
    writer.finish()?;
    emit_diagnostic(DiagnosticEvent::new(
        DiagnosticCategory::Updates,
        DiagnosticLevel::Info,
        DiagnosticCode::UpdateArtifactVerified,
    ));
    Ok(DownloadedUpdate {
        candidate,
        dmg_path: destination,
    })
}

fn update_http_client() -> Result<reqwest::Client, UpdateError> {
    reqwest::Client::builder()
        .user_agent(concat!("Wrenflow/", env!("CARGO_PKG_VERSION")))
        .https_only(true)
        .timeout(std::time::Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() > 5 {
                return attempt.error("too many updater redirects");
            }
            if is_allowed_download_redirect(attempt.url()) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .build()
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::ServiceUnavailable))
}

async fn read_bounded_response(
    mut response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, UpdateError> {
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(UpdateError::permanent(UpdateFailureCode::MalformedMetadata));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| offline_error())? {
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err(UpdateError::permanent(UpdateFailureCode::MalformedMetadata));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

fn select_release(
    payload: &[u8],
    current_version: &str,
    channel: UpdateChannel,
) -> Result<UpdateCheckOutcome, UpdateError> {
    let releases: Vec<FeedRelease> = serde_json::from_slice(payload)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::MalformedMetadata))?;
    if releases.len() > MAX_RELEASES {
        return Err(UpdateError::permanent(UpdateFailureCode::MalformedMetadata));
    }
    let current = Version::parse(current_version)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::UnsupportedReleaseLine))?;
    let minimum = Version::parse(MINIMUM_GPUI_VERSION)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::UnsupportedReleaseLine))?;
    if current < minimum {
        return Err(UpdateError::permanent(
            UpdateFailureCode::UnsupportedReleaseLine,
        ));
    }

    let mut seen = BTreeSet::new();
    let mut candidates = Vec::new();
    for release in releases.into_iter().filter(|release| !release.draft) {
        let version = release
            .tag_name
            .strip_prefix('v')
            .and_then(|value| Version::parse(value).ok())
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::MalformedMetadata))?;
        if release.tag_name != format!("v{version}") || release.prerelease == version.pre.is_empty()
        {
            return Err(UpdateError::permanent(UpdateFailureCode::MalformedMetadata));
        }
        if !seen.insert(version.clone()) {
            return Err(UpdateError::permanent(UpdateFailureCode::DuplicateRelease));
        }
        if version <= current || version < minimum || version.major != current.major {
            continue;
        }
        if matches!(channel, UpdateChannel::Stable) && release.prerelease {
            continue;
        }
        candidates.push(candidate_from_release(release, version)?);
    }
    candidates.sort_by(|left, right| {
        Version::parse(&left.version)
            .ok()
            .cmp(&Version::parse(&right.version).ok())
    });
    Ok(candidates
        .pop()
        .map_or(UpdateCheckOutcome::UpToDate, UpdateCheckOutcome::Available))
}

fn candidate_from_release(
    release: FeedRelease,
    version: Version,
) -> Result<UpdateCandidate, UpdateError> {
    let mut assets = release
        .assets
        .into_iter()
        .filter(|asset| asset.name == RELEASE_ASSET_NAME);
    let asset = assets
        .next()
        .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::MissingArtifact))?;
    if assets.next().is_some() {
        return Err(UpdateError::permanent(UpdateFailureCode::AmbiguousArtifact));
    }
    if !matches!(
        asset.content_type.as_str(),
        "application/octet-stream" | "application/x-apple-diskimage"
    ) || asset.size == 0
        || asset.size > MAX_DMG_BYTES
    {
        return Err(UpdateError::permanent(
            UpdateFailureCode::InvalidArtifactMetadata,
        ));
    }
    let sha256 = asset
        .digest
        .as_deref()
        .and_then(|digest| digest.strip_prefix("sha256:"))
        .filter(|digest| digest.len() == 64 && digest.bytes().all(is_lower_hex))
        .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::InvalidArtifactMetadata))?
        .to_string();
    let download_url = Url::parse(&asset.browser_download_url)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::UnexpectedHost))?;
    if !is_expected_release_asset_url(&download_url, &version.to_string()) {
        return Err(UpdateError::permanent(UpdateFailureCode::UnexpectedHost));
    }
    let published_at_iso = release.published_at.filter(|value| {
        value.len() <= 32
            && value.bytes().all(|byte| {
                byte.is_ascii_digit() || matches!(byte, b'-' | b':' | b'T' | b'Z' | b'.')
            })
    });
    Ok(UpdateCandidate {
        version: version.to_string(),
        channel: if version.pre.is_empty() {
            UpdateChannel::Stable
        } else {
            UpdateChannel::Beta
        },
        published_at_iso,
        size_bytes: asset.size,
        release_id: release.id,
        asset_id: asset.id,
        sha256,
        download_url,
    })
}

fn http_status_error(status: StatusCode, headers: &header::HeaderMap) -> UpdateError {
    if status == StatusCode::TOO_MANY_REQUESTS || status == StatusCode::FORBIDDEN {
        return UpdateError {
            code: UpdateFailureCode::RateLimited,
            retryable: true,
            retry_after_seconds: headers
                .get(header::RETRY_AFTER)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<u64>().ok())
                .map(|value| value.min(3_600)),
        };
    }
    UpdateError::retryable(UpdateFailureCode::ServiceUnavailable)
}

const fn offline_error() -> UpdateError {
    UpdateError::retryable(UpdateFailureCode::Offline)
}

fn is_expected_release_asset_url(url: &Url, version: &str) -> bool {
    url.scheme() == "https"
        && url.host_str() == Some("github.com")
        && url.query().is_none()
        && url.fragment().is_none()
        && url.path()
            == format!("/IlyaGulya/wrenflow/releases/download/v{version}/{RELEASE_ASSET_NAME}")
}

fn is_allowed_download_redirect(url: &Url) -> bool {
    url.scheme() == "https"
        && matches!(
            url.host_str(),
            Some("github.com")
                | Some("release-assets.githubusercontent.com")
                | Some("objects.githubusercontent.com")
        )
}

fn safe_version_filename(version: &str) -> Result<String, UpdateError> {
    let parsed = Version::parse(version)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::InvalidArtifactMetadata))?;
    let canonical = parsed.to_string();
    if canonical.len() > 64
        || !canonical
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+'))
    {
        return Err(UpdateError::permanent(
            UpdateFailureCode::InvalidArtifactMetadata,
        ));
    }
    Ok(canonical)
}

fn is_lower_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
}

struct DownloadWriter {
    temporary: PathBuf,
    destination: PathBuf,
    file: Option<File>,
    hasher: Sha256,
    written: u64,
    expected_size: u64,
    expected_sha256: String,
    complete: bool,
}

impl DownloadWriter {
    fn new(destination: &Path, candidate: &UpdateCandidate) -> Result<Self, UpdateError> {
        let temporary = destination.with_extension("dmg.partial");
        let _ = std::fs::remove_file(&temporary);
        let file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        set_private_file(&file)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        Ok(Self {
            temporary,
            destination: destination.to_path_buf(),
            file: Some(file),
            hasher: Sha256::new(),
            written: 0,
            expected_size: candidate.size_bytes,
            expected_sha256: candidate.sha256.clone(),
            complete: false,
        })
    }

    fn write_chunk(&mut self, chunk: &[u8]) -> Result<(), UpdateError> {
        self.written = self
            .written
            .checked_add(chunk.len() as u64)
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::ArtifactTooLarge))?;
        if self.written > self.expected_size || self.written > MAX_DMG_BYTES {
            return Err(UpdateError::permanent(UpdateFailureCode::ArtifactTooLarge));
        }
        self.file
            .as_mut()
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::PartialDownload))?
            .write_all(chunk)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::PartialDownload))?;
        self.hasher.update(chunk);
        Ok(())
    }

    fn finish(mut self) -> Result<(), UpdateError> {
        if self.written != self.expected_size {
            return Err(UpdateError::permanent(UpdateFailureCode::PartialDownload));
        }
        let actual = format!("{:x}", self.hasher.clone().finalize());
        if actual != self.expected_sha256 {
            return Err(UpdateError::permanent(UpdateFailureCode::ChecksumMismatch));
        }
        let file = self
            .file
            .take()
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::PartialDownload))?;
        file.sync_all()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        drop(file);
        std::fs::rename(&self.temporary, &self.destination)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        if let Some(parent) = self.destination.parent() {
            File::open(parent)
                .and_then(|directory| directory.sync_all())
                .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        }
        self.complete = true;
        Ok(())
    }
}

impl Drop for DownloadWriter {
    fn drop(&mut self) {
        if !self.complete {
            self.file.take();
            let _ = std::fs::remove_file(&self.temporary);
        }
    }
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreparedUpdate {
    pub version: String,
    token: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum InstallRoot {
    SystemApplications,
    UserApplications,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum TransactionPhase {
    Staging,
    Prepared,
    Swapped,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct UpdateTransaction {
    schema_version: u16,
    token: String,
    from_version: String,
    version: String,
    sha256: String,
    install_root: InstallRoot,
    phase: TransactionPhase,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TransactionRecoveryAction {
    RemoveInterruptedStaging,
    RemovePreparedCandidate,
    FinalizeInstalledCandidate,
    RecoveryRequired,
}

/// Verify the notarized DMG and its app, copy the candidate onto the installed
/// bundle's volume, and persist a private transaction before any replacement.
#[cfg(target_os = "macos")]
pub fn prepare_update(downloaded: DownloadedUpdate) -> Result<PreparedUpdate, UpdateError> {
    verify_downloaded_file(&downloaded)?;
    let (install_root, install_directory, installed_app) = installed_app_location()?;
    let token = format!(
        "{}-{}-{}",
        downloaded.candidate.release_id,
        downloaded.candidate.asset_id,
        &downloaded.candidate.sha256[..12]
    );
    if !token
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(UpdateError::permanent(
            UpdateFailureCode::InvalidArtifactMetadata,
        ));
    }
    let staging_name = staging_bundle_name(&token);
    let staged_app = install_directory.join(&staging_name);
    if staged_app.exists() {
        return Err(UpdateError::permanent(UpdateFailureCode::RecoveryRequired));
    }

    let updates = current_data_paths().updates;
    std::fs::create_dir_all(&updates)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    set_private_directory(&updates)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    let mut transaction = UpdateTransaction {
        schema_version: TRANSACTION_SCHEMA_VERSION,
        token: token.clone(),
        from_version: bundle_version(&installed_app)?,
        version: downloaded.candidate.version.clone(),
        sha256: downloaded.candidate.sha256.clone(),
        install_root,
        phase: TransactionPhase::Staging,
    };
    write_transaction(&transaction)?;
    let mount = updates.join(format!("mount-{token}"));
    if mount.exists() {
        return Err(UpdateError::permanent(UpdateFailureCode::RecoveryRequired));
    }
    std::fs::create_dir(&mount)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    set_private_directory(&mount)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;

    let result = (|| {
        verify_dmg(&downloaded.dmg_path)?;
        run_checked(
            "/usr/bin/hdiutil",
            &[
                "attach",
                "-readonly",
                "-nobrowse",
                "-mountpoint",
                path_string(&mount)?.as_str(),
                path_string(&downloaded.dmg_path)?.as_str(),
            ],
            UpdateFailureCode::SignatureMismatch,
        )?;
        let mounted_app = mount.join("Wrenflow.app");
        verify_app_bundle(&mounted_app, &downloaded.candidate.version)?;
        run_checked(
            "/usr/bin/ditto",
            &[
                path_string(&mounted_app)?.as_str(),
                path_string(&staged_app)?.as_str(),
            ],
            UpdateFailureCode::StagingFailed,
        )?;
        verify_app_bundle(&staged_app, &downloaded.candidate.version)?;
        verify_bundle_identity_only(&installed_app)?;
        Ok(())
    })();
    let _ = Command::new("/usr/bin/hdiutil")
        .args(["detach", path_string(&mount).unwrap_or_default().as_str()])
        .output();
    let _ = std::fs::remove_dir(&mount);
    if let Err(error) = result {
        // `?` deliberately keeps the Staging journal when cleanup fails, so
        // the next normal launch retries the exact, path-free cleanup instead
        // of orphaning an ambiguous app.
        remove_interrupted_staging_bundle(&staged_app)?;
        remove_transaction()?;
        return Err(error);
    }

    transaction.phase = TransactionPhase::Prepared;
    write_transaction(&transaction)?;
    emit_diagnostic(DiagnosticEvent::new(
        DiagnosticCategory::Updates,
        DiagnosticLevel::Info,
        DiagnosticCode::UpdatePrepared,
    ));
    Ok(PreparedUpdate {
        version: transaction.version,
        token,
    })
}

#[cfg(not(target_os = "macos"))]
pub fn prepare_update(_downloaded: DownloadedUpdate) -> Result<PreparedUpdate, UpdateError> {
    Err(UpdateError::permanent(
        UpdateFailureCode::UnsupportedInstallation,
    ))
}

/// Start a copy of this signed executable in a narrowly parsed helper mode.
/// The caller must then request normal typed app shutdown; the helper waits for
/// that exact PID before swapping bundles.
pub fn schedule_prepared_update(prepared: &PreparedUpdate) -> Result<(), UpdateError> {
    let executable = std::env::current_exe()
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    Command::new(executable)
        .arg("--wrenflow-update-helper")
        .arg(std::process::id().to_string())
        .arg(&prepared.token)
        .spawn()
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    Ok(())
}

/// Return `None` for normal app launches. Helper invocations accept only a PID
/// and the closed transaction token; paths and URLs cannot be injected.
pub fn run_update_helper_from_args<I, S>(arguments: I) -> Option<Result<(), UpdateError>>
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
        .position(|argument| argument == "--wrenflow-update-helper")?;
    let result = (|| {
        if arguments.len() != position + 3 {
            return Err(UpdateError::permanent(
                UpdateFailureCode::InvalidArtifactMetadata,
            ));
        }
        let pid = arguments[position + 1]
            .parse::<u32>()
            .map_err(|_| UpdateError::permanent(UpdateFailureCode::InvalidArtifactMetadata))?;
        let token = &arguments[position + 2];
        if token.len() > 96
            || !token
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err(UpdateError::permanent(
                UpdateFailureCode::InvalidArtifactMetadata,
            ));
        }
        run_update_helper(pid, token)
    })();
    Some(result)
}

#[cfg(target_os = "macos")]
fn run_update_helper(pid: u32, token: &str) -> Result<(), UpdateError> {
    let mut transaction = read_transaction()?;
    if transaction.token != token || !matches!(transaction.phase, TransactionPhase::Prepared) {
        return Err(UpdateError::permanent(UpdateFailureCode::RecoveryRequired));
    }
    wait_for_process_exit(pid)?;
    let install_directory = install_directory(transaction.install_root)?;
    let installed_app = install_directory.join("Wrenflow.app");
    let staged_app = install_directory.join(staging_bundle_name(token));
    verify_app_bundle(&installed_app, &transaction.from_version)?;
    verify_app_bundle(&staged_app, &transaction.version)?;
    atomic_swap(&staged_app, &installed_app)?;
    transaction.phase = TransactionPhase::Swapped;
    write_transaction(&transaction)?;
    let launch = Command::new("/usr/bin/open")
        .arg(&installed_app)
        .spawn()
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::AtomicSwapFailed));
    if launch.is_err() {
        let _ = atomic_swap(&staged_app, &installed_app);
        transaction.phase = TransactionPhase::Prepared;
        let _ = write_transaction(&transaction);
        return launch.map(|_| ());
    }
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn run_update_helper(_pid: u32, _token: &str) -> Result<(), UpdateError> {
    Err(UpdateError::permanent(
        UpdateFailureCode::UnsupportedInstallation,
    ))
}

/// Called only after the updated runtime and native shell report ready. The old
/// current-line app is then moved to Trash; there is no user-facing rollback.
#[cfg(target_os = "macos")]
pub fn finalize_update_after_ready() -> Result<bool, UpdateError> {
    let transaction = match read_transaction() {
        Ok(transaction) => transaction,
        Err(_) if !transaction_path().exists() => return Ok(false),
        Err(error) => return Err(error),
    };
    let install_directory = install_directory(transaction.install_root)?;
    let installed_app = install_directory.join("Wrenflow.app");
    let staged_old_app = install_directory.join(staging_bundle_name(&transaction.token));
    let installed_version = bundle_version(&installed_app).ok();
    let staged_version = bundle_version(&staged_old_app).ok();
    match classify_transaction(
        &transaction,
        installed_version.as_deref(),
        staged_version.as_deref(),
    ) {
        TransactionRecoveryAction::RemoveInterruptedStaging => {
            let mount = current_data_paths()
                .updates
                .join(format!("mount-{}", transaction.token));
            if mount.exists() {
                let _ = Command::new("/usr/bin/hdiutil")
                    .arg("detach")
                    .arg(&mount)
                    .output();
                let _ = std::fs::remove_dir(&mount);
            }
            remove_interrupted_staging_bundle(&staged_old_app)?;
            remove_transaction()?;
            purge_downloaded_dmgs(&current_data_paths().updates, None)?;
            Ok(false)
        }
        TransactionRecoveryAction::FinalizeInstalledCandidate => {
            verify_app_bundle(&installed_app, &transaction.version)?;
            verify_bundle_identity_only(&staged_old_app)?;
            run_checked(
                "/usr/bin/trash",
                &[path_string(&staged_old_app)?.as_str()],
                UpdateFailureCode::StagingFailed,
            )?;
            remove_transaction()?;
            remove_downloaded_dmg(&transaction.version);
            emit_diagnostic(DiagnosticEvent::new(
                DiagnosticCategory::Updates,
                DiagnosticLevel::Info,
                DiagnosticCode::UpdateCompleted,
            ));
            Ok(true)
        }
        TransactionRecoveryAction::RemovePreparedCandidate => {
            verify_app_bundle(&staged_old_app, &transaction.version)?;
            run_checked(
                "/usr/bin/trash",
                &[path_string(&staged_old_app)?.as_str()],
                UpdateFailureCode::StagingFailed,
            )?;
            remove_transaction()?;
            remove_downloaded_dmg(&transaction.version);
            Ok(false)
        }
        TransactionRecoveryAction::RecoveryRequired => {
            Err(UpdateError::permanent(UpdateFailureCode::RecoveryRequired))
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn finalize_update_after_ready() -> Result<bool, UpdateError> {
    Ok(false)
}

fn verify_downloaded_file(downloaded: &DownloadedUpdate) -> Result<(), UpdateError> {
    let metadata = downloaded
        .dmg_path
        .metadata()
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::PartialDownload))?;
    if !metadata.is_file() || metadata.len() != downloaded.candidate.size_bytes {
        return Err(UpdateError::permanent(UpdateFailureCode::PartialDownload));
    }
    let actual = sha256_file(&downloaded.dmg_path)?;
    if actual != downloaded.candidate.sha256 {
        return Err(UpdateError::permanent(UpdateFailureCode::ChecksumMismatch));
    }
    Ok(())
}

fn verify_dmg(path: &Path) -> Result<(), UpdateError> {
    run_checked(
        "/usr/bin/hdiutil",
        &["verify", path_string(path)?.as_str()],
        UpdateFailureCode::SignatureMismatch,
    )?;
    run_checked(
        "/usr/bin/codesign",
        &["--verify", "--strict", path_string(path)?.as_str()],
        UpdateFailureCode::SignatureMismatch,
    )?;
    run_checked(
        "/usr/bin/xcrun",
        &["stapler", "validate", path_string(path)?.as_str()],
        UpdateFailureCode::NotarizationMissing,
    )?;
    run_checked(
        "/usr/sbin/spctl",
        &[
            "--assess",
            "--type",
            "open",
            "--context",
            "context:primary-signature",
            path_string(path)?.as_str(),
        ],
        UpdateFailureCode::NotarizationMissing,
    )?;
    Ok(())
}

fn verify_app_bundle(app: &Path, version: &str) -> Result<(), UpdateError> {
    verify_bundle_identity_only(app)?;
    if bundle_version(app)? != version {
        return Err(UpdateError::permanent(UpdateFailureCode::BundleMismatch));
    }
    let binary = app.join("Contents/MacOS/wrenflow");
    let shell = app.join("Contents/Frameworks/libWrenflowShell.dylib");
    let ort = app.join("Contents/MacOS/libonnxruntime.dylib");
    for artifact in [&binary, &shell, &ort] {
        let arch = command_text(
            "/usr/bin/lipo",
            &["-archs", path_string(artifact)?.as_str()],
            UpdateFailureCode::SupportMismatch,
        )?;
        if arch.trim() != EXPECTED_ARCH {
            return Err(UpdateError::permanent(UpdateFailureCode::SupportMismatch));
        }
        let loads = command_text(
            "/usr/bin/otool",
            &["-l", path_string(artifact)?.as_str()],
            UpdateFailureCode::SupportMismatch,
        )?;
        if !loads
            .lines()
            .any(|line| line.trim() == format!("minos {EXPECTED_MIN_MACOS}"))
        {
            return Err(UpdateError::permanent(UpdateFailureCode::SupportMismatch));
        }
    }
    verify_supply_chain(app)?;
    run_checked(
        "/usr/sbin/spctl",
        &["--assess", "--type", "execute", path_string(app)?.as_str()],
        UpdateFailureCode::NotarizationMissing,
    )?;
    Ok(())
}

fn verify_bundle_identity_only(app: &Path) -> Result<(), UpdateError> {
    if !app.is_dir() || app.is_symlink() {
        return Err(UpdateError::permanent(UpdateFailureCode::BundleMismatch));
    }
    let plist = app.join("Contents/Info.plist");
    let identifier = command_text(
        "/usr/bin/plutil",
        &[
            "-extract",
            "CFBundleIdentifier",
            "raw",
            "-o",
            "-",
            path_string(&plist)?.as_str(),
        ],
        UpdateFailureCode::BundleMismatch,
    )?;
    if identifier.trim() != EXPECTED_BUNDLE_ID {
        return Err(UpdateError::permanent(UpdateFailureCode::BundleMismatch));
    }
    run_checked(
        "/usr/bin/codesign",
        &["--verify", "--deep", "--strict", path_string(app)?.as_str()],
        UpdateFailureCode::SignatureMismatch,
    )?;
    let signature = command_combined_text(
        "/usr/bin/codesign",
        &["--display", "--verbose=4", path_string(app)?.as_str()],
        UpdateFailureCode::SignatureMismatch,
    )?;
    if !signature
        .lines()
        .any(|line| line == format!("Identifier={EXPECTED_BUNDLE_ID}"))
        || !signature
            .lines()
            .any(|line| line == format!("TeamIdentifier={EXPECTED_TEAM_ID}"))
    {
        return Err(UpdateError::permanent(UpdateFailureCode::SignatureMismatch));
    }
    Ok(())
}

fn bundle_version(app: &Path) -> Result<String, UpdateError> {
    let value = command_text(
        "/usr/bin/plutil",
        &[
            "-extract",
            "CFBundleShortVersionString",
            "raw",
            "-o",
            "-",
            path_string(&app.join("Contents/Info.plist"))?.as_str(),
        ],
        UpdateFailureCode::BundleMismatch,
    )?;
    let value = value.trim();
    Version::parse(value).map_err(|_| UpdateError::permanent(UpdateFailureCode::BundleMismatch))?;
    Ok(value.to_string())
}

fn verify_supply_chain(app: &Path) -> Result<(), UpdateError> {
    let supply = app.join("Contents/Resources/SupplyChain");
    let candidate_pins: serde_json::Value = serde_json::from_slice(
        &std::fs::read(supply.join("pins.json"))
            .map_err(|_| UpdateError::permanent(UpdateFailureCode::SupplyChainMismatch))?,
    )
    .map_err(|_| UpdateError::permanent(UpdateFailureCode::SupplyChainMismatch))?;
    let pinned: serde_json::Value = serde_json::from_str(PINNED_SUPPLY_CHAIN)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::SupplyChainMismatch))?;
    if candidate_pins != pinned {
        return Err(UpdateError::permanent(
            UpdateFailureCode::SupplyChainMismatch,
        ));
    }
    let checksums = std::fs::read_to_string(supply.join("SHA256SUMS"))
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::SupplyChainMismatch))?;
    let allowed = [
        "Wrenflow.cdx.json",
        "RustThirdPartyLicenses.txt",
        "pins.json",
        "exceptions.json",
        "provenance.json",
    ];
    let mut seen = BTreeSet::new();
    for line in checksums.lines() {
        let Some((digest, name)) = line.split_once("  ") else {
            return Err(UpdateError::permanent(
                UpdateFailureCode::SupplyChainMismatch,
            ));
        };
        if !allowed.contains(&name)
            || digest.len() != 64
            || !digest.bytes().all(is_lower_hex)
            || !seen.insert(name)
        {
            return Err(UpdateError::permanent(
                UpdateFailureCode::SupplyChainMismatch,
            ));
        }
        if sha256_file(&supply.join(name))? != digest {
            return Err(UpdateError::permanent(
                UpdateFailureCode::SupplyChainMismatch,
            ));
        }
    }
    if seen.len() != allowed.len() {
        return Err(UpdateError::permanent(
            UpdateFailureCode::SupplyChainMismatch,
        ));
    }
    Ok(())
}

fn installed_app_location() -> Result<(InstallRoot, PathBuf, PathBuf), UpdateError> {
    let executable = std::env::current_exe()
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::UnsupportedInstallation))?;
    let app = executable
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .filter(|path| path.file_name().and_then(|name| name.to_str()) == Some("Wrenflow.app"))
        .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::UnsupportedInstallation))?;
    let system = PathBuf::from("/Applications/Wrenflow.app");
    if app == system {
        return Ok((
            InstallRoot::SystemApplications,
            PathBuf::from("/Applications"),
            system,
        ));
    }
    let user_directory = dirs::home_dir()
        .map(|home| home.join("Applications"))
        .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::UnsupportedInstallation))?;
    let user_app = user_directory.join("Wrenflow.app");
    if app == user_app {
        return Ok((InstallRoot::UserApplications, user_directory, user_app));
    }
    Err(UpdateError::permanent(
        UpdateFailureCode::UnsupportedInstallation,
    ))
}

fn install_directory(root: InstallRoot) -> Result<PathBuf, UpdateError> {
    match root {
        InstallRoot::SystemApplications => Ok(PathBuf::from("/Applications")),
        InstallRoot::UserApplications => dirs::home_dir()
            .map(|home| home.join("Applications"))
            .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::UnsupportedInstallation)),
    }
}

fn staging_bundle_name(token: &str) -> String {
    format!(".Wrenflow-update-{token}.app")
}

fn wait_for_process_exit(pid: u32) -> Result<(), UpdateError> {
    for _ in 0..300 {
        let running = Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .output()
            .is_ok_and(|output| output.status.success());
        if !running {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    Err(UpdateError::retryable(UpdateFailureCode::AtomicSwapFailed))
}

#[cfg(target_os = "macos")]
fn atomic_swap(left: &Path, right: &Path) -> Result<(), UpdateError> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt as _;

    const AT_FDCWD: i32 = -2;
    const RENAME_SWAP: u32 = 0x0000_0002;
    unsafe extern "C" {
        fn renameatx_np(
            from_fd: i32,
            from: *const std::ffi::c_char,
            to_fd: i32,
            to: *const std::ffi::c_char,
            flags: u32,
        ) -> i32;
    }
    let left = CString::new(left.as_os_str().as_bytes())
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::AtomicSwapFailed))?;
    let right = CString::new(right.as_os_str().as_bytes())
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::AtomicSwapFailed))?;
    let result = unsafe {
        renameatx_np(
            AT_FDCWD,
            left.as_ptr(),
            AT_FDCWD,
            right.as_ptr(),
            RENAME_SWAP,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(UpdateError::retryable(UpdateFailureCode::AtomicSwapFailed))
    }
}

fn classify_transaction(
    transaction: &UpdateTransaction,
    installed_version: Option<&str>,
    staged_version: Option<&str>,
) -> TransactionRecoveryAction {
    match (transaction.phase, installed_version, staged_version) {
        (TransactionPhase::Staging, Some(installed), _)
            if installed == transaction.from_version =>
        {
            TransactionRecoveryAction::RemoveInterruptedStaging
        }
        (TransactionPhase::Prepared, Some(installed), Some(staged))
            if installed == transaction.from_version && staged == transaction.version =>
        {
            TransactionRecoveryAction::RemovePreparedCandidate
        }
        (_, Some(installed), Some(staged))
            if installed == transaction.version && staged != transaction.version =>
        {
            TransactionRecoveryAction::FinalizeInstalledCandidate
        }
        _ => TransactionRecoveryAction::RecoveryRequired,
    }
}

fn remove_downloaded_dmg(version: &str) {
    if let Ok(version) = safe_version_filename(version) {
        let _ = std::fs::remove_file(
            current_data_paths()
                .updates
                .join(format!("Wrenflow-{version}.dmg")),
        );
    }
}

/// Keep updater storage bounded without accepting arbitrary deletion targets.
/// Only canonical, regular `Wrenflow-<semver>.dmg` files in the private update
/// directory are eligible. Unknown files and symlinks fail closed and remain.
fn purge_downloaded_dmgs(updates: &Path, keep_version: Option<&str>) -> Result<(), UpdateError> {
    let keep_version = keep_version.map(safe_version_filename).transpose()?;
    let entries = match std::fs::read_dir(updates) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(UpdateError::retryable(UpdateFailureCode::StagingFailed)),
    };
    let mut retained = 0_usize;
    for entry in entries {
        let entry = entry.map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        let file_type = entry
            .file_type()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        if !file_type.is_file() || file_type.is_symlink() {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(ToString::to_string) else {
            continue;
        };
        let Some(version) = name
            .strip_prefix("Wrenflow-")
            .and_then(|value| value.strip_suffix(".dmg"))
        else {
            continue;
        };
        let Ok(canonical) = safe_version_filename(version) else {
            continue;
        };
        if name != format!("Wrenflow-{canonical}.dmg") {
            continue;
        }
        if keep_version.as_deref() == Some(canonical.as_str()) && retained < MAX_RETAINED_DMGS {
            retained += 1;
            continue;
        }
        std::fs::remove_file(entry.path())
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn remove_interrupted_staging_bundle(path: &Path) -> Result<(), UpdateError> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(UpdateError::retryable(UpdateFailureCode::StagingFailed)),
    };
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(UpdateError::permanent(UpdateFailureCode::RecoveryRequired));
    }
    std::fs::remove_dir_all(path)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    if let Some(parent) = path.parent() {
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    }
    Ok(())
}

fn transaction_path() -> PathBuf {
    current_data_paths().updates.join(TRANSACTION_FILE)
}

fn write_transaction(transaction: &UpdateTransaction) -> Result<(), UpdateError> {
    let path = transaction_path();
    let parent = path
        .parent()
        .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::StagingFailed))?;
    std::fs::create_dir_all(parent)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    set_private_directory(parent)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    let bytes = serde_json::to_vec(transaction)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::StagingFailed))?;
    let temporary = path.with_extension("json.partial");
    let result = (|| {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temporary)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        set_private_file(&file)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        file.write_all(&bytes)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        file.sync_all()
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        drop(file);
        std::fs::rename(&temporary, &path)
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temporary);
    }
    result
}

fn read_transaction() -> Result<UpdateTransaction, UpdateError> {
    let bytes = std::fs::read(transaction_path())
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::RecoveryRequired))?;
    if bytes.len() > 8 * 1024 {
        return Err(UpdateError::permanent(UpdateFailureCode::RecoveryRequired));
    }
    let transaction: UpdateTransaction = serde_json::from_slice(&bytes)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::RecoveryRequired))?;
    if transaction.schema_version != TRANSACTION_SCHEMA_VERSION
        || transaction.token.len() > 96
        || !transaction
            .token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        || Version::parse(&transaction.version).is_err()
        || Version::parse(&transaction.from_version).is_err()
        || transaction.sha256.len() != 64
        || !transaction.sha256.bytes().all(is_lower_hex)
    {
        return Err(UpdateError::permanent(UpdateFailureCode::RecoveryRequired));
    }
    Ok(transaction)
}

fn remove_transaction() -> Result<(), UpdateError> {
    let path = transaction_path();
    std::fs::remove_file(&path)
        .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    if let Some(parent) = path.parent() {
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| UpdateError::retryable(UpdateFailureCode::StagingFailed))?;
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String, UpdateError> {
    let mut file = File::open(path)
        .map_err(|_| UpdateError::permanent(UpdateFailureCode::ChecksumMismatch))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| UpdateError::permanent(UpdateFailureCode::ChecksumMismatch))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn path_string(path: &Path) -> Result<String, UpdateError> {
    path.to_str()
        .map(ToString::to_string)
        .ok_or_else(|| UpdateError::permanent(UpdateFailureCode::UnsupportedInstallation))
}

fn run_checked(
    program: &str,
    arguments: &[&str],
    code: UpdateFailureCode,
) -> Result<(), UpdateError> {
    let output = Command::new(program)
        .args(arguments)
        .output()
        .map_err(|_| UpdateError::permanent(code))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(UpdateError::permanent(code))
    }
}

fn command_text(
    program: &str,
    arguments: &[&str],
    code: UpdateFailureCode,
) -> Result<String, UpdateError> {
    let output = Command::new(program)
        .args(arguments)
        .output()
        .map_err(|_| UpdateError::permanent(code))?;
    if !output.status.success() {
        return Err(UpdateError::permanent(code));
    }
    String::from_utf8(output.stdout).map_err(|_| UpdateError::permanent(code))
}

fn command_combined_text(
    program: &str,
    arguments: &[&str],
    code: UpdateFailureCode,
) -> Result<String, UpdateError> {
    let Output {
        status,
        stdout,
        stderr,
    } = Command::new(program)
        .args(arguments)
        .output()
        .map_err(|_| UpdateError::permanent(code))?;
    if !status.success() {
        return Err(UpdateError::permanent(code));
    }
    let mut bytes = stdout;
    bytes.extend_from_slice(&stderr);
    String::from_utf8(bytes).map_err(|_| UpdateError::permanent(code))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn endurance_fixture() -> tempfile::TempDir {
        if let Some(root) = std::env::var_os("WRENFLOW_ENDURANCE_DISPOSABLE_ROOT") {
            let root = std::path::PathBuf::from(root);
            assert!(root.is_absolute() && root.is_dir() && !root.is_symlink());
            tempfile::Builder::new()
                .prefix("update-")
                .tempdir_in(root)
                .unwrap()
        } else {
            tempfile::Builder::new()
                .prefix("wrenflow-gpui-v1-update-")
                .tempdir()
                .unwrap()
        }
    }

    fn release(version: &str, prerelease: bool, digest: &str, host: &str) -> serde_json::Value {
        serde_json::json!({
            "id": version.bytes().map(u64::from).sum::<u64>(),
            "tag_name": format!("v{version}"),
            "draft": false,
            "prerelease": prerelease,
            "published_at": "2026-08-09T12:00:00Z",
            "html_url": "https://github.com/IlyaGulya/wrenflow/releases",
            "assets": [{
                "id": 42,
                "name": "Wrenflow.dmg",
                "content_type": "application/x-apple-diskimage",
                "size": 4,
                "digest": format!("sha256:{digest}"),
                "browser_download_url": format!(
                    "https://{host}/IlyaGulya/wrenflow/releases/download/v{version}/Wrenflow.dmg"
                ),
                "download_count": 0
            }]
        })
    }

    fn payload(releases: Vec<serde_json::Value>) -> Vec<u8> {
        serde_json::to_vec(&releases).unwrap()
    }

    fn test_candidate(bytes: &[u8]) -> UpdateCandidate {
        let digest = format!("{:x}", Sha256::digest(bytes));
        UpdateCandidate {
            version: "0.4.0".to_string(),
            channel: UpdateChannel::Stable,
            published_at_iso: None,
            size_bytes: bytes.len() as u64,
            release_id: 1,
            asset_id: 2,
            sha256: digest,
            download_url: Url::parse(
                "https://github.com/IlyaGulya/wrenflow/releases/download/v0.4.0/Wrenflow.dmg",
            )
            .unwrap(),
        }
    }

    #[test]
    fn stable_and_beta_channels_are_strictly_isolated() {
        let digest = "a".repeat(64);
        let feed = payload(vec![
            release("0.5.0-beta.2", true, &digest, "github.com"),
            release("0.4.0", false, &digest, "github.com"),
        ]);
        let stable = select_release(&feed, "0.3.0", UpdateChannel::Stable).unwrap();
        let UpdateCheckOutcome::Available(stable) = stable else {
            panic!("stable update expected");
        };
        assert_eq!(stable.version, "0.4.0");
        assert_eq!(stable.channel, UpdateChannel::Stable);

        let beta = select_release(&feed, "0.3.0", UpdateChannel::Beta).unwrap();
        let UpdateCheckOutcome::Available(beta) = beta else {
            panic!("beta update expected");
        };
        assert_eq!(beta.version, "0.5.0-beta.2");
        assert_eq!(beta.channel, UpdateChannel::Beta);
    }

    #[test]
    fn current_newer_and_pre_gpui_versions_fail_closed() {
        let digest = "b".repeat(64);
        let current = payload(vec![release("0.3.0", false, &digest, "github.com")]);
        assert_eq!(
            select_release(&current, "0.3.0", UpdateChannel::Stable).unwrap(),
            UpdateCheckOutcome::UpToDate
        );
        let older = payload(vec![release("0.2.9", false, &digest, "github.com")]);
        assert_eq!(
            select_release(&older, "0.3.0", UpdateChannel::Stable).unwrap(),
            UpdateCheckOutcome::UpToDate
        );
        assert_eq!(
            select_release(&current, "0.2.9", UpdateChannel::Stable)
                .unwrap_err()
                .code,
            UpdateFailureCode::UnsupportedReleaseLine
        );
    }

    #[test]
    fn duplicate_malformed_and_unexpected_host_metadata_are_rejected() {
        let digest = "c".repeat(64);
        let duplicate = payload(vec![
            release("0.4.0", false, &digest, "github.com"),
            release("0.4.0", false, &digest, "github.com"),
        ]);
        assert_eq!(
            select_release(&duplicate, "0.3.0", UpdateChannel::Stable)
                .unwrap_err()
                .code,
            UpdateFailureCode::DuplicateRelease
        );
        let bad_digest = payload(vec![release("0.4.0", false, "not-a-digest", "github.com")]);
        assert_eq!(
            select_release(&bad_digest, "0.3.0", UpdateChannel::Stable)
                .unwrap_err()
                .code,
            UpdateFailureCode::InvalidArtifactMetadata
        );
        let hostile = payload(vec![release("0.4.0", false, &digest, "evil.example")]);
        assert_eq!(
            select_release(&hostile, "0.3.0", UpdateChannel::Stable)
                .unwrap_err()
                .code,
            UpdateFailureCode::UnexpectedHost
        );
    }

    #[test]
    fn offline_and_rate_limit_failures_are_actionable_and_bounded() {
        let offline = offline_error();
        assert_eq!(offline.code, UpdateFailureCode::Offline);
        assert!(offline.retryable);
        let mut headers = header::HeaderMap::new();
        headers.insert(
            header::RETRY_AFTER,
            header::HeaderValue::from_static("99999"),
        );
        let limited = http_status_error(StatusCode::TOO_MANY_REQUESTS, &headers);
        assert_eq!(limited.code, UpdateFailureCode::RateLimited);
        assert_eq!(limited.retry_after_seconds, Some(3_600));
    }

    #[test]
    fn partial_download_is_removed_and_never_published() {
        let fixture = tempfile::tempdir().unwrap();
        let candidate = test_candidate(b"test");
        let destination = fixture.path().join("Wrenflow-0.4.0.dmg");
        {
            let mut writer = DownloadWriter::new(&destination, &candidate).unwrap();
            writer.write_chunk(b"te").unwrap();
        }
        assert!(!destination.exists());
        assert!(!destination.with_extension("dmg.partial").exists());
    }

    #[test]
    fn checksum_mismatch_is_rejected_before_atomic_publish() {
        let fixture = tempfile::tempdir().unwrap();
        let mut candidate = test_candidate(b"test");
        candidate.sha256 = "d".repeat(64);
        let destination = fixture.path().join("Wrenflow-0.4.0.dmg");
        let mut writer = DownloadWriter::new(&destination, &candidate).unwrap();
        writer.write_chunk(b"test").unwrap();
        assert_eq!(
            writer.finish().unwrap_err().code,
            UpdateFailureCode::ChecksumMismatch
        );
        assert!(!destination.exists());
        assert!(!destination.with_extension("dmg.partial").exists());
    }

    #[test]
    fn verified_download_is_synced_and_atomically_published_private() {
        let fixture = tempfile::tempdir().unwrap();
        let candidate = test_candidate(b"test");
        let destination = fixture.path().join("Wrenflow-0.4.0.dmg");
        let mut writer = DownloadWriter::new(&destination, &candidate).unwrap();
        writer.write_chunk(b"te").unwrap();
        writer.write_chunk(b"st").unwrap();
        writer.finish().unwrap();
        assert_eq!(std::fs::read(&destination).unwrap(), b"test");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                destination.metadata().unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    fn transaction(phase: TransactionPhase) -> UpdateTransaction {
        UpdateTransaction {
            schema_version: TRANSACTION_SCHEMA_VERSION,
            token: "1-2-aaaaaaaaaaaa".to_string(),
            from_version: "0.3.0".to_string(),
            version: "0.4.0".to_string(),
            sha256: "a".repeat(64),
            install_root: InstallRoot::SystemApplications,
            phase,
        }
    }

    #[test]
    fn interruption_recovery_never_guesses_or_downgrades() {
        assert_eq!(
            classify_transaction(&transaction(TransactionPhase::Staging), Some("0.3.0"), None),
            TransactionRecoveryAction::RemoveInterruptedStaging
        );
        assert_eq!(
            classify_transaction(
                &transaction(TransactionPhase::Staging),
                Some("0.3.0"),
                Some("not-a-valid-bundle")
            ),
            TransactionRecoveryAction::RemoveInterruptedStaging
        );
        assert_eq!(
            classify_transaction(
                &transaction(TransactionPhase::Prepared),
                Some("0.3.0"),
                Some("0.4.0")
            ),
            TransactionRecoveryAction::RemovePreparedCandidate
        );
        assert_eq!(
            classify_transaction(
                &transaction(TransactionPhase::Prepared),
                Some("0.4.0"),
                Some("0.3.0")
            ),
            TransactionRecoveryAction::FinalizeInstalledCandidate
        );
        assert_eq!(
            classify_transaction(
                &transaction(TransactionPhase::Swapped),
                Some("0.4.0"),
                Some("0.3.0")
            ),
            TransactionRecoveryAction::FinalizeInstalledCandidate
        );
        assert_eq!(
            classify_transaction(
                &transaction(TransactionPhase::Swapped),
                Some("0.9.0"),
                Some("0.1.0")
            ),
            TransactionRecoveryAction::RecoveryRequired
        );
    }

    #[test]
    fn twenty_channel_download_and_transaction_fault_cycles_fail_closed() {
        const CYCLES: usize = 20;

        let digest = "e".repeat(64);
        let feed = payload(vec![
            release("0.5.0-beta.2", true, &digest, "github.com"),
            release("0.4.0", false, &digest, "github.com"),
        ]);
        let fixture = endurance_fixture();

        for cycle in 0..CYCLES {
            let UpdateCheckOutcome::Available(stable) =
                select_release(&feed, "0.3.0", UpdateChannel::Stable).unwrap()
            else {
                panic!("stable update expected on cycle {cycle}");
            };
            assert_eq!(stable.version, "0.4.0");
            assert_eq!(stable.channel, UpdateChannel::Stable);

            let UpdateCheckOutcome::Available(beta) =
                select_release(&feed, "0.3.0", UpdateChannel::Beta).unwrap()
            else {
                panic!("beta update expected on cycle {cycle}");
            };
            assert_eq!(beta.version, "0.5.0-beta.2");
            assert_eq!(beta.channel, UpdateChannel::Beta);

            let candidate = test_candidate(b"test");
            let destination = fixture.path().join(format!("Wrenflow-{cycle}.dmg"));
            {
                let mut writer = DownloadWriter::new(&destination, &candidate).unwrap();
                writer.write_chunk(b"te").unwrap();
            }
            assert!(!destination.exists());
            assert!(!destination.with_extension("dmg.partial").exists());

            assert_eq!(
                classify_transaction(&transaction(TransactionPhase::Staging), Some("0.3.0"), None),
                TransactionRecoveryAction::RemoveInterruptedStaging
            );
            assert_eq!(
                classify_transaction(
                    &transaction(TransactionPhase::Prepared),
                    Some("0.3.0"),
                    Some("0.4.0")
                ),
                TransactionRecoveryAction::RemovePreparedCandidate
            );
            assert_eq!(
                classify_transaction(
                    &transaction(TransactionPhase::Swapped),
                    Some("0.4.0"),
                    Some("0.3.0")
                ),
                TransactionRecoveryAction::FinalizeInstalledCandidate
            );
            assert_eq!(
                classify_transaction(
                    &transaction(TransactionPhase::Swapped),
                    Some("0.3.0"),
                    Some("0.4.0")
                ),
                TransactionRecoveryAction::RecoveryRequired
            );
        }
    }

    #[test]
    fn downloaded_dmg_retention_is_bounded_and_strictly_scoped() {
        let fixture = tempfile::tempdir().unwrap();
        let old = fixture.path().join("Wrenflow-0.3.0.dmg");
        let keep = fixture.path().join("Wrenflow-0.4.0.dmg");
        let malformed = fixture.path().join("Wrenflow-latest.dmg");
        let unrelated = fixture.path().join("customer-recording.dmg");
        std::fs::write(&old, b"old").unwrap();
        std::fs::write(&keep, b"keep").unwrap();
        std::fs::write(&malformed, b"unknown").unwrap();
        std::fs::write(&unrelated, b"unrelated").unwrap();

        purge_downloaded_dmgs(fixture.path(), Some("0.4.0")).unwrap();

        assert!(!old.exists());
        assert_eq!(std::fs::read(keep).unwrap(), b"keep");
        assert_eq!(std::fs::read(malformed).unwrap(), b"unknown");
        assert_eq!(std::fs::read(unrelated).unwrap(), b"unrelated");
    }

    #[cfg(unix)]
    #[test]
    fn downloaded_dmg_retention_never_follows_symlinks() {
        use std::os::unix::fs::symlink;

        let fixture = tempfile::tempdir().unwrap();
        let outside = fixture.path().join("outside");
        let link = fixture.path().join("Wrenflow-0.3.0.dmg");
        std::fs::write(&outside, b"preserved").unwrap();
        symlink(&outside, &link).unwrap();

        purge_downloaded_dmgs(fixture.path(), None).unwrap();

        assert!(link.is_symlink());
        assert_eq!(std::fs::read(outside).unwrap(), b"preserved");
    }

    #[test]
    fn helper_boundary_rejects_extra_arguments_and_path_injection() {
        let result = run_update_helper_from_args([
            "wrenflow",
            "--wrenflow-update-helper",
            "42",
            "1-2-aaaaaaaaaaaa",
            "/Applications/Evil.app",
        ])
        .unwrap()
        .unwrap_err();
        assert_eq!(result.code, UpdateFailureCode::InvalidArtifactMetadata);
    }

    #[test]
    fn supply_chain_pin_mismatch_is_rejected() {
        let fixture = tempfile::tempdir().unwrap();
        let supply = fixture
            .path()
            .join("Wrenflow.app/Contents/Resources/SupplyChain");
        std::fs::create_dir_all(&supply).unwrap();
        let files = [
            ("Wrenflow.cdx.json", b"sbom".as_slice()),
            ("RustThirdPartyLicenses.txt", b"licenses".as_slice()),
            ("pins.json", PINNED_SUPPLY_CHAIN.as_bytes()),
            ("exceptions.json", b"exceptions".as_slice()),
            ("provenance.json", b"provenance".as_slice()),
        ];
        let mut sums = String::new();
        for (name, contents) in files {
            std::fs::write(supply.join(name), contents).unwrap();
            sums.push_str(&format!("{:x}  {name}\n", Sha256::digest(contents)));
        }
        std::fs::write(supply.join("SHA256SUMS"), sums).unwrap();
        assert!(verify_supply_chain(&fixture.path().join("Wrenflow.app")).is_ok());
        std::fs::write(supply.join("pins.json"), b"{}").unwrap();
        assert_eq!(
            verify_supply_chain(&fixture.path().join("Wrenflow.app"))
                .unwrap_err()
                .code,
            UpdateFailureCode::SupplyChainMismatch
        );
    }

    #[test]
    fn injected_verifier_failure_maps_to_closed_code() {
        let error =
            run_checked("/usr/bin/false", &[], UpdateFailureCode::SignatureMismatch).unwrap_err();
        assert_eq!(error.code, UpdateFailureCode::SignatureMismatch);
        assert!(!error.retryable);
    }
}

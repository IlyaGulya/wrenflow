//! Private, fail-closed data isolation for the signed owner-operated release smoke.
//!
//! This gate changes only the base directory used by the ordinary production
//! runtime. It provides no generated input, UI automation, TCC operation, or
//! diagnostic surface.

use std::ffi::{OsStr, OsString};
use std::fs::{self, OpenOptions};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

use crate::data_paths::CURRENT_DATA_NAMESPACE;

pub const OWNER_SMOKE_ARGUMENT: &str = "--owner-smoke";
pub const OWNER_SMOKE_CONTRACT_ENV: &str = "WRENFLOW_OWNER_SMOKE_CONTRACT";
pub const OWNER_SMOKE_ROOT_ENV: &str = "WRENFLOW_OWNER_SMOKE_DATA_ROOT";
pub const OWNER_SMOKE_SESSION_ENV: &str = "WRENFLOW_OWNER_SMOKE_SESSION";
pub const OWNER_SMOKE_LAUNCH_ENV: &str = "WRENFLOW_OWNER_SMOKE_LAUNCH";
pub const OWNER_SMOKE_CONTRACT: &str = "wrenflow-owner-smoke-v1";
const MARKER_NAME: &str = ".wrenflow-owner-smoke-v1.json";
const READY_NAME: &str = ".wrenflow-owner-smoke-ready-v1.json";
static OWNER_SMOKE_CONTEXT: OnceLock<OwnerSmokeContext> = OnceLock::new();

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerSmokeGateError {
    GateMismatch,
    UnsafeRoot,
    RootInUse,
    RootOverrideUnavailable,
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct OwnerSmokeMarker {
    contract: String,
    session_id: String,
}

#[derive(Clone, Debug)]
struct OwnerSmokeContext {
    root: PathBuf,
    session_id: String,
    launch_id: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct OwnerSmokeReady {
    contract: String,
    session_id: String,
    launch_id: String,
    pid: u32,
    state: String,
}

#[derive(Clone, Debug, Default)]
struct ProcessInputs {
    contract: Option<OsString>,
    data_root: Option<OsString>,
    session: Option<OsString>,
    launch: Option<OsString>,
    unknown_owner_env: bool,
    incompatible_performance_env: bool,
}

impl ProcessInputs {
    fn production() -> Self {
        let mut result = Self {
            contract: std::env::var_os(OWNER_SMOKE_CONTRACT_ENV),
            data_root: std::env::var_os(OWNER_SMOKE_ROOT_ENV),
            session: std::env::var_os(OWNER_SMOKE_SESSION_ENV),
            launch: std::env::var_os(OWNER_SMOKE_LAUNCH_ENV),
            ..Self::default()
        };
        for (key, _) in std::env::vars_os() {
            if key.to_str().is_some_and(|key| {
                key.starts_with("WRENFLOW_OWNER_SMOKE_")
                    && !matches!(
                        key,
                        OWNER_SMOKE_CONTRACT_ENV
                            | OWNER_SMOKE_ROOT_ENV
                            | OWNER_SMOKE_SESSION_ENV
                            | OWNER_SMOKE_LAUNCH_ENV
                    )
            }) {
                result.unknown_owner_env = true;
            }
            if key
                .to_str()
                .is_some_and(|key| key.starts_with("WRENFLOW_PERFORMANCE_"))
            {
                result.incompatible_performance_env = true;
            }
        }
        result
    }

    fn any_present(&self) -> bool {
        self.contract.is_some()
            || self.data_root.is_some()
            || self.session.is_some()
            || self.launch.is_some()
            || self.unknown_owner_env
    }
}

/// Install the disposable base before any production path can be resolved.
pub fn prepare_owner_smoke(arguments: &[String]) -> Result<(), OwnerSmokeGateError> {
    let inputs = ProcessInputs::production();
    if !has_surface(arguments, &inputs) {
        return Ok(());
    }
    let (root, session, launch) = validate_gate(arguments, &inputs)?;
    prepare_root(&root, &session)?;
    crate::data_paths::install_current_data_base_override(root.clone())
        .map_err(|()| OwnerSmokeGateError::RootOverrideUnavailable)?;
    OWNER_SMOKE_CONTEXT
        .set(OwnerSmokeContext {
            root,
            session_id: session,
            launch_id: launch,
        })
        .map_err(|_| OwnerSmokeGateError::RootOverrideUnavailable)
}

/// Publish a root-local current-PID proof only after terminal window policy.
pub fn mark_owner_smoke_ready() -> Result<(), OwnerSmokeGateError> {
    let Some(context) = OWNER_SMOKE_CONTEXT.get() else {
        return Ok(());
    };
    write_atomic_private(
        &context.root,
        READY_NAME,
        &OwnerSmokeReady {
            contract: OWNER_SMOKE_CONTRACT.to_owned(),
            session_id: context.session_id.clone(),
            launch_id: context.launch_id.clone(),
            pid: std::process::id(),
            state: "terminal_window_policy_ready".to_owned(),
        },
        true,
    )
}

fn has_surface(arguments: &[String], inputs: &ProcessInputs) -> bool {
    arguments
        .iter()
        .any(|argument| argument.starts_with("--owner-smoke"))
        || inputs.any_present()
}

fn validate_gate(
    arguments: &[String],
    inputs: &ProcessInputs,
) -> Result<(PathBuf, String, String), OwnerSmokeGateError> {
    if arguments.len() != 2
        || arguments.get(1).map(String::as_str) != Some(OWNER_SMOKE_ARGUMENT)
        || inputs.contract.as_deref() != Some(OsStr::new(OWNER_SMOKE_CONTRACT))
        || inputs.unknown_owner_env
        || inputs.incompatible_performance_env
    {
        return Err(OwnerSmokeGateError::GateMismatch);
    }
    let root = inputs
        .data_root
        .as_ref()
        .and_then(|value| value.to_str())
        .map(PathBuf::from)
        .ok_or(OwnerSmokeGateError::GateMismatch)?;
    let session = inputs
        .session
        .as_ref()
        .and_then(|value| value.to_str())
        .filter(|value| is_session_id(value))
        .map(str::to_owned)
        .ok_or(OwnerSmokeGateError::GateMismatch)?;
    let launch = inputs
        .launch
        .as_ref()
        .and_then(|value| value.to_str())
        .filter(|value| is_session_id(value))
        .map(str::to_owned)
        .ok_or(OwnerSmokeGateError::GateMismatch)?;
    Ok((root, session, launch))
}

fn is_session_id(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn prepare_root(root: &Path, session: &str) -> Result<(), OwnerSmokeGateError> {
    validate_root_identity(root)?;
    let mut names = fs::read_dir(root)
        .map_err(|_| OwnerSmokeGateError::UnsafeRoot)?
        .map(|entry| {
            entry
                .map(|entry| entry.file_name())
                .map_err(|_| OwnerSmokeGateError::UnsafeRoot)
        })
        .collect::<Result<Vec<_>, _>>()?;
    names.sort();
    if names.is_empty() {
        return create_marker(root, session);
    }

    let marker_name = OsString::from(MARKER_NAME);
    let namespace_name = OsString::from(CURRENT_DATA_NAMESPACE.split('/').next().unwrap_or(""));
    let ready_name = OsString::from(READY_NAME);
    if !names.contains(&marker_name)
        || names
            .iter()
            .any(|name| name != &marker_name && name != &namespace_name && name != &ready_name)
    {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    validate_marker(root, session)?;
    if root.join(READY_NAME).exists() {
        validate_ready(root, session)?;
    }
    if root
        .join(CURRENT_DATA_NAMESPACE.split('/').next().unwrap_or(""))
        .exists()
    {
        validate_namespace(root)?;
    }
    Ok(())
}

fn validate_root_identity(root: &Path) -> Result<(), OwnerSmokeGateError> {
    if !root.is_absolute()
        || root
            .components()
            .any(|component| !matches!(component, Component::RootDir | Component::Normal(_)))
    {
        return Err(OwnerSmokeGateError::UnsafeRoot);
    }
    let metadata = fs::symlink_metadata(root).map_err(|_| OwnerSmokeGateError::UnsafeRoot)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(OwnerSmokeGateError::UnsafeRoot);
    }
    if fs::canonicalize(root).map_err(|_| OwnerSmokeGateError::UnsafeRoot)? != root {
        return Err(OwnerSmokeGateError::UnsafeRoot);
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & 0o777 != 0o700 || metadata.uid() != expected_owner_uid()? {
        return Err(OwnerSmokeGateError::UnsafeRoot);
    }
    Ok(())
}

#[cfg(unix)]
fn expected_owner_uid() -> Result<u32, OwnerSmokeGateError> {
    let executable = std::env::current_exe().map_err(|_| OwnerSmokeGateError::UnsafeRoot)?;
    fs::symlink_metadata(executable)
        .map(|metadata| metadata.uid())
        .map_err(|_| OwnerSmokeGateError::UnsafeRoot)
}

fn create_marker(root: &Path, session: &str) -> Result<(), OwnerSmokeGateError> {
    let marker = OwnerSmokeMarker {
        contract: OWNER_SMOKE_CONTRACT.to_owned(),
        session_id: session.to_owned(),
    };
    write_atomic_private(root, MARKER_NAME, &marker, false)
}

fn write_atomic_private<T: Serialize>(
    root: &Path,
    name: &str,
    value: &T,
    replace: bool,
) -> Result<(), OwnerSmokeGateError> {
    let path = root.join(name);
    let temporary = root.join(format!(".{name}.tmp-{}", std::process::id()));
    let content = serde_json::to_vec(value).map_err(|_| OwnerSmokeGateError::UnsafeRoot)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(&temporary)
        .map_err(|_| OwnerSmokeGateError::RootInUse)?;
    #[cfg(unix)]
    {
        if file
            .set_permissions(fs::Permissions::from_mode(0o600))
            .is_err()
        {
            drop(file);
            let _ = fs::remove_file(&temporary);
            return Err(OwnerSmokeGateError::UnsafeRoot);
        }
        let metadata = match file.metadata() {
            Ok(metadata) => metadata,
            Err(_) => {
                drop(file);
                let _ = fs::remove_file(&temporary);
                return Err(OwnerSmokeGateError::UnsafeRoot);
            }
        };
        if metadata.permissions().mode() & 0o777 != 0o600 || metadata.uid() != expected_owner_uid()?
        {
            drop(file);
            let _ = fs::remove_file(&temporary);
            return Err(OwnerSmokeGateError::UnsafeRoot);
        }
    }
    let prepared = file
        .write_all(&content)
        .and_then(|()| file.write_all(b"\n"))
        .and_then(|()| file.sync_all());
    drop(file);
    if prepared.is_err() {
        let _ = fs::remove_file(&temporary);
        return Err(OwnerSmokeGateError::UnsafeRoot);
    }
    if replace {
        if fs::rename(&temporary, &path).is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(OwnerSmokeGateError::UnsafeRoot);
        }
    } else {
        if fs::hard_link(&temporary, &path).is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(OwnerSmokeGateError::RootInUse);
        }
        if fs::remove_file(&temporary).is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(OwnerSmokeGateError::UnsafeRoot);
        }
    }
    let published = fs::symlink_metadata(&path).map_err(|_| OwnerSmokeGateError::UnsafeRoot)?;
    if published.file_type().is_symlink() || !published.is_file() {
        return Err(OwnerSmokeGateError::UnsafeRoot);
    }
    #[cfg(unix)]
    if published.permissions().mode() & 0o777 != 0o600 || published.uid() != expected_owner_uid()? {
        return Err(OwnerSmokeGateError::UnsafeRoot);
    }
    OpenOptions::new()
        .read(true)
        .open(root)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| OwnerSmokeGateError::UnsafeRoot)
}

fn validate_ready(root: &Path, session: &str) -> Result<(), OwnerSmokeGateError> {
    let path = root.join(READY_NAME);
    let metadata = fs::symlink_metadata(&path).map_err(|_| OwnerSmokeGateError::RootInUse)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & 0o777 != 0o600 || metadata.uid() != expected_owner_uid()? {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    let ready: OwnerSmokeReady =
        serde_json::from_slice(&fs::read(path).map_err(|_| OwnerSmokeGateError::RootInUse)?)
            .map_err(|_| OwnerSmokeGateError::RootInUse)?;
    if ready.contract != OWNER_SMOKE_CONTRACT
        || ready.session_id != session
        || !is_session_id(&ready.launch_id)
        || ready.pid == 0
        || ready.state != "terminal_window_policy_ready"
    {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    Ok(())
}

fn validate_marker(root: &Path, session: &str) -> Result<(), OwnerSmokeGateError> {
    let path = root.join(MARKER_NAME);
    let metadata = fs::symlink_metadata(&path).map_err(|_| OwnerSmokeGateError::RootInUse)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    #[cfg(unix)]
    if metadata.permissions().mode() & 0o777 != 0o600 || metadata.uid() != expected_owner_uid()? {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    let marker: OwnerSmokeMarker =
        serde_json::from_slice(&fs::read(path).map_err(|_| OwnerSmokeGateError::RootInUse)?)
            .map_err(|_| OwnerSmokeGateError::RootInUse)?;
    if marker
        != (OwnerSmokeMarker {
            contract: OWNER_SMOKE_CONTRACT.to_owned(),
            session_id: session.to_owned(),
        })
    {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    Ok(())
}

fn validate_namespace(root: &Path) -> Result<(), OwnerSmokeGateError> {
    let mut current = root.to_path_buf();
    for component in CURRENT_DATA_NAMESPACE.split('/') {
        current = current.join(component);
        let metadata =
            fs::symlink_metadata(&current).map_err(|_| OwnerSmokeGateError::RootInUse)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(OwnerSmokeGateError::RootInUse);
        }
    }
    let parent = root.join(CURRENT_DATA_NAMESPACE.split('/').next().unwrap_or(""));
    if fs::read_dir(&parent)
        .map_err(|_| OwnerSmokeGateError::RootInUse)?
        .count()
        != 1
    {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    #[cfg(unix)]
    let expected_uid = expected_owner_uid()?;
    #[cfg(not(unix))]
    let expected_uid = 0;
    validate_namespace_tree(&parent, expected_uid)
}

fn validate_namespace_tree(path: &Path, expected_uid: u32) -> Result<(), OwnerSmokeGateError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| OwnerSmokeGateError::RootInUse)?;
    if metadata.file_type().is_symlink() || (!metadata.is_dir() && !metadata.is_file()) {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    #[cfg(unix)]
    if metadata.uid() != expected_uid || metadata.permissions().mode() & 0o022 != 0 {
        return Err(OwnerSmokeGateError::RootInUse);
    }
    if metadata.is_dir() {
        for entry in fs::read_dir(path).map_err(|_| OwnerSmokeGateError::RootInUse)? {
            validate_namespace_tree(
                &entry.map_err(|_| OwnerSmokeGateError::RootInUse)?.path(),
                expected_uid,
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inputs(root: &Path, session: &str) -> ProcessInputs {
        ProcessInputs {
            contract: Some(OWNER_SMOKE_CONTRACT.into()),
            data_root: Some(root.as_os_str().to_owned()),
            session: Some(session.into()),
            launch: Some("11111111111111111111111111111111".into()),
            ..ProcessInputs::default()
        }
    }

    #[test]
    fn gate_requires_exact_argument_environment_and_excludes_performance() {
        let root = Path::new("/private/tmp/owner-smoke");
        let session = "0123456789abcdef0123456789abcdef";
        let exact = vec!["wrenflow".to_owned(), OWNER_SMOKE_ARGUMENT.to_owned()];
        assert_eq!(
            validate_gate(&exact, &inputs(root, session)),
            Ok((
                root.into(),
                session.into(),
                "11111111111111111111111111111111".into()
            ))
        );
        for arguments in [
            vec!["wrenflow".to_owned()],
            vec!["wrenflow".to_owned(), "--owner-smoke=1".to_owned()],
            vec![
                "wrenflow".to_owned(),
                OWNER_SMOKE_ARGUMENT.to_owned(),
                "extra".to_owned(),
            ],
        ] {
            assert_eq!(
                validate_gate(&arguments, &inputs(root, session)),
                Err(OwnerSmokeGateError::GateMismatch)
            );
        }
        let mut half = inputs(root, session);
        half.contract = None;
        assert_eq!(
            validate_gate(&exact, &half),
            Err(OwnerSmokeGateError::GateMismatch)
        );
        let mut wrong = inputs(root, session);
        wrong.session = Some("ABCDEF".into());
        assert_eq!(
            validate_gate(&exact, &wrong),
            Err(OwnerSmokeGateError::GateMismatch)
        );
        let mut unknown = inputs(root, session);
        unknown.unknown_owner_env = true;
        assert_eq!(
            validate_gate(&exact, &unknown),
            Err(OwnerSmokeGateError::GateMismatch)
        );
        let mut performance = inputs(root, session);
        performance.incompatible_performance_env = true;
        assert_eq!(
            validate_gate(&exact, &performance),
            Err(OwnerSmokeGateError::GateMismatch)
        );
        let mut missing_launch = inputs(root, session);
        missing_launch.launch = None;
        assert_eq!(
            validate_gate(&exact, &missing_launch),
            Err(OwnerSmokeGateError::GateMismatch)
        );
    }

    #[cfg(unix)]
    #[test]
    fn atomic_private_files_ignore_restrictive_process_umask() {
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root_path = fs::canonicalize(root.path()).unwrap();
        let session = "0123456789abcdef0123456789abcdef";
        assert_eq!(prepare_root(&root_path, session), Ok(()));
        write_atomic_private(
            &root_path,
            READY_NAME,
            &OwnerSmokeReady {
                contract: OWNER_SMOKE_CONTRACT.to_owned(),
                session_id: session.to_owned(),
                launch_id: "11111111111111111111111111111111".to_owned(),
                pid: 42,
                state: "terminal_window_policy_ready".to_owned(),
            },
            true,
        )
        .unwrap();
        for name in [MARKER_NAME, READY_NAME] {
            let metadata = fs::symlink_metadata(root_path.join(name)).unwrap();
            assert!(metadata.is_file() && !metadata.file_type().is_symlink());
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
            assert_eq!(metadata.uid(), expected_owner_uid().unwrap());
        }
    }

    #[cfg(unix)]
    #[test]
    fn empty_root_is_claimed_once_and_same_session_can_relaunch() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root_path = fs::canonicalize(root.path()).unwrap();
        let session = "0123456789abcdef0123456789abcdef";
        assert_eq!(prepare_root(&root_path, session), Ok(()));
        let marker_metadata = fs::symlink_metadata(root_path.join(MARKER_NAME)).unwrap();
        assert_eq!(marker_metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(marker_metadata.uid(), expected_owner_uid().unwrap());
        assert!(fs::read_dir(&root_path).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains(".tmp-")));
        assert_eq!(prepare_root(&root_path, session), Ok(()));
        write_atomic_private(
            &root_path,
            READY_NAME,
            &OwnerSmokeReady {
                contract: OWNER_SMOKE_CONTRACT.to_owned(),
                session_id: session.to_owned(),
                launch_id: "11111111111111111111111111111111".to_owned(),
                pid: 42,
                state: "terminal_window_policy_ready".to_owned(),
            },
            true,
        )
        .unwrap();
        assert_eq!(prepare_root(&root_path, session), Ok(()));
        assert_eq!(
            prepare_root(&root_path, "fedcba9876543210fedcba9876543210"),
            Err(OwnerSmokeGateError::RootInUse)
        );
        let namespace = root_path.join(CURRENT_DATA_NAMESPACE);
        fs::create_dir_all(&namespace).unwrap();
        fs::write(namespace.join("config.json"), b"ordinary state").unwrap();
        assert_eq!(prepare_root(&root_path, session), Ok(()));

        let namespace_parent = root_path.join(CURRENT_DATA_NAMESPACE.split('/').next().unwrap());
        fs::set_permissions(&namespace_parent, fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(
            prepare_root(&root_path, session),
            Err(OwnerSmokeGateError::RootInUse)
        );
        fs::set_permissions(&namespace_parent, fs::Permissions::from_mode(0o755)).unwrap();

        let nested_link = namespace.join("link");
        symlink(root.path(), &nested_link).unwrap();
        assert_eq!(
            prepare_root(&root_path, session),
            Err(OwnerSmokeGateError::RootInUse)
        );
        fs::remove_file(nested_link).unwrap();
        let writable = namespace.join("world-writable");
        fs::write(&writable, b"x").unwrap();
        fs::set_permissions(&writable, fs::Permissions::from_mode(0o666)).unwrap();
        assert_eq!(
            prepare_root(&root_path, session),
            Err(OwnerSmokeGateError::RootInUse)
        );
        fs::remove_file(writable).unwrap();
        fs::set_permissions(
            root_path.join(MARKER_NAME),
            fs::Permissions::from_mode(0o400),
        )
        .unwrap();
        assert_eq!(
            prepare_root(&root_path, session),
            Err(OwnerSmokeGateError::RootInUse)
        );
        fs::set_permissions(
            root_path.join(MARKER_NAME),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        fs::set_permissions(
            root_path.join(READY_NAME),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        assert_eq!(
            prepare_root(&root_path, session),
            Err(OwnerSmokeGateError::RootInUse)
        );
    }

    #[cfg(unix)]
    #[test]
    fn unsafe_reused_and_symlink_roots_are_rejected_without_marker_mutation() {
        use std::os::unix::fs::symlink;

        let session = "0123456789abcdef0123456789abcdef";
        let occupied = tempfile::tempdir().unwrap();
        fs::set_permissions(occupied.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let occupied_path = fs::canonicalize(occupied.path()).unwrap();
        fs::write(occupied.path().join("foreign"), b"x").unwrap();
        assert_eq!(
            prepare_root(&occupied_path, session),
            Err(OwnerSmokeGateError::RootInUse)
        );
        assert!(!occupied.path().join(MARKER_NAME).exists());

        let permissive = tempfile::tempdir().unwrap();
        fs::set_permissions(permissive.path(), fs::Permissions::from_mode(0o755)).unwrap();
        let permissive_path = fs::canonicalize(permissive.path()).unwrap();
        assert_eq!(
            prepare_root(&permissive_path, session),
            Err(OwnerSmokeGateError::UnsafeRoot)
        );
        assert!(!permissive.path().join(MARKER_NAME).exists());

        let parent = tempfile::tempdir().unwrap();
        let target = parent.path().join("target");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
        let link = parent.path().join("link");
        symlink(&target, &link).unwrap();
        assert_eq!(
            prepare_root(&link, session),
            Err(OwnerSmokeGateError::UnsafeRoot)
        );
        assert!(!target.join(MARKER_NAME).exists());
    }
}

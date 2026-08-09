mod shell;

use std::cell::RefCell;
use std::error::Error;
use std::rc::Rc;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use gpui::{
    actions, div, prelude::*, px, size, App, Application, Bounds, Context, KeyBinding, Render,
    Timer, Window, WindowBounds, WindowOptions,
};
use gpui_component::Root;
use serde::Deserialize;
use shell::{
    LaunchAtLoginObservation, MacShell, OverlayPhase, PermissionObservation, PermissionValue,
    ShellEvent, TrayMicrophone, TrayPresentation,
};
use tokio::runtime::{Builder, Runtime};
use wrenflow_gpui::{
    app::{AppAction, AppModel, NavigationTarget, ShellRequest, ShellRequestReceiver},
    screens::AppScreens,
    ui,
};
use wrenflow_runtime::{
    start_production_runtime, LaunchAtLoginSnapshot, PermissionStatus, PermissionsSnapshot,
    RuntimeCommand, RuntimeEvent, RuntimeHandle, ShellCapabilities, UpdateStatus,
};

const WINDOW_TITLE: &str = "Wrenflow";

actions!(wrenflow_shell, [HideSettings]);

struct ShellView {
    shell: MacShell,
    screens: gpui::Entity<AppScreens>,
}

struct ShellEnvironment {
    shell: MacShell,
    async_runtime: Arc<Runtime>,
    runtime_handle: RuntimeHandle,
}

impl Render for ShellView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let hide_shell = self.shell;

        div()
            .on_action(move |_: &HideSettings, _, _| hide_shell.hide_main_window())
            .size_full()
            .child(self.screens.clone())
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Wrenflow GPUI failed to start: {error}");
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let async_runtime = Arc::new(
        Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("could not start Tokio runtime: {error}"))?,
    );
    let runtime_instance = {
        let _guard = async_runtime.enter();
        start_production_runtime()
            .map_err(|error| format!("could not start Wrenflow runtime: {error}"))?
    };
    let runtime_handle = runtime_instance.handle.clone();
    let runtime_instance = Arc::new(Mutex::new(Some(runtime_instance)));

    let application = Application::new().with_assets(ui::WrenflowAssets);
    let reopen_model = Rc::new(RefCell::new(None::<gpui::Entity<AppModel>>));
    let reopen_model_for_handler = Rc::clone(&reopen_model);
    let reopen_shell = MacShell;
    application.on_reopen(move |cx| {
        reopen_shell.show_main_window();
        let model = reopen_model_for_handler.borrow().clone();
        if let Some(model) = model {
            model.update(cx, |model, cx| {
                model.dispatch(AppAction::Navigate(NavigationTarget::Settings), cx);
            });
        }
    });
    application.run(move |cx: &mut App| {
        gpui_component::init(cx);
        ui::init(cx, ui::ThemeMode::Light);
        cx.bind_keys([KeyBinding::new("cmd-w", HideSettings, None)]);

        let app_model =
            cx.new(|cx| AppModel::new(runtime_handle.clone(), async_runtime.handle().clone(), cx));
        reopen_model.replace(Some(app_model.clone()));
        let shell_requests = match app_model.update(cx, |model, _| model.take_shell_requests()) {
            Some(receiver) => receiver,
            None => {
                eprintln!("AppModel shell request receiver was already taken");
                cx.quit();
                return;
            }
        };

        let bounds = Bounds::centered(None, size(px(760.0), px(620.0)), cx);
        let app_model_for_window = app_model.clone();
        let screens_slot = Rc::new(RefCell::new(None::<gpui::Entity<AppScreens>>));
        let screens_for_window = Rc::clone(&screens_slot);
        let window_handle = match cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    ..Default::default()
                }),
                focus: false,
                show: false,
                ..Default::default()
            },
            move |window, cx| {
                let screens =
                    cx.new(|cx| AppScreens::new(app_model_for_window.clone(), window, cx));
                screens_for_window.replace(Some(screens.clone()));
                let shell_view = cx.new(|_| ShellView {
                    shell: MacShell,
                    screens,
                });
                cx.new(|cx| Root::new(shell_view, window, cx))
            },
        ) {
            Ok(window) => window,
            Err(error) => {
                eprintln!("could not create GPUI settings window: {error}");
                cx.quit();
                return;
            }
        };
        let screens = match screens_slot.borrow().clone() {
            Some(screens) => screens,
            None => {
                eprintln!("GPUI settings window did not create its AppScreens root");
                cx.quit();
                return;
            }
        };

        let (shell, shell_events) = match MacShell::install(WINDOW_TITLE, env!("CARGO_PKG_VERSION"))
        {
            Ok(installed) => installed,
            Err(error) => {
                eprintln!("could not install AppKit shell: {error}");
                cx.quit();
                return;
            }
        };

        if let Err(error) = shell.update_tray(&tray_presentation(&runtime_handle)) {
            eprintln!("could not publish initial tray state: {error}");
        }
        report_shell_capabilities(&async_runtime, &runtime_handle);
        spawn_runtime_shell_adapter(&async_runtime, &runtime_handle, shell);
        poll_shell_requests(
            cx,
            shell_requests,
            shell,
            Arc::clone(&async_runtime),
            runtime_handle.clone(),
        );
        poll_shell_events(
            cx,
            app_model,
            screens.clone(),
            window_handle,
            shell_events,
            ShellEnvironment {
                shell,
                async_runtime: Arc::clone(&async_runtime),
                runtime_handle: runtime_handle.clone(),
            },
        );
        let accessibility_self_test = std::env::args()
            .any(|argument| argument == "--accessibility-self-test");
        poll_accessibility(
            cx,
            screens,
            window_handle,
            shell,
            accessibility_self_test,
        );

        let shutdown_state = Arc::clone(&runtime_instance);
        cx.on_app_quit(move |_| {
            let instance = shutdown_state
                .lock()
                .ok()
                .and_then(|mut instance| instance.take());
            async move {
                if let Some(instance) = instance {
                    if let Err(error) = instance.shutdown().await {
                        eprintln!("Wrenflow runtime shutdown failed: {error}");
                    }
                }
                shell.shutdown();
            }
        })
        .detach();

        if std::env::args().any(|argument| argument == "--shell-self-test")
            || accessibility_self_test
        {
            shell.show_overlay(OverlayPhase::Initializing, 0.0);
            shell.show_main_window();
        }
    });
    Ok(())
}

fn poll_shell_events(
    cx: &mut App,
    app_model: gpui::Entity<AppModel>,
    screens: gpui::Entity<AppScreens>,
    window_handle: gpui::WindowHandle<Root>,
    receiver: mpsc::Receiver<ShellEvent>,
    environment: ShellEnvironment,
) {
    cx.spawn(async move |cx| loop {
        Timer::after(Duration::from_millis(40)).await;
        loop {
            let event = match receiver.try_recv() {
                Ok(event) => event,
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => return,
            };
            if shell_event_opens_window(&event) {
                environment.shell.show_main_window();
            }
            if let Some(action) = shell_event_action(&event) {
                let _ = cx.update(|cx| {
                    app_model.update(cx, |model, cx| model.dispatch(action, cx));
                });
            }
            if let ShellEvent::AccessibilityAction(request) = &event {
                let request = request.clone();
                let screens = screens.clone();
                let _ = cx.update(|cx| {
                    let result = window_handle.update(cx, |_root, window, cx| {
                        let Some(action) = accessibility_action(&request.action) else {
                            eprintln!(
                                "native accessibility requested unknown action `{}`",
                                request.action
                            );
                            return;
                        };
                        if let Err(error) = screens.update(cx, |screens, cx| {
                            screens.perform_accessibility_action(
                                &request.id,
                                action,
                                request.value.as_deref(),
                                window,
                                cx,
                            )
                        }) {
                            eprintln!("native accessibility action was rejected: {error}");
                        }
                    });
                    if let Err(error) = result {
                        eprintln!("could not access GPUI window for accessibility action: {error}");
                    }
                });
            }
            dispatch_shell_observation(
                &event,
                Arc::clone(&environment.async_runtime),
                environment.runtime_handle.clone(),
            );
        }
    })
    .detach();
}

fn poll_accessibility(
    cx: &mut App,
    screens: gpui::Entity<AppScreens>,
    window_handle: gpui::WindowHandle<Root>,
    shell: MacShell,
    self_test: bool,
) {
    cx.spawn(async move |cx| {
        let mut last_publication = None::<(u64, Option<String>)>;
        let mut attempts = 0_u16;
        loop {
            Timer::after(Duration::from_millis(50)).await;
            attempts = attempts.saturating_add(1);
            let snapshot = match cx.update(|cx| {
                window_handle.update(cx, |_root, window, cx| {
                    screens
                        .read(cx)
                        .accessibility_snapshot(window, cx)
                })
            }) {
                Ok(Ok(snapshot)) => snapshot,
                Ok(Err(error)) => {
                    eprintln!("could not read GPUI accessibility snapshot: {error}");
                    return;
                }
                Err(_) => return,
            };
            if snapshot.nodes.is_empty() {
                if self_test && attempts >= 300 {
                    eprintln!("WRENFLOW_ACCESSIBILITY_SELF_TEST_FAILED no measured nodes");
                    shell.terminate();
                    return;
                }
                continue;
            }

            let publication = (snapshot.generation, snapshot.focused_id.clone());
            if last_publication.as_ref() == Some(&publication) {
                continue;
            }
            last_publication = Some(publication);
            let expected_nodes = snapshot.nodes.len();
            if let Err(error) = shell.update_accessibility(&snapshot) {
                eprintln!("could not publish GPUI accessibility tree: {error}");
                if self_test {
                    eprintln!("WRENFLOW_ACCESSIBILITY_SELF_TEST_FAILED bridge rejected snapshot");
                    shell.terminate();
                    return;
                }
                continue;
            }
            if self_test {
                let native_nodes = shell.accessibility_node_count();
                if usize::try_from(native_nodes).ok() == Some(expected_nodes) {
                    println!(
                        "WRENFLOW_ACCESSIBILITY_SELF_TEST_OK nodes={expected_nodes} generation={}",
                        snapshot.generation
                    );
                } else {
                    eprintln!(
                        "WRENFLOW_ACCESSIBILITY_SELF_TEST_FAILED Rust nodes={expected_nodes} native nodes={native_nodes}"
                    );
                }
                shell.terminate();
                return;
            }
        }
    })
    .detach();
}

fn accessibility_action(value: &str) -> Option<ui::AccessibilityAction> {
    match value {
        "press" => Some(ui::AccessibilityAction::Press),
        "focus" => Some(ui::AccessibilityAction::Focus),
        "increment" => Some(ui::AccessibilityAction::Increment),
        "decrement" => Some(ui::AccessibilityAction::Decrement),
        "setValue" => Some(ui::AccessibilityAction::SetValue),
        _ => None,
    }
}

fn poll_shell_requests(
    cx: &mut App,
    mut receiver: ShellRequestReceiver,
    shell: MacShell,
    async_runtime: Arc<Runtime>,
    runtime_handle: RuntimeHandle,
) {
    cx.spawn(async move |_| {
        while let Some(request) = receiver.recv().await {
            match request {
                ShellRequest::RequestMicrophonePermission => shell.request_microphone(),
                ShellRequest::RequestAccessibilityPermission => shell.request_accessibility(),
                ShellRequest::OpenMicrophoneSettings => shell.open_microphone_settings(),
                ShellRequest::OpenAccessibilitySettings => shell.open_accessibility_settings(),
                ShellRequest::SetLaunchAtLogin(enabled) => shell.set_launch_at_login(enabled),
                ShellRequest::CheckForUpdates => {
                    spawn_update_check(&async_runtime, runtime_handle.clone());
                }
                ShellRequest::OpenUrl { url } => {
                    if let Err(error) = shell.open_url(&url) {
                        eprintln!("could not open shell URL: {error}");
                    }
                }
            }
        }
    })
    .detach();
}

fn spawn_update_check(async_runtime: &Runtime, runtime_handle: RuntimeHandle) {
    if matches!(
        &runtime_handle.snapshot().shell.update_status,
        UpdateStatus::Checking
    ) {
        return;
    }
    drop(async_runtime.spawn(async move {
        if runtime_handle
            .request(RuntimeCommand::ReportUpdateStatus(UpdateStatus::Checking))
            .await
            .is_err()
        {
            return;
        }
        let status = check_for_update(env!("CARGO_PKG_VERSION"))
            .await
            .unwrap_or_else(|message| UpdateStatus::Error { message });
        if let Err(error) = runtime_handle
            .request(RuntimeCommand::ReportUpdateStatus(status))
            .await
        {
            eprintln!("could not publish update status: {error}");
        }
    }));
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    html_url: String,
    published_at: Option<String>,
    #[serde(default)]
    assets: Vec<GitHubReleaseAsset>,
}

#[derive(Deserialize)]
struct GitHubReleaseAsset {
    name: String,
    browser_download_url: String,
}

async fn check_for_update(current_version: &str) -> Result<UpdateStatus, String> {
    let client = reqwest::Client::builder()
        .user_agent("Wrenflow")
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|error| format!("could not configure update client: {error}"))?;
    let response = client
        .get("https://api.github.com/repos/IlyaGulya/wrenflow/releases/latest")
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|error| format!("network error while checking for updates: {error}"))?
        .error_for_status()
        .map_err(|error| format!("GitHub update check failed: {error}"))?;
    let release: GitHubRelease = response
        .json()
        .await
        .map_err(|error| format!("invalid GitHub update response: {error}"))?;
    let latest_version = release.tag_name.trim_start_matches('v').to_string();
    if !is_newer_version(&latest_version, current_version) {
        return Ok(UpdateStatus::UpToDate);
    }
    let download_url = release
        .assets
        .iter()
        .find(|asset| {
            let name = asset.name.to_ascii_lowercase();
            name.ends_with(".dmg") || name.ends_with(".zip")
        })
        .map(|asset| asset.browser_download_url.clone())
        .unwrap_or_else(|| release.html_url.clone());
    Ok(UpdateStatus::Available {
        latest_version,
        release_url: release.html_url,
        download_url,
        published_at_iso: release.published_at,
    })
}

fn is_newer_version(latest: &str, current: &str) -> bool {
    let Some(latest) = parse_version(latest) else {
        return false;
    };
    let Some(current) = parse_version(current) else {
        return false;
    };
    latest > current
}

fn parse_version(value: &str) -> Option<(u64, u64, u64)> {
    let base = value.split('-').next()?;
    let mut parts = base.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    Some((major, minor, patch))
}

fn shell_event_opens_window(event: &ShellEvent) -> bool {
    matches!(
        event,
        ShellEvent::OpenSettings | ShellEvent::OpenHistory | ShellEvent::OpenAbout
    )
}

fn shell_event_action(event: &ShellEvent) -> Option<AppAction> {
    match event {
        ShellEvent::OpenSettings => Some(AppAction::Navigate(NavigationTarget::Settings)),
        ShellEvent::OpenHistory => Some(AppAction::Navigate(NavigationTarget::History)),
        ShellEvent::OpenAbout => Some(AppAction::Navigate(NavigationTarget::About)),
        ShellEvent::SelectMicrophone(id) => Some(AppAction::SetSelectedMicrophone(id.clone())),
        ShellEvent::QuitRequested => Some(AppAction::RequestQuit),
        ShellEvent::OverlayAction(action) if action == "openMicrophoneSettings" => {
            Some(AppAction::OpenMicrophoneSettings)
        }
        ShellEvent::OverlayAction(action) if action == "openAccessibilitySettings" => {
            Some(AppAction::OpenAccessibilitySettings)
        }
        ShellEvent::OverlayAction(action) if action == "activate_selected_model" => {
            Some(AppAction::ActivateSelectedModel)
        }
        ShellEvent::OverlayAction(action) if action == "open_models" => {
            Some(AppAction::Navigate(NavigationTarget::Models))
        }
        ShellEvent::HotkeyPressed => Some(AppAction::HotkeyPressed),
        ShellEvent::HotkeyReleased(duration) => Some(AppAction::HotkeyReleased(*duration)),
        ShellEvent::OverlayAction(_)
        | ShellEvent::PermissionsChanged(_)
        | ShellEvent::LaunchAtLoginChanged(_)
        | ShellEvent::MainWindowHidden
        | ShellEvent::AccessibilityAction(_) => None,
    }
}

fn dispatch_shell_observation(
    event: &ShellEvent,
    async_runtime: Arc<Runtime>,
    runtime_handle: RuntimeHandle,
) {
    let command = match event {
        ShellEvent::PermissionsChanged(permissions) => Some(RuntimeCommand::ReportPermissions(
            permissions_snapshot(permissions.clone()),
        )),
        ShellEvent::LaunchAtLoginChanged(observation) => Some(RuntimeCommand::ReportLaunchAtLogin(
            launch_at_login_snapshot(observation.clone()),
        )),
        ShellEvent::OpenSettings
        | ShellEvent::OpenHistory
        | ShellEvent::OpenAbout
        | ShellEvent::SelectMicrophone(_)
        | ShellEvent::QuitRequested
        | ShellEvent::OverlayAction(_)
        | ShellEvent::HotkeyPressed
        | ShellEvent::HotkeyReleased(_)
        | ShellEvent::MainWindowHidden
        | ShellEvent::AccessibilityAction(_) => None,
    };
    if let Some(command) = command {
        drop(async_runtime.spawn(async move {
            if let Err(error) = runtime_handle.request(command).await {
                eprintln!("shell command was rejected by runtime: {error}");
            }
        }));
    }
}

fn report_shell_capabilities(async_runtime: &Runtime, runtime_handle: &RuntimeHandle) {
    let runtime_handle = runtime_handle.clone();
    drop(async_runtime.spawn(async move {
        let capabilities = ShellCapabilities {
            launch_at_login: true,
            updates: true,
            local_transcription: true,
            microphone_selection: true,
            tray: true,
            overlays: true,
        };
        if let Err(error) = runtime_handle
            .request(RuntimeCommand::ReportShellCapabilities(capabilities))
            .await
        {
            eprintln!("could not publish GPUI shell capabilities: {error}");
        }
    }));
}

fn spawn_runtime_shell_adapter(
    async_runtime: &Runtime,
    runtime_handle: &RuntimeHandle,
    shell: MacShell,
) {
    let mut snapshots = runtime_handle.subscribe_snapshots();
    let snapshot_handle = runtime_handle.clone();
    drop(async_runtime.spawn(async move {
        while snapshots.changed().await.is_ok() {
            let snapshot = snapshots.borrow_and_update().clone();
            let _ = shell.update_tray(&tray_presentation(&snapshot_handle));
            match snapshot.pipeline.name() {
                "starting" | "initializing" => {
                    shell.show_overlay(OverlayPhase::Initializing, 0.0);
                }
                "recording" => shell.show_overlay(OverlayPhase::Recording, 0.0),
                "transcribing" => shell.show_overlay(OverlayPhase::Transcribing, 0.0),
                _ => shell.hide_overlay(),
            }
        }
    }));

    let mut audio_levels = runtime_handle.subscribe_audio_level();
    drop(async_runtime.spawn(async move {
        while audio_levels.changed().await.is_ok() {
            shell.update_overlay_audio(*audio_levels.borrow_and_update());
        }
    }));

    let mut events = runtime_handle.subscribe_events();
    drop(async_runtime.spawn(async move {
        while let Ok(envelope) = events.recv().await {
            match envelope.event {
                RuntimeEvent::PipelineError { message, action } => {
                    let result = shell.show_error(
                        &message,
                        action.as_ref().map(|action| action.label.as_str()),
                        action.as_ref().map(|action| action.id.as_str()),
                    );
                    if let Err(error) = result {
                        eprintln!("could not show native error toast: {error}");
                    }
                }
                RuntimeEvent::TranscriptReady { .. } | RuntimeEvent::PasteCompleted => {
                    shell.hide_overlay();
                }
                RuntimeEvent::QuitRequested => shell.terminate(),
                RuntimeEvent::PlaySound(_) | RuntimeEvent::HistoryEntryAdded(_) => {}
            }
        }
    }));
}

fn tray_presentation(runtime_handle: &RuntimeHandle) -> TrayPresentation {
    let snapshot = runtime_handle.snapshot();
    TrayPresentation {
        version: env!("CARGO_PKG_VERSION").into(),
        status: snapshot.pipeline.status_text().into(),
        launch_at_login: snapshot.shell.launch_at_login.enabled,
        microphones: snapshot
            .audio_devices
            .devices
            .iter()
            .map(|device| TrayMicrophone {
                id: device.id.clone(),
                name: device.name.clone(),
            })
            .collect(),
        selected_microphone_id: snapshot.settings.selected_microphone_id.clone(),
        selected_hotkey: hotkey_keycode(&snapshot.settings.selected_hotkey),
        update_url: match &snapshot.shell.update_status {
            UpdateStatus::Available {
                release_url,
                download_url,
                ..
            } => Some(if download_url.is_empty() {
                release_url.clone()
            } else {
                download_url.clone()
            }),
            _ => None,
        },
    }
}

fn hotkey_keycode(value: &str) -> u16 {
    match value {
        "fn" | "fnKey" => 63,
        "rightOption" => 61,
        "f5" => 96,
        _ => value.parse().unwrap_or(63),
    }
}

fn permissions_snapshot(observation: PermissionObservation) -> PermissionsSnapshot {
    PermissionsSnapshot {
        has_snapshot: true,
        microphone: permission_status(observation.microphone),
        accessibility: permission_status(observation.accessibility),
    }
}

const fn permission_status(value: PermissionValue) -> PermissionStatus {
    match value {
        PermissionValue::Unknown => PermissionStatus::Unknown,
        PermissionValue::Granted => PermissionStatus::Granted,
        PermissionValue::Denied => PermissionStatus::Denied,
        PermissionValue::Restricted => PermissionStatus::Restricted,
    }
}

fn launch_at_login_snapshot(observation: LaunchAtLoginObservation) -> LaunchAtLoginSnapshot {
    LaunchAtLoginSnapshot {
        is_available: observation.is_available,
        enabled: observation.enabled,
        is_loading: observation.is_loading,
        unavailable_reason: observation.unavailable_reason,
        error_message: observation.error_message,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        accessibility_action, hotkey_keycode, is_newer_version, parse_version,
        shell_event_action, shell_event_opens_window, AppAction, NavigationTarget, ShellEvent,
    };
    use wrenflow_gpui::ui::AccessibilityAction;

    #[test]
    fn version_comparison_matches_release_policy() {
        assert!(is_newer_version("0.4.0", "0.3.9"));
        assert!(is_newer_version("1.0.0", "0.99.99"));
        assert!(!is_newer_version("0.3.0", "0.3.0"));
        assert!(!is_newer_version("not-a-version", "0.3.0"));
        assert_eq!(parse_version("1.2.3-beta.1"), Some((1, 2, 3)));
    }

    #[test]
    fn hotkey_presets_and_invalid_values_have_stable_codes() {
        assert_eq!(hotkey_keycode("rightOption"), 61);
        assert_eq!(hotkey_keycode("fn"), 63);
        assert_eq!(hotkey_keycode("f5"), 96);
        assert_eq!(hotkey_keycode("96"), 96);
        assert_eq!(hotkey_keycode("invalid"), 63);
    }

    #[test]
    fn native_accessibility_actions_use_the_typed_screen_boundary() {
        assert_eq!(
            accessibility_action("press"),
            Some(AccessibilityAction::Press)
        );
        assert_eq!(
            accessibility_action("setValue"),
            Some(AccessibilityAction::SetValue)
        );
        assert_eq!(accessibility_action("unknown"), None);
    }

    #[test]
    fn native_navigation_and_hotkeys_enter_the_typed_app_model_boundary() {
        assert_eq!(
            shell_event_action(&ShellEvent::OpenHistory),
            Some(AppAction::Navigate(NavigationTarget::History))
        );
        assert!(shell_event_opens_window(&ShellEvent::OpenAbout));
        assert!(!shell_event_opens_window(&ShellEvent::HotkeyPressed));
        assert_eq!(
            shell_event_action(&ShellEvent::SelectMicrophone("built-in".into())),
            Some(AppAction::SetSelectedMicrophone("built-in".into()))
        );
        assert_eq!(
            shell_event_action(&ShellEvent::HotkeyReleased(
                std::time::Duration::from_millis(480)
            )),
            Some(AppAction::HotkeyReleased(std::time::Duration::from_millis(
                480
            )))
        );
        assert_eq!(
            shell_event_action(&ShellEvent::OverlayAction(
                "openAccessibilitySettings".into()
            )),
            Some(AppAction::OpenAccessibilitySettings)
        );
        assert_eq!(
            shell_event_action(&ShellEvent::OverlayAction("activate_selected_model".into())),
            Some(AppAction::ActivateSelectedModel)
        );
        assert_eq!(
            shell_event_action(&ShellEvent::OverlayAction("open_models".into())),
            Some(AppAction::Navigate(NavigationTarget::Models))
        );
    }
}

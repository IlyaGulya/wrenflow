mod shell;

use std::cell::RefCell;
use std::error::Error;
use std::rc::Rc;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex,
};
use std::time::Duration;

use gpui::{
    actions, div, prelude::*, px, size, App, Application, Bounds, Context, KeyBinding, Render,
    Timer, Window, WindowBounds, WindowOptions,
};
use gpui_component::Root;
use shell::{
    LaunchAtLoginObservation, MacShell, OverlayPhase, PermissionObservation, PermissionValue,
    ShellEvent, TrayMicrophone, TrayPresentation, WindowLayout,
};
use tokio::runtime::{Builder, Runtime};
use wrenflow_gpui::{
    app::{AppAction, AppModel, NavigationTarget, ShellRequest, ShellRequestReceiver},
    screens::AppScreens,
    ui,
};
use wrenflow_runtime::support::{SupportContext, SupportUpdateState};
use wrenflow_runtime::update::{
    UpdateChannel, UpdateCheckOutcome, UpdateError, UpdateFailureCode, UpdateSession,
};
use wrenflow_runtime::{
    diagnostics::{
        emit_diagnostic, initialize_production_diagnostics, DiagnosticCategory, DiagnosticCode,
        DiagnosticEvent, DiagnosticLevel,
    },
    start_production_runtime, LaunchAtLoginSnapshot, PermissionStatus, PermissionsSnapshot,
    RuntimeCommand, RuntimeEvent, RuntimeHandle, RuntimeInstance, ShellCapabilities,
    SupportBundleStatus, ThemePreference, TranscriptDisposition, UpdateStatus,
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

enum RuntimeShellUpdate {
    Tray(TrayPresentation),
    Theme(ThemePreference),
    ShowOverlay(OverlayPhase, f32),
    UpdateOverlayAudio(f32),
    HideOverlay,
    PasteCompleted,
    ShowError {
        message: String,
        action_label: Option<String>,
        action_id: Option<String>,
    },
    Terminate,
}

struct UpdateOperationGuard(Arc<AtomicBool>);

impl Drop for UpdateOperationGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

fn begin_update_operation(busy: &Arc<AtomicBool>) -> Option<UpdateOperationGuard> {
    busy.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .ok()
        .map(|_| UpdateOperationGuard(Arc::clone(busy)))
}

#[derive(Clone)]
struct AppWindowContext {
    handle: gpui::WindowHandle<Root>,
    screens: gpui::Entity<AppScreens>,
}

type AppWindowSlot = Rc<RefCell<Option<AppWindowContext>>>;

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
    let arguments = std::env::args().collect::<Vec<_>>();
    let performance_request =
        match wrenflow_runtime::performance::prepare_performance_self_test(&arguments) {
            Ok(request) => request,
            Err(error) => {
                let _closed_failure_code = error.code();
                std::process::exit(64);
            }
        };
    if let Some(result) = wrenflow_runtime::recovery::run_reset_helper_from_args(&arguments) {
        std::process::exit(i32::from(result.is_err()));
    }
    initialize_production_diagnostics();
    if let Some(result) = wrenflow_runtime::update::run_update_helper_from_args(&arguments) {
        if result.is_err() {
            report_diagnostic_failure(DiagnosticCategory::Updates, DiagnosticCode::UpdateFailed);
        }
        std::process::exit(i32::from(result.is_err()));
    }
    if run(performance_request).is_err() {
        report_diagnostic_failure(
            DiagnosticCategory::Lifecycle,
            DiagnosticCode::GpuiStartupFailed,
        );
    }
}

fn report_diagnostic_failure(category: DiagnosticCategory, code: DiagnosticCode) {
    emit_diagnostic(DiagnosticEvent::new(category, DiagnosticLevel::Error, code));
}

fn run(
    performance_request: Option<wrenflow_runtime::performance::PerformanceSelfTestRequest>,
) -> Result<(), Box<dyn Error>> {
    MacShell::prepare_process();
    if !MacShell::claim_single_instance() {
        if performance_request.is_some() {
            return Err("performance self-test requires an unused bundle instance".into());
        }
        return Ok(());
    }

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
    let app_window = Rc::new(RefCell::new(None::<AppWindowContext>));
    let reopen_model_for_handler = Rc::clone(&reopen_model);
    let app_window_for_handler = Rc::clone(&app_window);
    let reopen_shell = MacShell;
    application.on_reopen(move |cx| {
        let model = reopen_model_for_handler.borrow().clone();
        if let Some(model) = model {
            model.update(cx, |model, cx| {
                model.dispatch(AppAction::Navigate(NavigationTarget::Settings), cx);
            });
            if ensure_app_window(cx, &model, &app_window_for_handler).is_err() {
                report_diagnostic_failure(
                    DiagnosticCategory::Lifecycle,
                    DiagnosticCode::GpuiWindowCreateFailed,
                );
                return;
            }
            reopen_shell
                .apply_window_layout(WindowLayout::Settings)
                .ok();
            reopen_shell.show_main_window();
        }
    });
    application.run(move |cx: &mut App| {
        gpui_component::init(cx);
        ui::init(
            cx,
            ui::ThemeMode::for_window_appearance(cx.window_appearance()),
        );
        cx.bind_keys([KeyBinding::new("cmd-w", HideSettings, None)]);

        let app_model =
            cx.new(|cx| AppModel::new(runtime_handle.clone(), async_runtime.handle().clone(), cx));
        reopen_model.replace(Some(app_model.clone()));
        let shell_requests = match app_model.update(cx, |model, _| model.take_shell_requests()) {
            Some(receiver) => receiver,
            None => {
                report_diagnostic_failure(
                    DiagnosticCategory::Bridge,
                    DiagnosticCode::ShellRequestReceiverUnavailable,
                );
                cx.quit();
                return;
            }
        };

        let (shell, shell_events) = match MacShell::install(WINDOW_TITLE, env!("CARGO_PKG_VERSION"))
        {
            Ok(installed) => installed,
            Err(_) => {
                report_diagnostic_failure(
                    DiagnosticCategory::Bridge,
                    DiagnosticCode::AppKitShellInstallFailed,
                );
                cx.quit();
                return;
            }
        };

        if let Some(paths) = performance_request
            .as_ref()
            .and_then(|request| request.interaction_driver_paths())
        {
            app_model.update(cx, |model, cx| {
                model.dispatch(
                    AppAction::SetTranscriptDisposition(TranscriptDisposition::Paste),
                    cx,
                );
            });
            if shell
                .start_performance_interaction(paths.ready_path(), paths.report_path())
                .is_err()
            {
                report_diagnostic_failure(
                    DiagnosticCategory::Bridge,
                    DiagnosticCode::SwiftShellFailure,
                );
                cx.quit();
                return;
            }
        }

        let tray_projection_ready = shell
            .update_tray(&tray_presentation(&runtime_handle))
            .is_ok();
        if !tray_projection_ready {
            report_diagnostic_failure(
                DiagnosticCategory::Bridge,
                DiagnosticCode::TrayPublishFailed,
            );
        }
        let accessibility_self_test =
            std::env::args().any(|argument| argument == "--accessibility-self-test");
        let shell_self_test = std::env::args().any(|argument| argument == "--shell-self-test");
        poll_window_policy(
            cx,
            app_model.clone(),
            Rc::clone(&app_window),
            shell,
            shell_self_test || accessibility_self_test,
        );
        report_shell_capabilities(&async_runtime, &runtime_handle);
        if wrenflow_runtime::recovery::mark_production_launch_ready().is_err() {
            report_diagnostic_failure(
                DiagnosticCategory::Lifecycle,
                DiagnosticCode::RecoveryStateWriteFailed,
            );
        }
        let update_session = Arc::new(UpdateSession::new());
        let update_busy = Arc::new(AtomicBool::new(false));
        spawn_update_recovery(
            &async_runtime,
            runtime_handle.clone(),
            Arc::clone(&update_busy),
        );
        let (runtime_shell_sender, runtime_shell_receiver) = mpsc::channel();
        spawn_runtime_shell_adapter(&async_runtime, &runtime_handle, runtime_shell_sender);
        poll_runtime_shell_updates(
            cx,
            runtime_shell_receiver,
            shell,
            Arc::clone(&async_runtime),
            Arc::clone(&runtime_instance),
        );
        poll_shell_requests(
            cx,
            shell_requests,
            shell,
            Arc::clone(&async_runtime),
            runtime_handle.clone(),
            update_session,
            update_busy,
        );
        poll_shell_events(
            cx,
            app_model.clone(),
            Rc::clone(&app_window),
            shell_events,
            ShellEnvironment {
                shell,
                async_runtime: Arc::clone(&async_runtime),
                runtime_handle: runtime_handle.clone(),
            },
        );
        poll_accessibility(cx, Rc::clone(&app_window), shell, accessibility_self_test);

        let shutdown_state = Arc::clone(&runtime_instance);
        cx.on_app_quit(move |_| {
            // The callback itself runs at the GPUI/AppKit boundary. Tear down
            // native shell state here, before returning an async future, so no
            // background shutdown executor can synchronously hop to main.
            shell.shutdown();
            let instance = shutdown_state
                .lock()
                .ok()
                .and_then(|mut instance| instance.take());
            async move {
                if let Some(instance) = instance {
                    if instance.shutdown().await.is_err() {
                        report_diagnostic_failure(
                            DiagnosticCategory::Lifecycle,
                            DiagnosticCode::RuntimeShutdownFailed,
                        );
                    }
                }
            }
        })
        .detach();

        if let Some(code) = menu_bar_ready_code(tray_projection_ready) {
            emit_diagnostic(DiagnosticEvent::new(
                DiagnosticCategory::Lifecycle,
                DiagnosticLevel::Info,
                code,
            ));
        }

        if let Some(request) = performance_request {
            app_model.read(cx).start_performance_self_test(request);
        }

        if shell_self_test || accessibility_self_test {
            shell.show_overlay(OverlayPhase::Initializing, 0.0);
        }
    });
    Ok(())
}

fn ensure_app_window(
    cx: &mut App,
    app_model: &gpui::Entity<AppModel>,
    slot: &AppWindowSlot,
) -> Result<(), String> {
    if slot.borrow().is_some() {
        return Ok(());
    }
    let route = app_model.read(cx).presentation().active_route;
    let frame_size = match window_layout(route) {
        WindowLayout::Compact => size(px(340.0), px(380.0)),
        WindowLayout::Settings => size(px(720.0), px(520.0)),
    };
    let bounds = Bounds::centered(None, frame_size, cx);
    let app_model_for_window = app_model.clone();
    let screens_slot = Rc::new(RefCell::new(None::<gpui::Entity<AppScreens>>));
    let screens_for_window = Rc::clone(&screens_slot);
    let handle = cx
        .open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: Some(gpui::TitlebarOptions {
                    title: Some(WINDOW_TITLE.into()),
                    appears_transparent: true,
                    ..Default::default()
                }),
                focus: false,
                show: false,
                window_min_size: Some(size(px(300.0), px(340.0))),
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
        )
        .map_err(|error| error.to_string())?;
    let screens = screens_slot
        .borrow()
        .clone()
        .ok_or_else(|| "GPUI window did not create AppScreens".to_string())?;
    slot.replace(Some(AppWindowContext { handle, screens }));
    Ok(())
}

fn remove_app_window(cx: &mut App, slot: &AppWindowSlot) {
    let Some(window_context) = slot.borrow_mut().take() else {
        return;
    };
    if window_context
        .handle
        .update(cx, |_root, window, _cx| window.remove_window())
        .is_err()
    {
        report_diagnostic_failure(
            DiagnosticCategory::Lifecycle,
            DiagnosticCode::GpuiWindowRemoveFailed,
        );
    }
}

fn poll_window_policy(
    cx: &mut App,
    app_model: gpui::Entity<AppModel>,
    app_window: AppWindowSlot,
    shell: MacShell,
    force_visible: bool,
) {
    cx.spawn(async move |cx| {
        let mut last_route = None;
        let mut auto_visible = false;
        loop {
            Timer::after(Duration::from_millis(40)).await;
            let route = match cx.update(|cx| app_model.read(cx).presentation().active_route) {
                Ok(route) => route,
                Err(_) => return,
            };
            if last_route == Some(route) {
                continue;
            }
            last_route = Some(route);

            let wants_auto_window = force_visible || route_opens_automatically(route);
            if wants_auto_window && !auto_visible {
                if cx
                    .update(|cx| ensure_app_window(cx, &app_model, &app_window))
                    .is_err()
                {
                    report_diagnostic_failure(
                        DiagnosticCategory::Bridge,
                        DiagnosticCode::GpuiAppAccessFailed,
                    );
                    continue;
                }
                if shell.apply_window_layout(window_layout(route)).is_err() {
                    report_diagnostic_failure(
                        DiagnosticCategory::Bridge,
                        DiagnosticCode::GpuiWindowLayoutFailed,
                    );
                }
                shell.show_main_window();
                auto_visible = true;
            } else if !wants_auto_window && auto_visible {
                let _ = cx.update(|cx| remove_app_window(cx, &app_window));
                shell.hide_main_window();
                auto_visible = false;
            } else if app_window.borrow().is_some()
                && shell.apply_window_layout(window_layout(route)).is_err()
            {
                report_diagnostic_failure(
                    DiagnosticCategory::Bridge,
                    DiagnosticCode::GpuiWindowLayoutFailed,
                );
            }
        }
    })
    .detach();
}

fn window_layout(route: NavigationTarget) -> WindowLayout {
    match route {
        NavigationTarget::Loading
        | NavigationTarget::Onboarding
        | NavigationTarget::PermissionRecovery => WindowLayout::Compact,
        NavigationTarget::Settings
        | NavigationTarget::Models
        | NavigationTarget::History
        | NavigationTarget::About => WindowLayout::Settings,
    }
}

fn route_opens_automatically(route: NavigationTarget) -> bool {
    matches!(
        route,
        NavigationTarget::Onboarding | NavigationTarget::PermissionRecovery
    )
}

fn poll_shell_events(
    cx: &mut App,
    app_model: gpui::Entity<AppModel>,
    app_window: AppWindowSlot,
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
            if let Some(action) = shell_event_action(&event) {
                let _ = cx.update(|cx| {
                    app_model.update(cx, |model, cx| model.dispatch(action, cx));
                });
            }
            if let ShellEvent::AccessibilityPreferencesChanged(preferences) = &event {
                let preferences = ui::AccessibilityPreferences {
                    increase_contrast: preferences.increase_contrast,
                    differentiate_without_color: preferences.differentiate_without_color,
                    reduce_motion: preferences.reduce_motion,
                    reduce_transparency: preferences.reduce_transparency,
                    text_scale_percent: preferences.text_scale_percent,
                };
                let window_context = app_window.borrow().clone();
                let _ = cx.update(|cx| {
                    ui::install_accessibility_preferences(cx, preferences);
                    if let Some(window_context) = window_context {
                        let _ = window_context
                            .handle
                            .update(cx, |_root, window, _| window.refresh());
                    }
                });
            }
            if matches!(event, ShellEvent::MainWindowHidden) {
                let _ = cx.update(|cx| remove_app_window(cx, &app_window));
            }
            if shell_event_opens_window(&event) {
                let app_model = app_model.clone();
                let app_window = Rc::clone(&app_window);
                let route = cx
                    .update(|cx| {
                        ensure_app_window(cx, &app_model, &app_window)?;
                        Ok::<_, String>(app_model.read(cx).presentation().active_route)
                    })
                    .ok()
                    .and_then(Result::ok);
                if let Some(route) = route {
                    if environment
                        .shell
                        .apply_window_layout(window_layout(route))
                        .is_err()
                    {
                        report_diagnostic_failure(
                            DiagnosticCategory::Bridge,
                            DiagnosticCode::GpuiWindowLayoutFailed,
                        );
                    }
                    environment.shell.show_main_window();
                } else {
                    report_diagnostic_failure(
                        DiagnosticCategory::Lifecycle,
                        DiagnosticCode::GpuiWindowCreateFailed,
                    );
                }
            }
            if let ShellEvent::AccessibilityAction(request) = &event {
                let request = request.clone();
                let window_context = app_window.borrow().clone();
                let _ = cx.update(|cx| {
                    let Some(window_context) = window_context else {
                        return;
                    };
                    let screens = window_context.screens.clone();
                    let result = window_context.handle.update(cx, |_root, window, cx| {
                        let Some(action) = accessibility_action(&request.action) else {
                            report_diagnostic_failure(
                                DiagnosticCategory::Bridge,
                                DiagnosticCode::AccessibilityActionUnknown,
                            );
                            return;
                        };
                        let action_result = screens.update(cx, |screens, cx| {
                            screens.perform_accessibility_action(
                                &request.id,
                                action,
                                request.value.as_deref(),
                                window,
                                cx,
                            )
                        });
                        if action_result.is_err() {
                            report_diagnostic_failure(
                                DiagnosticCategory::Bridge,
                                DiagnosticCode::AccessibilityActionRejected,
                            );
                        } else {
                            // Native AX actions arrive outside GPUI's pointer
                            // dispatch. Repaint explicitly so an app-local
                            // theme press and every other typed mutation are
                            // visible on the same window without a relaunch.
                            cx.notify();
                            window.refresh();
                        }
                    });
                    if result.is_err() {
                        report_diagnostic_failure(
                            DiagnosticCategory::Bridge,
                            DiagnosticCode::GpuiAppAccessFailed,
                        );
                    } else {
                        // A native NSAccessibility action is delivered outside
                        // GPUI's pointer/key event pump. Wake every window after
                        // the typed mutation so the pixels and republished AX
                        // snapshot advance in the same occurrence.
                        cx.refresh_windows();
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

fn poll_accessibility(cx: &mut App, app_window: AppWindowSlot, shell: MacShell, self_test: bool) {
    cx.spawn(async move |cx| {
        // Accessibility generations are local to each AppScreens entity. A
        // hidden settings window is destroyed and recreated, so generation 1
        // in the new entity must not be deduplicated against generation 1 in
        // the previous window.
        let mut last_publication = None::<(u64, u64, Option<String>)>;
        let mut attempts = 0_u16;
        loop {
            Timer::after(Duration::from_millis(50)).await;
            attempts = attempts.saturating_add(1);
            let Some(window_context) = app_window.borrow().clone() else {
                last_publication = None;
                continue;
            };
            let snapshot = match cx.update(|cx| {
                window_context.handle.update(cx, |_root, window, cx| {
                    window_context
                        .screens
                        .read(cx)
                        .accessibility_snapshot(window, cx)
                })
            }) {
                Ok(Ok(snapshot)) => snapshot,
                Ok(Err(_)) => {
                    report_diagnostic_failure(
                        DiagnosticCategory::Bridge,
                        DiagnosticCode::AccessibilitySnapshotFailed,
                    );
                    app_window.borrow_mut().take();
                    last_publication = None;
                    continue;
                }
                Err(_) => {
                    app_window.borrow_mut().take();
                    last_publication = None;
                    continue;
                }
            };
            if snapshot.nodes.is_empty() {
                if self_test && attempts >= 300 {
                    eprintln!("WRENFLOW_ACCESSIBILITY_SELF_TEST_FAILED no measured nodes");
                    shell.terminate();
                    return;
                }
                continue;
            }

            let publication = (
                window_context.screens.entity_id().as_u64(),
                snapshot.generation,
                snapshot.focused_id.clone(),
            );
            if last_publication.as_ref() == Some(&publication) {
                continue;
            }
            let expected_nodes = snapshot.nodes.len();
            if shell.update_accessibility(&snapshot).is_err() {
                report_diagnostic_failure(
                    DiagnosticCategory::Bridge,
                    DiagnosticCode::AccessibilityTreePublishFailed,
                );
                if self_test {
                    eprintln!("WRENFLOW_ACCESSIBILITY_SELF_TEST_FAILED bridge rejected snapshot");
                    shell.terminate();
                    return;
                }
                continue;
            }
            last_publication = Some(publication);
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
    updates: Arc<UpdateSession>,
    update_busy: Arc<AtomicBool>,
) {
    cx.spawn(async move |_| {
        while let Some(request) = receiver.recv().await {
            match request {
                ShellRequest::RequestMicrophonePermission => shell.request_microphone(),
                ShellRequest::RequestAccessibilityPermission => shell.request_accessibility(),
                ShellRequest::OpenMicrophoneSettings => shell.open_microphone_settings(),
                ShellRequest::OpenAccessibilitySettings => shell.open_accessibility_settings(),
                ShellRequest::SetLaunchAtLogin(enabled) => shell.set_launch_at_login(enabled),
                ShellRequest::CheckForUpdates(channel) => {
                    spawn_update_check(
                        &async_runtime,
                        runtime_handle.clone(),
                        Arc::clone(&updates),
                        Arc::clone(&update_busy),
                        channel,
                    );
                }
                ShellRequest::DownloadAvailableUpdate => {
                    spawn_update_download(
                        &async_runtime,
                        runtime_handle.clone(),
                        Arc::clone(&updates),
                        Arc::clone(&update_busy),
                    );
                }
                ShellRequest::InstallReadyUpdate => {
                    spawn_update_install(
                        &async_runtime,
                        runtime_handle.clone(),
                        Arc::clone(&updates),
                        Arc::clone(&update_busy),
                    );
                }
                ShellRequest::ExportSupportBundle => {
                    spawn_support_export(&async_runtime, runtime_handle.clone());
                }
                ShellRequest::ResetCurrentData => {
                    spawn_current_data_reset(&async_runtime, runtime_handle.clone());
                }
            }
        }
    })
    .detach();
}

fn spawn_update_check(
    async_runtime: &Runtime,
    runtime_handle: RuntimeHandle,
    updates: Arc<UpdateSession>,
    busy: Arc<AtomicBool>,
    channel: UpdateChannel,
) {
    if matches!(
        &runtime_handle.snapshot().shell.update_status,
        UpdateStatus::Checking { .. }
            | UpdateStatus::Downloading { .. }
            | UpdateStatus::ReadyToInstall { .. }
            | UpdateStatus::Installing { .. }
    ) {
        return;
    }
    let Some(operation) = begin_update_operation(&busy) else {
        return;
    };
    drop(async_runtime.spawn(async move {
        let _operation = operation;
        if publish_update_status(&runtime_handle, UpdateStatus::Checking { channel })
            .await
            .is_err()
        {
            return;
        }
        let current_version = match wrenflow_runtime::update::current_installed_version() {
            Ok(version) => version,
            Err(error) => {
                let _ = publish_update_status(&runtime_handle, update_error_status(error)).await;
                return;
            }
        };
        let status = match updates.check(&current_version, channel).await {
            Ok(UpdateCheckOutcome::UpToDate) => UpdateStatus::UpToDate { channel },
            Ok(UpdateCheckOutcome::Available(candidate)) => UpdateStatus::Available {
                latest_version: candidate.version,
                channel: candidate.channel,
                published_at_iso: candidate.published_at_iso,
                size_bytes: candidate.size_bytes,
            },
            Err(error) => update_error_status(error),
        };
        let _ = publish_update_status(&runtime_handle, status).await;
    }));
}

fn spawn_update_download(
    async_runtime: &Runtime,
    runtime_handle: RuntimeHandle,
    updates: Arc<UpdateSession>,
    busy: Arc<AtomicBool>,
) {
    let (latest_version, total_bytes) = match &runtime_handle.snapshot().shell.update_status {
        UpdateStatus::Available {
            latest_version,
            size_bytes,
            ..
        } => (latest_version.clone(), *size_bytes),
        _ => return,
    };
    let Some(operation) = begin_update_operation(&busy) else {
        return;
    };
    drop(async_runtime.spawn(async move {
        let _operation = operation;
        if publish_update_status(
            &runtime_handle,
            UpdateStatus::Downloading {
                latest_version: latest_version.clone(),
                total_bytes,
            },
        )
        .await
        .is_err()
        {
            return;
        }
        let result = match updates.download_available().await {
            Ok(_) => {
                let updates = Arc::clone(&updates);
                tokio::task::spawn_blocking(move || updates.prepare_downloaded())
                    .await
                    .map_err(|_| UpdateError {
                        code: UpdateFailureCode::StagingFailed,
                        retryable: true,
                        retry_after_seconds: None,
                    })
                    .and_then(|result| result)
            }
            Err(error) => Err(error),
        };
        let status = match result {
            Ok(prepared) => UpdateStatus::ReadyToInstall {
                latest_version: prepared.version,
            },
            Err(error) => update_error_status(error),
        };
        let _ = publish_update_status(&runtime_handle, status).await;
    }));
}

fn spawn_update_install(
    async_runtime: &Runtime,
    runtime_handle: RuntimeHandle,
    updates: Arc<UpdateSession>,
    busy: Arc<AtomicBool>,
) {
    if !matches!(
        runtime_handle.snapshot().shell.update_status,
        UpdateStatus::ReadyToInstall { .. }
    ) {
        return;
    }
    let Some(operation) = begin_update_operation(&busy) else {
        return;
    };
    drop(async_runtime.spawn(async move {
        let _operation = operation;
        let status = match updates.schedule_prepared() {
            Ok(version) => UpdateStatus::Installing {
                latest_version: version,
            },
            Err(error) => {
                let _ = publish_update_status(&runtime_handle, update_error_status(error)).await;
                return;
            }
        };
        if publish_update_status(&runtime_handle, status).await.is_ok() {
            let _ = runtime_handle.request(RuntimeCommand::RequestQuit).await;
        }
    }));
}

fn spawn_update_recovery(
    async_runtime: &Runtime,
    runtime_handle: RuntimeHandle,
    busy: Arc<AtomicBool>,
) {
    let Some(operation) = begin_update_operation(&busy) else {
        return;
    };
    drop(async_runtime.spawn(async move {
        let _operation = operation;
        let result =
            tokio::task::spawn_blocking(wrenflow_runtime::update::finalize_update_after_ready)
                .await;
        match result {
            Ok(Ok(_)) => {}
            Ok(Err(error)) => {
                let _ = publish_update_status(&runtime_handle, update_error_status(error)).await;
            }
            Err(_) => {
                let _ = publish_update_status(
                    &runtime_handle,
                    UpdateStatus::RecoveryRequired {
                        code: UpdateFailureCode::RecoveryRequired,
                    },
                )
                .await;
            }
        }
    }));
}

fn spawn_support_export(async_runtime: &Runtime, runtime_handle: RuntimeHandle) {
    if matches!(
        runtime_handle.snapshot().shell.support_bundle_status,
        SupportBundleStatus::Exporting
    ) {
        return;
    }
    drop(async_runtime.spawn(async move {
        if publish_support_status(&runtime_handle, SupportBundleStatus::Exporting)
            .await
            .is_err()
        {
            return;
        }
        let snapshot = runtime_handle.snapshot();
        let context = SupportContext {
            recovery: snapshot.recovery.clone(),
            update_state: support_update_state(&snapshot.shell.update_status),
        };
        let result = tokio::task::spawn_blocking(move || {
            wrenflow_runtime::support::export_support_bundle_to_downloads(context)
        })
        .await;
        let status = match result {
            Ok(Ok(artifact)) => SupportBundleStatus::Ready {
                size_bytes: artifact.bytes.len() as u64,
                suggested_filename: artifact.suggested_filename,
            },
            Ok(Err(error)) => SupportBundleStatus::Error { code: error.code() },
            Err(_) => SupportBundleStatus::Error {
                code: wrenflow_runtime::support::SupportBundleFailureCode::StorageUnavailable,
            },
        };
        let _ = publish_support_status(&runtime_handle, status).await;
    }));
}

fn spawn_current_data_reset(async_runtime: &Runtime, runtime_handle: RuntimeHandle) {
    drop(async_runtime.spawn(async move {
        if wrenflow_runtime::recovery::schedule_current_data_reset().is_err() {
            report_diagnostic_failure(
                DiagnosticCategory::Lifecycle,
                DiagnosticCode::RecoveryStateWriteFailed,
            );
            return;
        }
        let _ = runtime_handle.request(RuntimeCommand::RequestQuit).await;
    }));
}

async fn publish_update_status(
    runtime_handle: &RuntimeHandle,
    status: UpdateStatus,
) -> Result<(), ()> {
    runtime_handle
        .request(RuntimeCommand::ReportUpdateStatus(status))
        .await
        .map(|_| ())
        .map_err(|_| {
            report_diagnostic_failure(
                DiagnosticCategory::Updates,
                DiagnosticCode::UpdateStatusPublishFailed,
            );
        })
}

async fn publish_support_status(
    runtime_handle: &RuntimeHandle,
    status: SupportBundleStatus,
) -> Result<(), ()> {
    runtime_handle
        .request(RuntimeCommand::ReportSupportBundleStatus(status))
        .await
        .map(|_| ())
        .map_err(|_| {
            report_diagnostic_failure(
                DiagnosticCategory::Lifecycle,
                DiagnosticCode::SupportBundleFailed,
            );
        })
}

fn update_error_status(error: UpdateError) -> UpdateStatus {
    report_diagnostic_failure(DiagnosticCategory::Updates, DiagnosticCode::UpdateFailed);
    if matches!(error.code, UpdateFailureCode::RecoveryRequired) {
        UpdateStatus::RecoveryRequired { code: error.code }
    } else if matches!(error.code, UpdateFailureCode::UnsupportedInstallation) {
        UpdateStatus::Unsupported
    } else {
        UpdateStatus::Error {
            code: error.code,
            retryable: error.retryable,
            retry_after_seconds: error.retry_after_seconds,
        }
    }
}

const fn support_update_state(status: &UpdateStatus) -> SupportUpdateState {
    match status {
        UpdateStatus::Unsupported | UpdateStatus::Idle | UpdateStatus::UpToDate { .. } => {
            SupportUpdateState::Idle
        }
        UpdateStatus::Checking { .. } => SupportUpdateState::Checking,
        UpdateStatus::Available { .. } => SupportUpdateState::Available,
        UpdateStatus::Downloading { .. } => SupportUpdateState::Downloading,
        UpdateStatus::ReadyToInstall { .. } => SupportUpdateState::ReadyToInstall,
        UpdateStatus::Installing { .. } => SupportUpdateState::Installing,
        UpdateStatus::RecoveryRequired { .. } => SupportUpdateState::RecoveryRequired,
        UpdateStatus::Error { .. } => SupportUpdateState::Failed,
    }
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
        | ShellEvent::AccessibilityAction(_)
        | ShellEvent::AccessibilityPreferencesChanged(_) => None,
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
        | ShellEvent::AccessibilityAction(_)
        | ShellEvent::AccessibilityPreferencesChanged(_) => None,
    };
    if let Some(command) = command {
        drop(async_runtime.spawn(async move {
            if runtime_handle.request(command).await.is_err() {
                report_diagnostic_failure(
                    DiagnosticCategory::Bridge,
                    DiagnosticCode::ShellCommandRejected,
                );
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
        if runtime_handle
            .request(RuntimeCommand::ReportShellCapabilities(capabilities))
            .await
            .is_err()
        {
            report_diagnostic_failure(
                DiagnosticCategory::Bridge,
                DiagnosticCode::ShellCapabilitiesPublishFailed,
            );
        }
    }));
}

const fn menu_bar_ready_code(tray_projection_ready: bool) -> Option<DiagnosticCode> {
    if tray_projection_ready {
        Some(DiagnosticCode::MenuBarReady)
    } else {
        None
    }
}

fn spawn_runtime_shell_adapter(
    async_runtime: &Runtime,
    runtime_handle: &RuntimeHandle,
    sender: mpsc::Sender<RuntimeShellUpdate>,
) {
    let _ = sender.send(RuntimeShellUpdate::Theme(
        runtime_handle.snapshot().settings.theme_preference,
    ));
    let mut snapshots = runtime_handle.subscribe_snapshots();
    let snapshot_handle = runtime_handle.clone();
    let snapshot_sender = sender.clone();
    drop(async_runtime.spawn(async move {
        while snapshots.changed().await.is_ok() {
            let snapshot = snapshots.borrow_and_update().clone();
            let _ = snapshot_sender.send(RuntimeShellUpdate::Tray(tray_presentation(
                &snapshot_handle,
            )));
            let _ = snapshot_sender.send(RuntimeShellUpdate::Theme(
                snapshot.settings.theme_preference,
            ));
            let update = match snapshot.pipeline.name() {
                "starting" | "initializing" => {
                    RuntimeShellUpdate::ShowOverlay(OverlayPhase::Initializing, 0.0)
                }
                "recording" => RuntimeShellUpdate::ShowOverlay(OverlayPhase::Recording, 0.0),
                "transcribing" => RuntimeShellUpdate::ShowOverlay(OverlayPhase::Transcribing, 0.0),
                _ => RuntimeShellUpdate::HideOverlay,
            };
            if snapshot_sender.send(update).is_err() {
                return;
            }
        }
    }));

    let mut audio_levels = runtime_handle.subscribe_audio_level();
    let audio_sender = sender.clone();
    drop(async_runtime.spawn(async move {
        while audio_levels.changed().await.is_ok() {
            if audio_sender
                .send(RuntimeShellUpdate::UpdateOverlayAudio(
                    *audio_levels.borrow_and_update(),
                ))
                .is_err()
            {
                return;
            }
        }
    }));

    let mut events = runtime_handle.subscribe_events();
    drop(async_runtime.spawn(async move {
        while let Ok(envelope) = events.recv().await {
            let update = match envelope.event {
                RuntimeEvent::PipelineError { message, action } => RuntimeShellUpdate::ShowError {
                    message,
                    action_label: action.as_ref().map(|action| action.label.clone()),
                    action_id: action.as_ref().map(|action| action.id.clone()),
                },
                RuntimeEvent::TranscriptReady { .. } => RuntimeShellUpdate::HideOverlay,
                RuntimeEvent::PasteCompleted => RuntimeShellUpdate::PasteCompleted,
                RuntimeEvent::QuitRequested => RuntimeShellUpdate::Terminate,
                RuntimeEvent::PlaySound(_) | RuntimeEvent::HistoryEntryAdded(_) => continue,
            };
            if sender.send(update).is_err() {
                return;
            }
        }
    }));
}

fn poll_runtime_shell_updates(
    cx: &mut App,
    receiver: mpsc::Receiver<RuntimeShellUpdate>,
    shell: MacShell,
    async_runtime: Arc<Runtime>,
    runtime_instance: Arc<Mutex<Option<RuntimeInstance>>>,
) {
    cx.spawn(async move |cx| loop {
        Timer::after(Duration::from_millis(16)).await;
        loop {
            let update = match receiver.try_recv() {
                Ok(update) => update,
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => return,
            };
            match update {
                RuntimeShellUpdate::Tray(presentation) => {
                    if shell.update_tray(&presentation).is_err() {
                        report_diagnostic_failure(
                            DiagnosticCategory::Bridge,
                            DiagnosticCode::TrayPublishFailed,
                        );
                    }
                }
                RuntimeShellUpdate::Theme(preference) => {
                    if shell.apply_theme_preference(preference).is_err() {
                        report_diagnostic_failure(
                            DiagnosticCategory::Bridge,
                            DiagnosticCode::SwiftShellFailure,
                        );
                    }
                }
                RuntimeShellUpdate::ShowOverlay(phase, audio_level) => {
                    shell.show_overlay(phase, audio_level);
                }
                RuntimeShellUpdate::UpdateOverlayAudio(level) => {
                    shell.update_overlay_audio(level);
                }
                RuntimeShellUpdate::HideOverlay => shell.hide_overlay(),
                RuntimeShellUpdate::PasteCompleted => {
                    shell.observe_performance_paste_dispatch();
                    shell.hide_overlay();
                }
                RuntimeShellUpdate::ShowError {
                    message,
                    action_label,
                    action_id,
                } => {
                    if shell
                        .show_error(&message, action_label.as_deref(), action_id.as_deref())
                        .is_err()
                    {
                        report_diagnostic_failure(
                            DiagnosticCategory::Bridge,
                            DiagnosticCode::ErrorToastPublishFailed,
                        );
                    }
                }
                RuntimeShellUpdate::Terminate => {
                    let instance = runtime_instance
                        .lock()
                        .ok()
                        .and_then(|mut instance| instance.take());
                    if let Some(instance) = instance {
                        match async_runtime.spawn(instance.shutdown()).await {
                            Ok(Ok(())) => {}
                            Ok(Err(_)) | Err(_) => report_diagnostic_failure(
                                DiagnosticCategory::Lifecycle,
                                DiagnosticCode::RuntimeShutdownFailed,
                            ),
                        }
                    }
                    let _ = cx.update(|_| shell.terminate());
                    return;
                }
            }
        }
    })
    .detach();
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
        accessibility_action, begin_update_operation, hotkey_keycode, menu_bar_ready_code,
        route_opens_automatically, shell_event_action, shell_event_opens_window, window_layout,
        AppAction, DiagnosticCode, NavigationTarget, RuntimeShellUpdate, ShellEvent, WindowLayout,
    };
    use wrenflow_gpui::ui::AccessibilityAction;

    #[test]
    fn updater_effects_are_single_flight() {
        let busy = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let Some(first) = begin_update_operation(&busy) else {
            panic!("first operation must start");
        };
        assert!(begin_update_operation(&busy).is_none());
        drop(first);
        assert!(begin_update_operation(&busy).is_some());
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

    #[test]
    fn window_policy_matches_flutter_geometry_without_leaking_into_screens() {
        assert_eq!(
            window_layout(NavigationTarget::Loading),
            WindowLayout::Compact
        );
        assert_eq!(
            window_layout(NavigationTarget::Onboarding),
            WindowLayout::Compact
        );
        assert_eq!(
            window_layout(NavigationTarget::PermissionRecovery),
            WindowLayout::Compact
        );
        assert_eq!(
            window_layout(NavigationTarget::Settings),
            WindowLayout::Settings
        );
        assert_eq!(
            window_layout(NavigationTarget::Models),
            WindowLayout::Settings
        );
        assert_eq!(
            window_layout(NavigationTarget::History),
            WindowLayout::Settings
        );
        assert_eq!(
            window_layout(NavigationTarget::About),
            WindowLayout::Settings
        );
        assert!(route_opens_automatically(NavigationTarget::Onboarding));
        assert!(route_opens_automatically(
            NavigationTarget::PermissionRecovery
        ));
        assert!(!route_opens_automatically(NavigationTarget::Settings));
    }

    #[test]
    fn runtime_shell_adapter_cannot_call_appkit_from_tokio() {
        fn assert_send<T: Send>() {}
        assert_send::<RuntimeShellUpdate>();

        let source = include_str!("main.rs");
        let Some((_, adapter_and_poll)) = source.split_once("fn spawn_runtime_shell_adapter")
        else {
            panic!("runtime shell adapter exists");
        };
        let Some((adapter, _)) = adapter_and_poll.split_once("fn poll_runtime_shell_updates")
        else {
            panic!("main-thread runtime shell poll exists");
        };
        assert!(adapter.contains("sender.send"));
        assert!(!adapter.contains("MacShell"));
        assert!(!adapter.contains("shell."));
    }

    #[test]
    fn appkit_restoration_cannot_order_a_gpui_window_during_launch() {
        let source = include_str!("main.rs");
        let Some((_, run)) = source.split_once("fn run(") else {
            panic!("run entry point exists");
        };
        let Some(prepare) = run.find("MacShell::prepare_process()") else {
            panic!("persistent UI opt-out runs");
        };
        let Some(claim) = run.find("MacShell::claim_single_instance()") else {
            panic!("single-instance guard runs");
        };
        let Some(application) = run.find("Application::new()") else {
            panic!("GPUI application is constructed");
        };
        assert!(prepare < claim && claim < application);

        let Some((_, launch_callback)) = source.split_once("application.run(move") else {
            panic!("GPUI launch callback exists");
        };
        let Some((did_finish_callback, _)) =
            launch_callback.split_once("let (shell, shell_events)")
        else {
            panic!("native shell install exists");
        };
        assert!(!did_finish_callback.contains("ensure_app_window"));

        let Some((_, window_policy)) = source.split_once("fn poll_window_policy") else {
            panic!("state-restoration-safe window policy exists");
        };
        let Some((delayed_window, _)) = window_policy.split_once("fn window_layout") else {
            panic!("window layout follows policy");
        };
        let Some(timer) = delayed_window.find("Timer::after") else {
            panic!("window creation yields past AppKit launch callback");
        };
        let Some(window) = delayed_window.find("ensure_app_window") else {
            panic!("window is created after yielding");
        };
        assert!(timer < window);

        let swift = include_str!("../macos/WrenflowShell.swift");
        assert!(swift.contains("ApplePersistenceIgnoreState"));
        assert!(swift.contains("window.isRestorable = false"));
        let plist = include_str!("../macos/Info.plist");
        assert!(plist.contains("NSQuitAlwaysKeepsWindows"));
    }

    #[test]
    fn menu_bar_readiness_requires_tray_and_complete_main_thread_wiring() {
        assert_eq!(menu_bar_ready_code(false), None);
        assert_eq!(
            menu_bar_ready_code(true),
            Some(DiagnosticCode::MenuBarReady)
        );

        let source = include_str!("main.rs");
        let Some((_, callback)) = source.split_once("application.run(move") else {
            panic!("GPUI launch callback exists");
        };
        let Some((callback, _)) = callback.split_once("fn ensure_app_window") else {
            panic!("window helper follows launch callback");
        };
        let Some(install) = callback.find("MacShell::install") else {
            panic!("native shell is installed");
        };
        let Some(tray) = callback.find("let tray_projection_ready") else {
            panic!("initial tray projection is checked");
        };
        let Some(runtime_poller) = callback.find("poll_runtime_shell_updates(") else {
            panic!("runtime shell poller is installed");
        };
        let Some(request_poller) = callback.find("poll_shell_requests(") else {
            panic!("shell request poller is installed");
        };
        let Some(event_poller) = callback.find("poll_shell_events(") else {
            panic!("shell event poller is installed");
        };
        let Some(accessibility_poller) = callback.find("poll_accessibility(") else {
            panic!("accessibility poller is installed");
        };
        let Some(quit) = callback.find("cx.on_app_quit") else {
            panic!("typed quit callback is installed");
        };
        let Some(ready) = callback.find("menu_bar_ready_code(tray_projection_ready)") else {
            panic!("menu bar readiness is emitted");
        };
        assert!(
            install < tray
                && tray < runtime_poller
                && runtime_poller < request_poller
                && request_poller < event_poller
                && event_poller < accessibility_poller
                && accessibility_poller < quit
                && quit < ready
        );
    }

    #[test]
    fn current_line_quit_cleans_runtime_before_appkit_termination() {
        let source = include_str!("main.rs");
        let Some((_, polling)) = source.split_once("fn poll_runtime_shell_updates") else {
            panic!("runtime shell polling exists");
        };
        let Some((polling, _)) = polling.split_once("fn tray_presentation") else {
            panic!("tray projection follows runtime shell polling");
        };
        let shutdown = polling.find("async_runtime.spawn(instance.shutdown()).await");
        let terminate = polling.find("shell.terminate()");
        assert!(shutdown.is_some(), "typed quit awaits runtime shutdown");
        assert!(
            terminate.is_some(),
            "AppKit termination follows runtime shutdown"
        );
        assert!(shutdown < terminate);

        let swift = include_str!("../macos/WrenflowShell.swift");
        assert!(swift.contains("makeSignalSource(signal: SIGUSR1"));
        assert!(swift.contains("Darwin.kill(existing.processIdentifier, SIGUSR1)"));
        assert!(swift.contains("existing.bundleURL?.resolvingSymlinksInPath().standardizedFileURL"));
        assert!(
            swift.contains("existing.executableURL?.resolvingSymlinksInPath().standardizedFileURL")
        );
        assert!(!swift.contains("Darwin.kill(running.processIdentifier, SIGTERM)"));
    }

    #[test]
    fn performance_self_test_is_two_gate_private_and_uses_normal_app_cleanup() {
        let main = include_str!("main.rs");
        let model = include_str!("app/model.rs");
        let actions = include_str!("app/action.rs");
        let shell = include_str!("shell.rs");
        let swift = include_str!("../macos/WrenflowShell.swift");
        let performance = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../core/wrenflow-runtime/src/performance.rs"
        ));
        let api = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../core/wrenflow-runtime/src/api.rs"
        ));

        let prepare = main.find("prepare_performance_self_test(&arguments)");
        let diagnostics = main.find("initialize_production_diagnostics()");
        assert!(prepare.is_some() && diagnostics.is_some() && prepare < diagnostics);
        let quit_callback = main.find("cx.on_app_quit");
        let launch = main.find("start_performance_self_test(request)");
        assert!(quit_callback.is_some() && launch.is_some() && quit_callback < launch);
        assert!(model.contains("run_performance_self_test(request).await"));
        assert!(model.contains("RuntimeCommand::RequestQuit"));
        assert!(main.contains("request.interaction_driver_paths()"));
        assert!(main.contains("AppAction::SetTranscriptDisposition(TranscriptDisposition::Paste)"));
        assert!(
            main.contains("start_performance_interaction(paths.ready_path(), paths.report_path())")
        );
        assert!(main.contains("RuntimeEvent::PasteCompleted => RuntimeShellUpdate::PasteCompleted"));
        assert!(main.contains("shell.observe_performance_paste_dispatch()"));
        assert!(shell.contains("wrenflow_shell_start_performance_interaction"));
        assert!(shell.contains("wrenflow_shell_observe_performance_paste_dispatch"));
        assert!(swift.contains("WrenflowPerformanceInteractionDriver"));
        assert!(swift.contains("classification: \"post_event_tap_synthetic\""));
        assert!(swift.contains("source: \"signed_wrenflow_typed_hotkey_callback\""));
        assert!(swift.contains("self?.handleHotkeyPressed()"));
        assert!(swift.contains("self?.handleHotkeyReleased(duration)"));
        assert!(!swift.contains("event.post(tap: .cghidEventTap)"));
        assert!(!swift.contains("CGEvent(keyboardEventSource:"));
        assert!(!swift.contains("Wrenflow Performance Target"));
        assert!(swift.contains("performanceInteraction?.observePasteDispatch()"));
        assert!(!actions.contains("PerformanceSelfTest"));
        assert!(!api.contains("PerformanceSelfTest"));
        assert!(performance.contains("WRENFLOW_PERFORMANCE_SELF_TEST"));
        assert!(performance.contains("WRENFLOW_PERFORMANCE_FIXTURE"));
        assert!(performance.contains("WRENFLOW_PERFORMANCE_DATA_ROOT"));
        assert!(performance.contains("WRENFLOW_PERFORMANCE_REPORT"));
    }

    #[test]
    fn native_visual_shell_tracks_system_appearance_and_active_display() {
        let main_source = include_str!("main.rs");
        assert!(main_source.contains("ThemeMode::for_window_appearance(cx.window_appearance())"));
        assert!(main_source.contains("appears_transparent: true"));

        let shell = include_str!("../macos/WrenflowShell.swift");
        assert!(shell.contains("accessibilityDisplayOptionsDidChangeNotification"));
        assert!(shell.contains("emitAccessibilityPreferences(force: true)"));

        let accessibility = include_str!("../macos/WrenflowAccessibilityBridge.swift");
        assert!(accessibility.contains("case \"slider\": return .slider"));
        assert!(accessibility.contains("case \"window\", \"dialog\": return .window"));
        assert!(accessibility.contains("case \"navigation\": return .list"));
        assert!(accessibility.contains("case \"dialog\": return .dialog"));
        assert!(accessibility.contains("setAccessibilityModal(snapshot.role == \"dialog\")"));

        let overlay = include_str!("../macos/WrenflowOverlayController.swift");
        assert!(!overlay.contains("NSScreen.main"));
        assert!(overlay.contains("NSEvent.mouseLocation"));
        assert!(overlay.contains("didChangeScreenParametersNotification"));
        assert!(overlay.contains("activeSpaceDidChangeNotification"));
        assert!(overlay.contains("screen.safeAreaInsets.top"));
        assert!(overlay.contains(".nonactivatingPanel"));
        assert!(overlay.contains("override var canBecomeKey: Bool { false }"));
        assert!(!overlay.contains("environment(\\.colorScheme, .light)"));
    }
}

use std::sync::Arc;
use dioxus::prelude::*;
use wrenflow_core::config::AppConfig;
use wrenflow_core::http_client;
use wrenflow_core::platform::{PlatformHost, PermissionStatus};

use crate::components::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StepId {
    Provider, ApiKey, MicPerm, Accessibility, ScreenRec, Hotkey, Vocab, LaunchLogin,
}

impl StepId {
    fn label(self) -> &'static str {
        match self {
            Self::Provider => "Transcription",
            Self::ApiKey => "API Key",
            Self::MicPerm => "Microphone Permission",
            Self::Accessibility => "Accessibility",
            Self::ScreenRec => "Screen Recording",
            Self::Hotkey => "Push-to-Talk Key",
            Self::Vocab => "Custom Vocabulary",
            Self::LaunchLogin => "Launch at Login",
        }
    }

    fn all(caps: &wrenflow_core::platform::PlatformCapabilities) -> Vec<StepId> {
        let mut s = vec![StepId::Provider, StepId::ApiKey];
        if caps.permissions {
            s.extend([StepId::MicPerm, StepId::Accessibility, StepId::ScreenRec]);
        }
        s.push(StepId::Hotkey);
        s.push(StepId::Vocab);
        if caps.launch_at_login { s.push(StepId::LaunchLogin); }
        s
    }
}

#[component]
pub fn SetupWizard(config: Signal<AppConfig>, api_key: Signal<String>, on_complete: EventHandler<()>) -> Element {
    let host = use_context::<Arc<dyn PlatformHost>>();
    let caps = host.capabilities();
    let steps = StepId::all(&caps);
    let total = steps.len();
    let mut active = use_signal(|| 0usize);
    let icon_url = crate::icon_data_url();

    rsx! {
        div { class: "max-w-lg mx-auto py-6 px-4",
            // Header
            div { class: "flex items-center gap-2 mb-5",
                img { class: "w-6 h-6 opacity-40", src: "{icon_url}", alt: "" }
                span { class: "text-sm font-semibold", "Wrenflow Setup" }
            }

            // Accordion steps
            div { class: "flex flex-col gap-1",
                for (i, &step) in steps.iter().enumerate() {
                    {
                        let idx = *active.read();
                        let done = i < idx;
                        let is_active = i == idx;
                        let num = format!("{}", i + 1);
                        let dot_cls = if done { "w-5 h-5 rounded-full bg-frost-700 text-white flex items-center justify-center text-[10px] shrink-0" }
                            else if is_active { "w-5 h-5 rounded-full bg-ash-900 text-white flex items-center justify-center text-[10px] font-semibold shrink-0" }
                            else { "w-5 h-5 rounded-full bg-ash-200 text-ash-500 flex items-center justify-center text-[10px] font-semibold shrink-0" };
                        let label_cls = if done { "text-xs text-ash-500" }
                            else if is_active { "text-xs font-medium text-ash-900" }
                            else { "text-xs text-ash-400" };
                        let dot_text = if done { "\u{2713}".to_string() } else { num };
                        let label_text = step.label().to_string();

                        rsx! {
                            div { class: "border border-ash-200 rounded overflow-hidden bg-white",
                                button {
                                    class: "w-full flex items-center gap-2 px-3 py-2 text-left",
                                    onclick: move |_| { if i <= idx { active.set(i); } },
                                    span { class: dot_cls, "{dot_text}" }
                                    span { class: label_cls, "{label_text}" }
                                }

                                // Body — only when active
                                if is_active {
                                    div { class: "px-3 pb-3 pt-1 border-t border-ash-100",
                                        match step {
                                            StepId::Provider => rsx! { ProviderBody { config } },
                                            StepId::ApiKey => rsx! { ApiKeyBody { config, api_key } },
                                            StepId::MicPerm => rsx! { PermBody { kind: "mic".to_string() } },
                                            StepId::Accessibility => rsx! { PermBody { kind: "ax".to_string() } },
                                            StepId::ScreenRec => rsx! { PermBody { kind: "sr".to_string() } },
                                            StepId::Hotkey => rsx! { HotkeyBody { config } },
                                            StepId::Vocab => rsx! { VocabBody { config } },
                                            StepId::LaunchLogin => rsx! { LaunchBody {} },
                                        }

                                        // Continue / Skip / Done
                                        div { class: "flex items-center gap-2 mt-3",
                                            if i + 1 < total {
                                                button {
                                                    class: "h-7 px-3 rounded text-[11px] font-medium bg-frost-700 text-white hover:opacity-90",
                                                    onclick: move |_| active.set(i + 1),
                                                    "Continue"
                                                }
                                                if matches!(step, StepId::ApiKey | StepId::Vocab | StepId::LaunchLogin) {
                                                    button {
                                                        class: "text-[11px] text-ash-500 hover:text-ash-700",
                                                        onclick: move |_| active.set(i + 1),
                                                        "Skip"
                                                    }
                                                }
                                            } else {
                                                button {
                                                    class: "h-7 px-3 rounded text-[11px] font-medium bg-frost-700 text-white hover:opacity-90",
                                                    onclick: move |_| on_complete.call(()),
                                                    "Done"
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// --- Step bodies ---

#[component]
fn ProviderBody(config: Signal<AppConfig>) -> Element {
    let p = config.read().transcription_provider.clone();
    rsx! {
        div { class: "flex flex-col gap-1.5",
            RadioOption { label: "Local (Parakeet)".to_string(), description: "On-device, ~500MB model.".to_string(),
                selected: p == "local", on_click: move |_| { config.write().transcription_provider = "local".to_string(); } }
            RadioOption { label: "Cloud (Groq)".to_string(), description: "Fast cloud API. Requires key.".to_string(),
                selected: p == "groq", on_click: move |_| { config.write().transcription_provider = "groq".to_string(); } }
        }
    }
}

#[component]
fn ApiKeyBody(config: Signal<AppConfig>, api_key: Signal<String>) -> Element {
    let mut key_input = use_signal(|| api_key.read().clone());
    let mut validating = use_signal(|| false);
    let mut result = use_signal(|| None::<bool>);
    let mut error = use_signal(|| None::<String>);
    rsx! {
        div { class: "flex flex-col gap-1.5",
            p { class: "text-[11px] text-ash-500", "For cloud transcription and post-processing." }
            div { class: "flex gap-1.5 items-center",
                input {
                    class: "flex-1 h-7 px-2 bg-mint-50 border border-ash-200 rounded text-xs font-mono outline-none focus:border-frost-700",
                    r#type: "password", placeholder: "gsk_...", value: "{key_input}",
                    disabled: *validating.read(),
                    oninput: move |e: Event<FormData>| { key_input.set(e.value()); result.set(None); error.set(None); },
                }
                button {
                    class: "h-7 px-2.5 rounded text-[11px] font-medium bg-frost-700 text-white hover:opacity-90 disabled:opacity-35",
                    disabled: key_input.read().trim().is_empty() || *validating.read(),
                    onclick: {
                        let base_url = config.read().api_base_url.clone();
                        move |_| {
                            let key = key_input.read().trim().to_string();
                            let url = base_url.clone();
                            validating.set(true); result.set(None); error.set(None);
                            spawn(async move {
                                match http_client::build_client() {
                                    Ok(c) => {
                                        let ok = http_client::validate_api_key(&c, &key, &url).await;
                                        validating.set(false);
                                        if ok { api_key.set(key); result.set(Some(true)); }
                                        else { error.set(Some("Invalid key.".to_string())); }
                                    }
                                    Err(e) => { validating.set(false); error.set(Some(format!("{e}"))); }
                                }
                            });
                        }
                    },
                    if *validating.read() { "..." } else { "Validate" }
                }
            }
            if let Some(true) = *result.read() { span { class: "text-[11px] text-frost-700", "\u{2713} Saved" } }
            if let Some(ref e) = *error.read() { span { class: "text-[11px] text-red-600", "\u{2717} {e}" } }
        }
    }
}

#[component]
fn PermBody(kind: String) -> Element {
    let host = use_context::<Arc<dyn PlatformHost>>();
    let k = kind.clone();
    let mut status = use_signal({
        let h = host.clone(); let k = k.clone();
        move || match k.as_str() {
            "mic" => h.get_microphone_permission(),
            "ax" => h.get_accessibility_permission(),
            _ => h.get_screen_recording_permission(),
        }
    });
    let hp = host.clone(); let kp = kind.clone();
    use_future(move || {
        let h = hp.clone(); let k = kp.clone();
        async move { loop {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            status.set(match k.as_str() {
                "mic" => h.get_microphone_permission(),
                "ax" => h.get_accessibility_permission(),
                _ => h.get_screen_recording_permission(),
            });
        }}
    });
    let granted = *status.read() == PermissionStatus::Granted;
    let hr = host.clone(); let kr = kind.clone();

    rsx! {
        if granted {
            span { class: "text-[11px] text-frost-700", "\u{2713} Granted" }
        } else {
            div { class: "flex items-center gap-2",
                p { class: "text-[11px] text-ash-500", "Required for Wrenflow to work." }
                button {
                    class: "h-6 px-2 rounded text-[11px] font-medium bg-frost-700 text-white hover:opacity-90",
                    onclick: move |_| match kr.as_str() {
                        "mic" => hr.request_microphone_permission(),
                        "ax" => hr.request_accessibility_permission(),
                        _ => hr.request_screen_recording_permission(),
                    },
                    "Grant"
                }
            }
        }
    }
}

#[component]
fn HotkeyBody(config: Signal<AppConfig>) -> Element {
    let sel = config.read().selected_hotkey.clone();
    rsx! {
        div { class: "flex flex-col gap-1",
            for &(val, label, desc) in super::settings::HOTKEY_OPTIONS {
                RadioOption { label: label.to_string(), description: desc.to_string(), selected: sel == val,
                    on_click: { let v = val.to_string(); move |_| { config.write().selected_hotkey = v.clone(); } } }
            }
        }
    }
}

#[component]
fn VocabBody(config: Signal<AppConfig>) -> Element {
    let v = config.read().custom_vocabulary.clone();
    rsx! {
        div { class: "flex flex-col gap-1.5",
            textarea {
                class: "w-full p-2 bg-mint-50 border border-ash-200 rounded text-xs font-mono leading-snug outline-none focus:border-frost-700 resize-y min-h-14",
                rows: "3", placeholder: "Wrenflow, Parakeet, gRPC", value: "{v}",
                oninput: move |e: Event<FormData>| { config.write().custom_vocabulary = e.value().trim().to_string(); },
            }
            p { class: "text-[11px] text-ash-500", "Comma or newline separated." }
        }
    }
}

#[component]
fn LaunchBody() -> Element {
    let host = use_context::<Arc<dyn PlatformHost>>();
    let mut enabled = use_signal(|| host.get_launch_at_login());
    let h = host.clone();
    rsx! {
        div { class: "flex items-center gap-2",
            label { class: "toggle",
                input { r#type: "checkbox", checked: *enabled.read(),
                    onchange: move |e: Event<FormData>| { let v = e.checked(); h.set_launch_at_login(v); enabled.set(v); } }
                span { class: "toggle-track" }
            }
            span { class: "text-xs", "Start Wrenflow at login" }
        }
    }
}

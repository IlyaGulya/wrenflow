mod components;
mod platform_cards;
mod prompts;
mod run_log;
mod settings;
mod setup;
mod theme;

use std::sync::Arc;
use dioxus::prelude::*;
use wrenflow_core::config::AppConfig;
use wrenflow_core::history::{HistoryEntry, HistoryStore};
use wrenflow_core::platform::{PlatformHost, StubPlatformHost};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tab { General, Prompts, RunLog }

impl Tab {
    fn label(self) -> &'static str {
        match self { Self::General => "General", Self::Prompts => "Prompts", Self::RunLog => "Run Log" }
    }
}

const TABS: [Tab; 3] = [Tab::General, Tab::Prompts, Tab::RunLog];

fn is_setup_mode() -> bool { std::env::args().any(|a| a == "--setup") }

fn config_path() -> PathBuf { AppConfig::default_path("Wrenflow") }

fn history_db_path() -> PathBuf {
    config_path().parent().unwrap().join("PipelineHistory.sqlite")
}

pub fn icon_data_url() -> String {
    format!("data:image/png;base64,{}", theme::ICON_BASE64.trim())
}

/// Global PlatformHost instance, set before launch.
static PLATFORM_HOST: std::sync::OnceLock<Arc<dyn PlatformHost>> = std::sync::OnceLock::new();

fn main() {
    env_logger::init();
    launch_ui(Arc::new(StubPlatformHost));
}

/// Entry point callable from native shells.
pub fn launch_ui(host: Arc<dyn PlatformHost>) {
    PLATFORM_HOST.set(host).ok();
    let setup = is_setup_mode();
    let window = if setup {
        dioxus::desktop::tao::window::WindowBuilder::new()
            .with_title("Wrenflow Setup")
            .with_inner_size(dioxus::desktop::tao::dpi::LogicalSize::new(480.0, 520.0))
            .with_resizable(false)
    } else {
        dioxus::desktop::tao::window::WindowBuilder::new()
            .with_title("Wrenflow Settings")
            .with_inner_size(dioxus::desktop::tao::dpi::LogicalSize::new(780.0, 560.0))
            .with_min_inner_size(dioxus::desktop::tao::dpi::LogicalSize::new(580.0, 380.0))
    };
    let cfg = dioxus::desktop::Config::new().with_window(window);
    dioxus::LaunchBuilder::desktop().with_cfg(cfg).launch(App);
}

#[component]
fn App() -> Element {
    // Provide PlatformHost to all descendants
    let host = PLATFORM_HOST.get().expect("PlatformHost not initialized").clone();
    use_context_provider(|| host);

    let config = use_signal(|| AppConfig::load_or_default(&config_path()));
    let api_key = use_signal(String::new);
    let mut history = use_signal(Vec::<HistoryEntry>::new);

    use_effect(move || {
        if let Ok(store) = HistoryStore::open(&history_db_path()) {
            if let Ok(entries) = store.load_all() { history.set(entries); }
        }
    });

    let setup_mode = is_setup_mode();
    let mut setup_done = use_signal(|| !setup_mode);

    if !*setup_done.read() {
        return rsx! {
            style { {theme::TAILWIND_CSS} }
            setup::SetupWizard {
                config, api_key,
                on_complete: move |_| {
                    let _ = config.read().save(&config_path());
                    // In setup mode, close the window. Otherwise show settings.
                    if is_setup_mode() {
                        std::process::exit(0);
                    }
                    setup_done.set(true);
                },
            }
        };
    }

    rsx! {
        style { {theme::TAILWIND_CSS} }
        SettingsApp { config, api_key, history }
    }
}

#[component]
fn SettingsApp(
    config: Signal<AppConfig>,
    api_key: Signal<String>,
    history: Signal<Vec<HistoryEntry>>,
) -> Element {
    let mut tab = use_signal(|| Tab::General);
    let icon_url = icon_data_url();

    rsx! {
        div { class: "flex h-screen bg-mint-50 text-ash-900 text-[13px] font-[Inter,-apple-system,system-ui,sans-serif] antialiased",
            div { class: "w-[180px] shrink-0 p-2 bg-mint-100 flex flex-col gap-px",
                div { class: "flex items-center gap-1.5 px-2 py-1.5 mb-2",
                    img { class: "w-4 h-4 opacity-45", src: "{icon_url}", alt: "Wrenflow" }
                    span { class: "text-[13px] font-semibold text-ash-800", "Wrenflow" }
                }
                for t in TABS {
                    button {
                        class: if *tab.read() == t {
                            "w-full text-left px-2.5 py-1 h-7 rounded text-xs font-medium bg-mint-200 text-ash-900 transition-colors"
                        } else {
                            "w-full text-left px-2.5 py-1 h-7 rounded text-xs font-medium text-ash-600 hover:bg-mint-200 hover:text-ash-800 transition-colors"
                        },
                        onclick: move |_| tab.set(t),
                        "{t.label()}"
                    }
                }
            }
            div { class: "flex-1 overflow-y-auto p-4 max-w-[600px]",
                match *tab.read() {
                    Tab::General => rsx! { settings::GeneralSettings { config, api_key } },
                    Tab::Prompts => rsx! { prompts::PromptsSettings { config, api_key } },
                    Tab::RunLog => rsx! {
                        run_log::RunLog {
                            history,
                            on_clear: move |_| {
                                if let Ok(store) = HistoryStore::open(&history_db_path()) {
                                    let _ = store.clear_all();
                                }
                                history.set(Vec::new());
                            },
                        }
                    },
                }
            }
        }
    }
}

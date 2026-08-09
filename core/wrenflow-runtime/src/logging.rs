//! Production logging and crash diagnostics shared by desktop shells.

use std::io::Write as _;
use std::sync::{Mutex, Once};

static INSTALL: Once = Once::new();
static LOGGER: DualLogger = DualLogger;
static LOG_FILE: Mutex<Option<std::fs::File>> = Mutex::new(None);

struct DualLogger;

impl log::Log for DualLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }

        let message = format!(
            "[RUST/{}] {} — {}",
            record.level(),
            record.target(),
            record.args()
        );
        eprintln!("{message}");
        with_log_file(|file| {
            let _ = writeln!(file, "{message}");
            let _ = file.flush();
        });
    }

    fn flush(&self) {
        with_log_file(|file| {
            let _ = file.flush();
        });
    }
}

/// Existing developer tooling tails this path, so the GPUI cutover preserves it.
const LOG_FILE_PATH: &str = "/tmp/wrenflow.log";

pub(crate) fn install() {
    INSTALL.call_once(|| {
        let level = std::env::var("RUST_LOG")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(log::LevelFilter::Info);

        let file = std::fs::File::create(LOG_FILE_PATH).ok();
        if let Ok(mut log_file) = LOG_FILE.lock() {
            *log_file = file;
        }

        let _ = log::set_logger(&LOGGER);
        log::set_max_level(level);
        install_panic_hook();
    });
}

fn with_log_file(callback: impl FnOnce(&mut std::fs::File)) {
    let Ok(mut log_file) = LOG_FILE.lock() else {
        return;
    };
    let Some(file) = log_file.as_mut() else {
        return;
    };
    callback(file);
}

fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let thread = std::thread::current();
        let thread_name = thread.name().unwrap_or("<unnamed>");
        let message = if let Some(message) = info.payload().downcast_ref::<&str>() {
            (*message).to_string()
        } else if let Some(message) = info.payload().downcast_ref::<String>() {
            message.clone()
        } else {
            "unknown panic".to_string()
        };
        let location = info
            .location()
            .map(|location| {
                format!(
                    "{}:{}:{}",
                    location.file(),
                    location.line(),
                    location.column()
                )
            })
            .unwrap_or_else(|| "unknown location".to_string());
        let crash = format!("RUST PANIC on thread '{thread_name}' at {location}: {message}");

        eprintln!("!!! {crash}");
        if let Err(error) = write_crash_log(&crash) {
            eprintln!("Failed to write crash log: {error}");
        }
    }));
}

fn write_crash_log(message: &str) -> std::io::Result<()> {
    let directory = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("wrenflow");
    std::fs::create_dir_all(&directory)?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(directory.join("crash.log"))?;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    writeln!(file, "[{timestamp}] {message}")
}

//! Logging infrastructure for the Rust hub.
//!
//! Dual output: stderr (for `flutter run`) + file at /tmp/wrenflow.log
//! (for `open wrenflow.app` where stderr goes to system log).

use std::io::Write;
use std::sync::Mutex;

static LOGGER: DualLogger = DualLogger;
static LOG_FILE: Mutex<Option<std::fs::File>> = Mutex::new(None);

struct DualLogger;

impl log::Log for DualLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            let msg = format!(
                "[RUST/{}] {} — {}",
                record.level(),
                record.target(),
                record.args()
            );
            eprintln!("{msg}");
            if let Ok(mut guard) = LOG_FILE.lock() {
                if let Some(ref mut f) = *guard {
                    let _ = writeln!(f, "{msg}");
                    let _ = f.flush();
                }
            }
        }
    }

    fn flush(&self) {
        if let Ok(mut guard) = LOG_FILE.lock() {
            if let Some(ref mut f) = *guard {
                let _ = f.flush();
            }
        }
    }
}

/// Log file path — readable by `mise run logs` or `tail -f`.
pub const LOG_FILE_PATH: &str = "/tmp/wrenflow.log";

/// Initialize logging. Call once at hub startup.
pub fn init_logging() {
    let level = std::env::var("RUST_LOG")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(log::LevelFilter::Info);

    // Open log file (truncate on each launch for fresh logs).
    if let Ok(file) = std::fs::File::create(LOG_FILE_PATH) {
        if let Ok(mut guard) = LOG_FILE.lock() {
            *guard = Some(file);
        }
    }

    let _ = log::set_logger(&LOGGER);
    log::set_max_level(level);
}

/// Install a global panic hook that logs via eprintln + writes crash file.
pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let thread = std::thread::current();
        let thread_name = thread.name().unwrap_or("<unnamed>");

        let message = if let Some(s) = info.payload().downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".to_string()
        };

        let location = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "unknown location".to_string());

        let log_msg = format!(
            "RUST PANIC on thread '{thread_name}' at {location}: {message}"
        );

        // Print to stderr (captured by flutter run if eprintln works)
        eprintln!("!!! {log_msg}");

        // Also write to crash log file
        if let Err(e) = write_crash_log(&log_msg) {
            eprintln!("Failed to write crash log: {e}");
        }
    }));
}

fn write_crash_log(message: &str) -> std::io::Result<()> {
    use std::io::Write;

    let dir = dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("wrenflow");
    std::fs::create_dir_all(&dir)?;

    let path = dir.join("crash.log");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;

    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    writeln!(file, "[{timestamp}] {message}")?;
    Ok(())
}

/// Convert a panic payload to a human-readable string.
pub fn panic_payload_to_string(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic payload".to_string()
    }
}

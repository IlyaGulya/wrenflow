//! `log` compatibility and privacy-safe panic capture.

use std::sync::Once;

static INSTALL: Once = Once::new();
static LOGGER: StructuredLogger = StructuredLogger;

struct StructuredLogger;

impl log::Log for StructuredLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            crate::diagnostics::emit_legacy_record(record);
        }
    }

    fn flush(&self) {}
}

pub(crate) fn install() {
    INSTALL.call_once(|| {
        crate::diagnostics::initialize();
        let level = configured_level();
        if log::set_logger(&LOGGER).is_ok() {
            log::set_max_level(level);
        }
        install_panic_hook();
    });
}

fn configured_level() -> log::LevelFilter {
    if cfg!(debug_assertions) {
        std::env::var("RUST_LOG")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(log::LevelFilter::Debug)
    } else {
        // Production binaries keep trace/debug out regardless of their launch
        // environment. Their free-form arguments are never persisted anyway.
        log::LevelFilter::Info
    }
}

fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        crate::diagnostics::capture_panic(info);
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_policy_never_exceeds_info() {
        if !cfg!(debug_assertions) {
            assert_eq!(configured_level(), log::LevelFilter::Info);
        }
    }
}

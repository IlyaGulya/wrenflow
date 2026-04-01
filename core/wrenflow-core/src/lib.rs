// Re-export domain types
pub use wrenflow_domain::config;
pub use wrenflow_domain::pipeline;
pub use wrenflow_domain::history;
pub use wrenflow_domain::metrics;
pub use wrenflow_domain::platform;
pub use wrenflow_domain::audio;
pub use wrenflow_domain::transcription;
pub use wrenflow_domain::model_management;

// Audio capture (cpal-based) — internal Mutex locks are safe to unwrap
#[allow(clippy::unwrap_used)]
pub mod audio_capture;

// Audio encoding
pub mod opus_encoder;

// Persistence
pub mod config_store;
pub mod history_store;

// Local transcription (Parakeet)
pub mod model_downloader;
pub mod transcription_local;

// Convenience re-exports
pub use config_store::{ConfigStore, ConfigError, default_config_path};
pub use history_store::{HistoryStore, HistoryError};

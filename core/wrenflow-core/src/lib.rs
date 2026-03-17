// Re-export domain types for backward compatibility
pub use wrenflow_domain::config;
pub use wrenflow_domain::pipeline;
pub use wrenflow_domain::history;
pub use wrenflow_domain::metrics;
pub use wrenflow_domain::platform;
pub use wrenflow_domain::audio;
pub use wrenflow_domain::transcription;
pub use wrenflow_domain::post_processing;
pub use wrenflow_domain::models;

// Infrastructure modules (IO, network, persistence)
pub mod http_client;
pub mod config_store;
pub mod history_store;
pub mod models_infra;
pub mod post_processing_infra;
pub mod transcription_cloud;
pub mod transcription_local;

// Convenience re-exports for backward compatibility
pub use config_store::{ConfigStore, ConfigError, default_config_path};
pub use history_store::{HistoryStore, HistoryError};

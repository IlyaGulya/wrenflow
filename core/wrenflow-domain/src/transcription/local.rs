//! Local transcription — domain types only (no parakeet-rs dependency).

/// Model loading state (pure domain type, no IO).
#[derive(Debug, Clone, PartialEq)]
pub enum ModelState {
    NotLoaded,
    Downloading,
    Compiling,
    Ready,
    Error(String),
}

impl ModelState {
    pub fn is_ready(&self) -> bool {
        matches!(self, Self::Ready)
    }

    pub fn is_loading(&self) -> bool {
        matches!(self, Self::Downloading | Self::Compiling)
    }
}

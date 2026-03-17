//! Pipeline metrics — flexible key-value store per pipeline run.
//! Mirrors Swift's `PipelineMetrics` / `MetricValue` exactly.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A single metric value — bool must come before int in serde order
/// to match Swift's `Codable` decode priority (Bool → Int → Double → String).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum MetricValue {
    Bool(bool),
    Int(i64),
    Double(f64),
    String(String),
}

impl MetricValue {
    pub fn display_value(&self) -> String {
        match self {
            MetricValue::Double(v) => {
                if *v >= 1000.0 {
                    format!("{:.1}s", v / 1000.0)
                } else {
                    format!("{:.1}ms", v)
                }
            }
            MetricValue::Int(v) => v.to_string(),
            MetricValue::String(v) => v.clone(),
            MetricValue::Bool(v) => if *v { "true" } else { "false" }.to_string(),
        }
    }
}

/// Flexible key→value map for pipeline run metrics.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PipelineMetrics {
    #[serde(flatten)]
    storage: BTreeMap<String, MetricValue>,
}

impl PipelineMetrics {
    pub fn new() -> Self {
        Self::default()
    }

    // Setters
    pub fn set_double(&mut self, key: &str, value: f64) {
        self.storage.insert(key.to_string(), MetricValue::Double(value));
    }

    pub fn set_int(&mut self, key: &str, value: i64) {
        self.storage.insert(key.to_string(), MetricValue::Int(value));
    }

    pub fn set_string(&mut self, key: &str, value: String) {
        self.storage.insert(key.to_string(), MetricValue::String(value));
    }

    pub fn set_bool(&mut self, key: &str, value: bool) {
        self.storage.insert(key.to_string(), MetricValue::Bool(value));
    }

    // Getters
    pub fn get_double(&self, key: &str) -> Option<f64> {
        match self.storage.get(key) {
            Some(MetricValue::Double(v)) => Some(*v),
            _ => None,
        }
    }

    pub fn get_int(&self, key: &str) -> Option<i64> {
        match self.storage.get(key) {
            Some(MetricValue::Int(v)) => Some(*v),
            _ => None,
        }
    }

    pub fn get_string(&self, key: &str) -> Option<&str> {
        match self.storage.get(key) {
            Some(MetricValue::String(v)) => Some(v.as_str()),
            _ => None,
        }
    }

    pub fn get_bool(&self, key: &str) -> Option<bool> {
        match self.storage.get(key) {
            Some(MetricValue::Bool(v)) => Some(*v),
            _ => None,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.storage.is_empty()
    }

    pub fn all_keys(&self) -> Vec<String> {
        self.storage.keys().cloned().collect()
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(&self.storage).unwrap_or_default()
    }

    pub fn from_json(json: &str) -> Self {
        let storage: BTreeMap<String, MetricValue> =
            serde_json::from_str(json).unwrap_or_default();
        Self { storage }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_json() {
        let mut m = PipelineMetrics::new();
        m.set_double("transcription.durationMs", 200.5);
        m.set_int("recording.fileSizeBytes", 48000);
        m.set_string("transcription.provider", "local".to_string());
        m.set_bool("postProcessing.enabled", false);

        let json = m.to_json();
        let loaded = PipelineMetrics::from_json(&json);
        assert_eq!(loaded.get_double("transcription.durationMs"), Some(200.5));
        assert_eq!(loaded.get_int("recording.fileSizeBytes"), Some(48000));
        assert_eq!(loaded.get_string("transcription.provider"), Some("local"));
        assert_eq!(loaded.get_bool("postProcessing.enabled"), Some(false));
    }

    #[test]
    fn display_value_formatting() {
        assert_eq!(MetricValue::Double(200.5).display_value(), "200.5ms");
        assert_eq!(MetricValue::Double(1500.0).display_value(), "1.5s");
        assert_eq!(MetricValue::Int(42).display_value(), "42");
        assert_eq!(MetricValue::Bool(true).display_value(), "true");
        assert_eq!(MetricValue::String("local".into()).display_value(), "local");
    }

    #[test]
    fn empty_metrics() {
        let m = PipelineMetrics::new();
        assert!(m.is_empty());
        assert_eq!(m.all_keys().len(), 0);
    }
}

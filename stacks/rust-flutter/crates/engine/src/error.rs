//! Model errors (SPEC 4.6). Each variant of failure carries the spec's error code.

use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub struct ModelError {
    pub code: &'static str,
    pub detail: String,
}

impl ModelError {
    pub fn new(code: &'static str, detail: impl Into<String>) -> Self {
        ModelError { code, detail: detail.into() }
    }

    /// The `{"error": .., "detail": ..}` body used by the CLI and the server.
    pub fn to_json(&self) -> String {
        serde_json::json!({ "error": self.code, "detail": self.detail }).to_string()
    }
}

impl fmt::Display for ModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.detail)
    }
}

impl std::error::Error for ModelError {}

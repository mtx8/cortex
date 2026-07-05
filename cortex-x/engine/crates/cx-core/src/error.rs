use thiserror::Error;

#[derive(Debug, Error)]
pub enum CxError {
    #[error("config error: {0}")]
    Config(String),
    #[error("feed error: {0}")]
    Feed(String),
    #[error("risk rejection: {0}")]
    Risk(String),
    #[error("order error: {0}")]
    Order(String),
    #[error("egress blocked: {0}")]
    EgressBlocked(String),
    #[error("egress failed: {0}")]
    EgressFailed(String),
    #[error("ai provider error: {0}")]
    Ai(String),
    #[error("serialization error: {0}")]
    Serde(String),
    #[error("io error: {0}")]
    Io(String),
}

impl From<serde_json::Error> for CxError {
    fn from(e: serde_json::Error) -> Self {
        CxError::Serde(e.to_string())
    }
}

impl From<std::io::Error> for CxError {
    fn from(e: std::io::Error) -> Self {
        CxError::Io(e.to_string())
    }
}

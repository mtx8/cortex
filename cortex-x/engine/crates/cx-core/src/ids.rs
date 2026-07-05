//! Process-unique id generation. Order ids are monotonic u64s; request ids
//! are timestamp-prefixed strings safe to expose to clients.

use std::sync::atomic::{AtomicU64, Ordering};

use crate::time::now_ms;

static NEXT_ORDER_ID: AtomicU64 = AtomicU64::new(1);

pub fn next_order_id() -> u64 {
    NEXT_ORDER_ID.fetch_add(1, Ordering::Relaxed)
}

static NEXT_SEQ: AtomicU64 = AtomicU64::new(1);

/// e.g. "cx-1719412345678-42"
pub fn next_request_id(prefix: &str) -> String {
    let seq = NEXT_SEQ.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}-{}-{seq}", now_ms())
}

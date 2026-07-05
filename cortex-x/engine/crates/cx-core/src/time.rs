//! Wall-clock helpers. All engine timestamps are unix milliseconds (i64).

use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Align a timestamp down to the start of its bucket.
pub fn bucket_start(ts_ms: i64, bucket_ms: i64) -> i64 {
    if bucket_ms <= 0 {
        return ts_ms;
    }
    ts_ms - ts_ms.rem_euclid(bucket_ms)
}

/// Milliseconds since local midnight UTC — used by daily clocks.
pub fn ms_into_utc_day(ts_ms: i64) -> i64 {
    ts_ms.rem_euclid(86_400_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_alignment() {
        assert_eq!(bucket_start(61_500, 60_000), 60_000);
        assert_eq!(bucket_start(60_000, 60_000), 60_000);
        assert_eq!(bucket_start(59_999, 60_000), 0);
    }
}

//! Equity feed: CBOE delayed quotes (keyless, ~15 min delayed) polled on a
//! slow cadence, plus Yahoo chart backfill. Intraday (H1/M5) backfill asks
//! for extended-hours bars (`includePrePost=true`) so pre/post-market
//! action lands in the store — bars carry their real timestamps, nothing
//! is re-marked or filtered as RTH-only. Delayed data is honest data: the
//! feed advertises itself as Degraded (never Live) so downstream consumers
//! and the operator can see exactly what they are trading on.
//!
//! Honest data also means honest CLOCKS and honest SIZES. Every tick this
//! poller emits is stamped with the quote's own `last_trade_time`, not with
//! wall-clock arrival, and carries the per-poll delta of the venue's cumulative
//! session volume as its size. Both feed `agg`, which buckets bars and gates
//! the daily session bar on `Tick::ts_ms`, and whose bars land in the same
//! [`BarStore`] series as the Yahoo backfill above.
//!
//! LEVEL 2 depth for equities: there is NO real order book here. Equities
//! carry only CBOE ~15-min-DELAYED top-of-book (L1) today. For the actively-
//! viewed equity symbol this feed therefore publishes a MINIMAL, honest
//! [`BookDepth`] with `is_live = false` and `source = "cboe delayed L1 (no
//! depth)"` — a single delayed level per side so the UI shows something true
//! rather than pretending crypto-style live L2. Real equity L2 (and a real
//! tape) arrives via IBKR (`reqMktDepth` / `reqTickByTick`) once the operator
//! connects IB Gateway with their market-data subscriptions, through the
//! integration point [`publish_ibkr_depth`] / [`publish_ibkr_tape`] at the
//! bottom of this file. This poller NEVER fabricates real-time equity depth or
//! aggressor-tagged prints.
//!
//! PRECEDENCE, because both publishers target the same actively-viewed symbol:
//! LIVE WINS. A live book claims the ladder for `LIVE_DEPTH_TTL_MS` and the
//! delayed stand-in below stays quiet for that symbol; when the live feed stops
//! (no entitlement, Gateway closed, session lost) the claim lapses and the
//! delayed book resumes. Unguarded, the operator would watch a real 20-row
//! ladder blink to one delayed level every poll.

use std::sync::Arc;
use std::time::Duration;

use cx_core::egress::Egress;
use cx_core::events::{
    Bar, BookDepth, BookLevel, BookTop, EngineEvent, FeedHealth, FeedStatus, TapePrint, Tick,
};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Interval, Venue};
use cx_core::Bus;
use tokio::sync::watch;

const POLL_SECS: u64 = 20;
const FEED_NAME: &str = "cboe-equities";
/// Nominal age of a CBOE delayed quote, used ONLY as the fallback stamp when
/// `last_trade_time` cannot be parsed. Stamping a ~15-minute-old quote with the
/// wall clock shifted every live equity bar 15 minutes late and broke the daily
/// session bar at both ends: at 09:30 ET the quote in hand still reflects
/// pre-open, yet `us_rth(now)` accepted it as today's official OPEN, and from
/// 16:00–16:15 ET the quotes carrying the closing auction were rejected as
/// extended hours, leaving the session CLOSE at the ~15:45 print. Both the bar
/// bucketing and the equity D1 session gate in `agg` read `Tick::ts_ms`.
const FEED_DELAY_MS: i64 = 15 * 60_000;
/// Honest provenance label carried on every equity [`BookDepth`]: delayed L1
/// with no real order-book depth.
const EQUITY_DEPTH_SOURCE: &str = "cboe delayed L1 (no depth)";

fn quote_url(symbol: &str) -> String {
    format!("https://cdn.cboe.com/api/global/delayed_quotes/quotes/{symbol}.json")
}

/// Yahoo v8 chart backfill URL. Intraday requests (`pre_post`) include
/// extended-hours bars — the daily range never asks (D1 rows are official
/// RTH sessions; the flag is meaningless there).
fn chart_url(symbol: &str, range: &str, gran: &str, pre_post: bool) -> String {
    let extra = if pre_post { "&includePrePost=true" } else { "" };
    format!(
        "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range={range}&interval={gran}{extra}"
    )
}

/// Parsed subset of the CBOE quote payload.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct EquityQuote {
    pub price: f64,
    pub bid: f64,
    pub ask: f64,
    pub bid_size: f64,
    pub ask_size: f64,
    pub volume: f64,
    pub last_trade_time: String,
}

pub(crate) fn parse_quote(raw: &str) -> Option<EquityQuote> {
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    let d = v.get("data")?;
    let f = |k: &str| d.get(k).and_then(|x| x.as_f64()).unwrap_or(f64::NAN);
    let q = EquityQuote {
        price: f("current_price"),
        bid: f("bid"),
        ask: f("ask"),
        bid_size: f("bid_size"),
        ask_size: f("ask_size"),
        volume: f("volume"),
        last_trade_time: d
            .get("last_trade_time")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string(),
    };
    (q.price.is_finite() && q.price > 0.0).then_some(q)
}

/// CBOE stamps `last_trade_time` as a ZONELESS local US/Eastern instant
/// ("2026-07-02T16:00:00"). Resolve it to epoch ms so bars are bucketed — and
/// the equity D1 RTH gate judged — on the instant the trade actually printed
/// rather than on when this poller happened to see it.
///
/// Returns `None` when the field is missing, unparseable, or lands implausibly
/// far from `now`: a feed that is 15 minutes BEHIND us can never be ahead of
/// us, and a stamp days off means the format changed under us. Callers fall
/// back to `now - FEED_DELAY_MS` rather than trusting a guess — never to `now`.
pub(crate) fn parse_trade_time_ms(raw: &str, now: i64) -> Option<i64> {
    use chrono::{DateTime, NaiveDateTime};
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    // An explicit offset (not what CBOE sends today, but cheap to honour if it
    // ever appears) is authoritative and needs no zone guessing.
    let ts = if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        dt.timestamp_millis()
    } else {
        const FORMATS: [&str; 4] = [
            "%Y-%m-%dT%H:%M:%S%.f",
            "%Y-%m-%d %H:%M:%S%.f",
            "%Y-%m-%dT%H:%M",
            "%Y-%m-%d %H:%M",
        ];
        let naive = FORMATS
            .iter()
            .find_map(|f| NaiveDateTime::parse_from_str(s, f).ok())?;
        let naive_ms = naive.and_utc().timestamp_millis();
        // Resolve US/Eastern by testing the EDT reading against the DST window;
        // outside it the stamp is EST. The single ambiguous hour is the 02:00
        // autumn fold, which is never a trading instant.
        let edt = naive_ms + 4 * 3_600_000;
        if crate::agg::is_us_eastern_dst(edt) {
            edt
        } else {
            naive_ms + 5 * 3_600_000
        }
    };
    (ts > now - 7 * 86_400_000 && ts <= now + 60_000).then_some(ts)
}

/// Per-poll traded volume from CBOE's CUMULATIVE session `volume` field.
///
/// The cumulative number was parsed and then used only for change detection, so
/// every tick was published with `size: 0.0` and every live-formed equity bar
/// carried volume exactly 0 — the chart's volume pane skips zero-volume bars, so
/// the live tail read as "no trading" while the crosshair printed a
/// measured-looking "v 0.00". The delta is floored at 0 so the session rollover
/// (cumulative resets to near zero) cannot emit a negative size, and is 0 on the
/// first poll of a symbol, which has no baseline to difference against. NaN
/// inputs yield 0 (`f64::max` returns the non-NaN operand).
fn traded_delta(prev_cumulative: Option<f64>, cumulative: f64) -> f64 {
    match prev_cumulative {
        Some(prev) => (cumulative - prev).max(0.0),
        None => 0.0,
    }
}

/// Yahoo v8 chart JSON -> bars. Null slots (halts, partial rows) are skipped;
/// a malformed payload yields an empty vec, never a panic. `now` is the wall
/// clock (injected for tests) and decides which trailing row is still forming.
pub(crate) fn parse_yahoo_chart(
    symbol: &str,
    interval: Interval,
    raw: &str,
    max: usize,
    now: i64,
) -> Vec<Bar> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    let Some(result) = v
        .get("chart")
        .and_then(|c| c.get("result"))
        .and_then(|r| r.get(0))
    else {
        return Vec::new();
    };
    let Some(ts) = result.get("timestamp").and_then(|t| t.as_array()) else {
        return Vec::new();
    };
    let Some(quote) = result
        .get("indicators")
        .and_then(|i| i.get("quote"))
        .and_then(|q| q.get(0))
    else {
        return Vec::new();
    };
    let series = |k: &str| quote.get(k).and_then(|a| a.as_array());
    let (Some(open), Some(high), Some(low), Some(close), Some(volume)) = (
        series("open"),
        series("high"),
        series("low"),
        series("close"),
        series("volume"),
    ) else {
        return Vec::new();
    };

    // Yahoo returns the still-forming bucket as its last row. Stamping it
    // `complete: true` walked a partial session straight through the very gates
    // that exist to exclude forming bars (`scanner::read_bars`,
    // `regimes::classify`): days_in_state reset, vol_surge divided a half-day
    // volume by 20 full-day averages, and "new 52w high" could flag off a
    // mid-session print. The row is kept — the chart draws a forming bar
    // distinctly, and the live aggregator folds it in as a bucket seed — but it
    // is labelled honestly. Same grid as live aggregation by construction:
    // `agg::bar_bucket` is the one definition of the bucket grid.
    let forming_bucket = crate::agg::bar_bucket(symbol, interval, now);
    let mut bars: Vec<Bar> = Vec::new();
    for i in 0..ts.len() {
        let (Some(t), Some(o), Some(h), Some(l), Some(c)) = (
            ts.get(i).and_then(|x| x.as_i64()),
            open.get(i).and_then(|x| x.as_f64()),
            high.get(i).and_then(|x| x.as_f64()),
            low.get(i).and_then(|x| x.as_f64()),
            close.get(i).and_then(|x| x.as_f64()),
        ) else {
            continue;
        };
        if ![o, h, l, c].iter().all(|x| x.is_finite() && *x > 0.0) || h < l {
            continue;
        }
        // D1 rows stay UTC-midnight-bucketed (utcDayKey + the live
        // aggregator's daily dedupe key on them). Intraday bars keep
        // Yahoo's true opens: RTH hourlies are 09:30-anchored, so flooring
        // would alias the 09:30 RTH bar into the 09:00 pre-market bucket —
        // destroying the pre-market bar in the store and mis-shading the
        // first regular hour as extended on every equity H1 chart.
        let ts_open_ms = if interval == Interval::D1 {
            cx_core::time::bucket_start(t * 1000, interval.ms())
        } else {
            t * 1000
        };
        bars.push(Bar {
            symbol: symbol.to_string(),
            interval,
            ts_open_ms,
            open: o,
            high: h,
            low: l,
            close: c,
            volume: volume.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0),
            // 0 marks this as a VENUE bar: `agg::is_venue_bar` reads it to tell
            // a backfill row apart from an aggregator-built bar, so it must
            // stay 0 here.
            trade_count: 0,
            vwap: c,
            complete: ts_open_ms < forming_bucket,
        });
    }
    let start = bars.len().saturating_sub(max);
    bars.split_off(start)
}

/// Poll loop for all configured equity symbols. Publishes ticks/tops on real
/// quote changes only (a closed market produces silence, not fake prints).
pub(crate) async fn run(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    symbols: Vec<String>,
    tick_tx: tokio::sync::mpsc::Sender<Tick>,
    backfill_bars: u32,
    mut depth_rx: watch::Receiver<Option<String>>,
) {
    if symbols.is_empty() {
        return;
    }
    let egress = Egress::new();

    // History first, so charts and analytics have context immediately:
    // five years of dailies, three months of hourlies, five days of
    // 5-minute bars. Intraday ranges include extended-hours bars.
    const RANGES: [(Interval, &str, &str, bool); 3] = [
        (Interval::D1, "5y", "1d", false),
        (Interval::H1, "3mo", "1h", true),
        (Interval::M5, "5d", "5m", true),
    ];
    for symbol in &symbols {
        for (interval, range, gran, pre_post) in RANGES {
            let url = chart_url(symbol, range, gran, pre_post);
            match egress.get_text(&url).await {
                Ok(raw) => {
                    let bars =
                        parse_yahoo_chart(symbol, interval, &raw, backfill_bars as usize, now_ms());
                    let n = bars.len();
                    for bar in bars {
                        store.push(bar);
                    }
                    tracing::info!(symbol = %symbol, interval = interval.label(), bars = n, "equity backfill");
                }
                Err(e) => {
                    tracing::warn!(symbol = %symbol, interval = interval.label(), error = %e, "equity backfill failed")
                }
            }
            tokio::time::sleep(Duration::from_millis(400)).await;
        }
    }

    bus.publish(EngineEvent::FeedStatus(FeedStatus {
        feed: FEED_NAME.into(),
        health: FeedHealth::Degraded,
        detail: "cboe delayed quotes (~15m), polled".into(),
        ts_ms: now_ms(),
    }));

    let mut last_seen: std::collections::HashMap<String, EquityQuote> =
        std::collections::HashMap::new();
    let mut consecutive_failures = 0u32;
    // Whether the last published health for this feed was `Down`. Without it
    // the status LATCHES: the loop announced Down after a failure streak and
    // never announced anything again, so a recovered feed kept reading "down"
    // in the chart header and the empty-chart panel indefinitely — telling the
    // operator the wrong reason for missing data. (Observed live: "down" with a
    // two-day-old timestamp while the endpoint served HTTP 200.)
    let mut published_down = false;
    loop {
        for symbol in &symbols {
            match egress.get_text(&quote_url(symbol)).await {
                Ok(raw) => {
                    consecutive_failures = 0;
                    // Recovery is as newsworthy as the failure. Republish the
                    // steady-state health so the UI stops blaming a dead feed.
                    if published_down {
                        published_down = false;
                        bus.publish(EngineEvent::FeedStatus(FeedStatus {
                            feed: FEED_NAME.into(),
                            health: FeedHealth::Degraded,
                            detail: "cboe delayed quotes (~15m), polled — recovered".into(),
                            ts_ms: now_ms(),
                        }));
                    }
                    let Some(q) = parse_quote(&raw) else { continue };
                    let changed = last_seen.get(symbol) != Some(&q);
                    if !changed {
                        continue;
                    }
                    let ts = now_ms();
                    // Difference the CUMULATIVE session volume against the
                    // previous poll BEFORE overwriting the baseline.
                    let traded = traded_delta(last_seen.get(symbol).map(|p| p.volume), q.volume);
                    // The quote's OWN trade time, never the wall clock: this
                    // feed is ~15 minutes behind the tape and `Tick::ts_ms` is
                    // what decides the bar bucket and whether the print counts
                    // as regular-hours for the daily session bar.
                    let trade_ts = parse_trade_time_ms(&q.last_trade_time, ts)
                        .unwrap_or_else(|| ts.saturating_sub(FEED_DELAY_MS));
                    last_seen.insert(symbol.clone(), q.clone());
                    store.set_last_price_from(symbol, q.price, Venue::Cboe);
                    let tick = Tick {
                        symbol: symbol.clone(),
                        ts_ms: trade_ts,
                        price: q.price,
                        size: traded,
                        aggressor: None,
                        venue: Venue::Cboe,
                    };
                    bus.publish(EngineEvent::Tick(tick.clone()));
                    let _ = tick_tx.send(tick).await;
                    if q.bid.is_finite() && q.ask.is_finite() && q.bid > 0.0 && q.ask >= q.bid {
                        bus.publish(EngineEvent::BookTop(BookTop {
                            symbol: symbol.clone(),
                            ts_ms: ts,
                            bid_px: q.bid,
                            bid_sz: q.bid_size.max(0.0),
                            ask_px: q.ask,
                            ask_sz: q.ask_size.max(0.0),
                        }));
                    }
                    // Honest DELAYED L1 "depth" for the actively-viewed symbol
                    // only (bandwidth bound): a single delayed level per side,
                    // is_live=false. Never fabricated as live L2.
                    //
                    // ...and only while no LIVE IBKR ladder owns this symbol.
                    // Live depth wins: publishing here underneath a real 20-row
                    // book would replace it with one delayed level every poll.
                    if depth_rx.borrow().as_deref() == Some(symbol.as_str())
                        && !live_depth_owns(symbol, ts)
                    {
                        bus.publish(EngineEvent::Depth(equity_depth(symbol, &q)));
                    }
                }
                Err(e) => {
                    consecutive_failures += 1;
                    if consecutive_failures == 3 {
                        published_down = true;
                        bus.publish(EngineEvent::FeedStatus(FeedStatus {
                            feed: FEED_NAME.into(),
                            health: FeedHealth::Down,
                            detail: format!("quote polling failing: {e}"),
                            ts_ms: now_ms(),
                        }));
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        // Sleep between poll cycles, but wake early when the actively-viewed
        // depth symbol changes so the ladder shows the last-known delayed
        // top-of-book immediately on open (rather than up to a poll away).
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(POLL_SECS)) => {}
            changed = depth_rx.changed() => {
                if changed.is_err() {
                    return; // command side gone: squadron shutdown
                }
                let active = depth_rx.borrow_and_update().clone();
                if let Some(sym) = active {
                    // Same precedence rule as the poll path. On a symbol SWITCH
                    // nothing owns the new symbol yet, so the delayed book still
                    // seeds the ladder instantly (labelled is_live=false) and
                    // the live IBKR ladder — which is opening off this same
                    // watch update — takes it over a beat later. A truthful
                    // stand-in beats an empty ladder; a re-assert of a symbol
                    // already served live stays quiet.
                    if let Some(q) = last_seen.get(&sym) {
                        if !live_depth_owns(&sym, now_ms()) {
                            bus.publish(EngineEvent::Depth(equity_depth(&sym, q)));
                        }
                    }
                }
            }
        }
    }
}

/// Build the honest single-level DELAYED depth for an equity from its latest
/// CBOE top-of-book. `is_live = false` and `source` disclose that this is
/// delayed L1 with NO real order-book depth — the UI shows something truthful
/// without pretending crypto-style live L2. A side is present only when its
/// price is finite and positive (and the ask is not crossed); nothing is
/// fabricated. `count` is 0 (no order count in an L1 quote). Real, live equity
/// depth comes ONLY from the IBKR integration point below, never from here.
pub(crate) fn equity_depth(symbol: &str, q: &EquityQuote) -> BookDepth {
    let mut bids = Vec::new();
    let mut asks = Vec::new();
    // Delayed L1 stand-in — a single anonymous level per side, never route-
    // attributed (`mm: None`). Real market-maker routes come only from the live
    // IBKR reqMktDepth path below.
    if q.bid.is_finite() && q.bid > 0.0 {
        bids.push(BookLevel::agg(q.bid, q.bid_size.max(0.0), 0));
    }
    if q.ask.is_finite() && q.ask > 0.0 && q.ask >= q.bid {
        asks.push(BookLevel::agg(q.ask, q.ask_size.max(0.0), 0));
    }
    BookDepth {
        symbol: symbol.to_string(),
        bids,
        asks,
        depth: 1,
        source: EQUITY_DEPTH_SOURCE.into(),
        is_live: false,
        ts_ms: now_ms(),
    }
}

// ---------------------------------------------------------------------------
// IBKR INTEGRATION POINT.
//
// Real equity LEVEL 1 / LEVEL 2 depth and a real trade tape become available
// once the operator connects IB Gateway / TWS and the IBKR adapter (cx-broker,
// behind the `ibkr` feature) requests them:
//   - `reqMktData`  -> live/frozen top-of-book (L1) and last-trade prints;
//   - `reqMktDepth` -> the aggregated LEVEL 2 order book (per-venue depth),
// both subject to the user's own IBKR market-data subscriptions.
//
// The adapter constructs honest `BookDepth` / `TapePrint` values (labelling
// `is_live`/`source` per the ACTUAL subscription — live vs delayed vs frozen)
// and publishes them through these two functions; cortexd (which depends on
// both crates) closes the seam. They are the ONLY sanctioned way to emit real
// equity depth/tape; the CBOE poller above never emits `is_live = true`.
// Keeping them here (not in cx-broker) preserves the bus-only rule: cx-broker
// publishes market data via cx-md's vocabulary without depending on the
// connectors.
// ---------------------------------------------------------------------------

/// How long a LIVE depth publish keeps the actively-viewed ladder, in ms.
///
/// Deliberately longer than the CBOE `POLL_SECS` cycle: while IBKR depth is
/// flowing, the delayed poller must never get a turn between two live edits,
/// or the operator would watch a real 20-row ladder blink to a one-level
/// delayed stand-in every 20 seconds. Bounded (rather than a latch) so a
/// session that dies — entitlement pulled, Gateway closed, socket lost — hands
/// the ladder BACK to the honest delayed book within one TTL instead of
/// leaving the equity book permanently dark.
const LIVE_DEPTH_TTL_MS: i64 = 30_000;

/// Which symbol currently has a live L2 ladder, and when it was last proven.
///
/// PRECEDENCE between the two equity depth publishers lives here because both
/// of them live in this file. There is exactly one actively-viewed depth symbol
/// per process (cortexd's `next_active_depth`), so one slot is the whole state.
/// A `Mutex` over a tuple, never held across an await — the critical section is
/// a compare and two field writes.
static LIVE_EQUITY_DEPTH: std::sync::Mutex<Option<(String, i64)>> = std::sync::Mutex::new(None);

/// Take the mutex without ever panicking. Release builds are `panic = "abort"`,
/// so a poisoned lock (a panic in another thread while holding it) must not be
/// allowed to take the trading process down over a depth-precedence hint — the
/// data behind it is a symbol and a timestamp, and stale is recoverable.
fn live_depth_slot() -> std::sync::MutexGuard<'static, Option<(String, i64)>> {
    LIVE_EQUITY_DEPTH
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Record that genuine live depth for `symbol` was just published.
fn claim_live_depth(symbol: &str, ts_ms: i64) {
    let mut slot = live_depth_slot();
    match slot.as_mut() {
        // Same ladder: refresh the proof in place, no allocation on the hot
        // path (this runs on every published live book, ~10/s).
        Some((s, ts)) if s.eq_ignore_ascii_case(symbol) => *ts = ts_ms,
        _ => *slot = Some((symbol.to_string(), ts_ms)),
    }
}

/// Whether a live L2 ladder currently owns `symbol` — i.e. whether the delayed
/// stand-in must stay quiet. False for every other symbol and once the claim
/// has aged past `LIVE_DEPTH_TTL_MS`.
fn live_depth_owns(symbol: &str, now: i64) -> bool {
    match live_depth_slot().as_ref() {
        Some((s, ts)) => {
            s.eq_ignore_ascii_case(symbol.trim()) && now.saturating_sub(*ts) <= LIVE_DEPTH_TTL_MS
        }
        None => false,
    }
}

/// Publish a LEVEL 2 (or L1) equity depth book obtained from the IBKR adapter.
/// The caller MUST label `is_live` / `source` truthfully for the subscription
/// that produced it (live `reqMktDepth`, delayed L1, or frozen). No-op-safe:
/// with no subscribers the event is simply dropped by the bus.
///
/// PRECEDENCE: a book labelled `is_live` also CLAIMS the actively-viewed ladder
/// for `LIVE_DEPTH_TTL_MS`, which silences this file's delayed CBOE stand-in
/// for that symbol (see the poller above). Live depth wins whenever available —
/// two publishers on one symbol would otherwise fight and the operator would
/// see a real ladder flicker to a one-level delayed book. The claim is made
/// HERE, at the single sanctioned live emitter, so no future caller can wire
/// the feed up and forget the guard. A book NOT labelled live claims nothing:
/// only real live depth may displace the honest delayed one.
pub fn publish_ibkr_depth(bus: &Bus, depth: BookDepth) {
    if depth.is_live {
        claim_live_depth(&depth.symbol, now_ms());
    }
    bus.publish(EngineEvent::Depth(depth));
}

/// Publish a real equity trade print (Time & Sales) obtained from the IBKR
/// adapter's `reqMktData` last-trade stream. The caller labels `is_live`
/// truthfully and sets `aggressor` only when the venue actually discloses the
/// taker side (else `None` — never guessed).
pub fn publish_ibkr_tape(bus: &Bus, print: TapePrint) {
    bus.publish(EngineEvent::Tape(print));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_parses_and_rejects_garbage() {
        let raw = r#"{"data": {"symbol":"AAPL","current_price":308.45,"bid":308.44,"ask":308.47,"bid_size":200,"ask_size":40,"volume":75400626,"last_trade_time":"2026-07-02T16:00:00"}}"#;
        let q = parse_quote(raw).unwrap();
        assert_eq!(q.price, 308.45);
        assert_eq!(q.bid_size, 200.0);
        assert!(parse_quote("{}").is_none());
        assert!(parse_quote(r#"{"data":{"current_price":"NaN"}}"#).is_none());
    }

    /// The depth PRECEDENCE contract, end to end. One test rather than five
    /// because the claim slot is process-wide (one active ladder per engine)
    /// and cargo runs `#[test]`s in parallel — splitting it would let the cases
    /// race each other.
    #[test]
    fn live_ibkr_depth_owns_the_ladder_and_the_claim_expires() {
        let bus = Bus::new(64);
        let now = now_ms();
        let book = |symbol: &str, is_live: bool| BookDepth {
            symbol: symbol.into(),
            bids: vec![BookLevel {
                px: 10.0,
                sz: 1.0,
                count: 0,
                mm: None,
            }],
            asks: vec![BookLevel {
                px: 10.1,
                sz: 1.0,
                count: 0,
                mm: None,
            }],
            depth: 20,
            source: "test".into(),
            is_live,
            ts_ms: now,
        };

        // A DELAYED book claims nothing: the CBOE stand-in must never lock
        // itself in and shut out the real ladder.
        publish_ibkr_depth(&bus, book("DLYD", false));
        assert!(!live_depth_owns("DLYD", now_ms()));

        // A LIVE book takes the ladder for its own symbol only.
        publish_ibkr_depth(&bus, book("AAPL", true));
        let claimed = now_ms();
        assert!(
            live_depth_owns("AAPL", claimed),
            "live depth must own its symbol"
        );
        assert!(
            live_depth_owns(" aapl ", claimed),
            "match is trimmed + case-insensitive"
        );
        assert!(
            !live_depth_owns("MSFT", claimed),
            "a claim is per-symbol, not global"
        );

        // The claim is a bounded lease, not a latch: a dead live feed hands the
        // ladder back to the honest delayed book instead of leaving it dark.
        assert!(live_depth_owns("AAPL", claimed + LIVE_DEPTH_TTL_MS));
        assert!(!live_depth_owns("AAPL", claimed + LIVE_DEPTH_TTL_MS + 1));

        // Switching symbols moves the lease; the old one is released at once,
        // so the delayed stand-in resumes for a symbol nobody streams live.
        publish_ibkr_depth(&bus, book("MSFT", true));
        let moved = now_ms();
        assert!(live_depth_owns("MSFT", moved));
        assert!(!live_depth_owns("AAPL", moved));

        // Leave the slot clean for anything else in this binary.
        *live_depth_slot() = None;
    }

    #[test]
    fn equity_depth_is_honest_delayed_single_level() {
        // A live-looking CBOE quote still yields a DELAYED, is_live=false book
        // of a single level per side — never crypto-style live L2.
        let raw = r#"{"data":{"symbol":"AAPL","current_price":308.45,"bid":308.44,
            "ask":308.47,"bid_size":200,"ask_size":40,"volume":1,"last_trade_time":""}}"#;
        let q = parse_quote(raw).unwrap();
        let depth = equity_depth("AAPL", &q);
        assert!(!depth.is_live, "equity depth must never claim to be live");
        assert_eq!(depth.source, "cboe delayed L1 (no depth)");
        assert_eq!(depth.depth, 1);
        assert_eq!(depth.bids.len(), 1);
        assert_eq!(depth.asks.len(), 1);
        assert_eq!(depth.bids[0].px, 308.44);
        assert_eq!(depth.bids[0].sz, 200.0);
        assert_eq!(depth.bids[0].count, 0);
        assert_eq!(depth.asks[0].px, 308.47);
        assert_eq!(depth.asks[0].sz, 40.0);

        // A crossed / missing ask drops that side rather than fabricating one.
        let crossed = EquityQuote {
            price: 10.0,
            bid: 10.0,
            ask: 9.5, // crossed
            bid_size: 5.0,
            ask_size: 5.0,
            volume: 0.0,
            last_trade_time: String::new(),
        };
        let depth = equity_depth("XYZ", &crossed);
        assert_eq!(depth.bids.len(), 1);
        assert!(depth.asks.is_empty(), "a crossed ask is dropped, not shown");
        assert!(!depth.is_live);
    }

    #[test]
    fn chart_url_intraday_includes_pre_post_daily_does_not() {
        let m5 = chart_url("AAPL", "5d", "5m", true);
        assert_eq!(
            m5,
            "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=5d&interval=5m&includePrePost=true"
        );
        let h1 = chart_url("AAPL", "3mo", "1h", true);
        assert!(h1.contains("&includePrePost=true"));
        let d1 = chart_url("AAPL", "5y", "1d", false);
        assert_eq!(
            d1,
            "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=5y&interval=1d"
        );
        assert!(!d1.contains("includePrePost"));
    }

    /// Wall clock well past every fixture row, so all of them are finished
    /// buckets (the forming-row case has its own test below).
    const AFTER_FIXTURES_MS: i64 = 1_800_000_000_000; // 2027-01-15

    #[test]
    fn yahoo_chart_parses_skips_nulls_and_caps() {
        let raw = r#"{"chart":{"result":[{"timestamp":[1751500800,1751587200,1751673600],
            "indicators":{"quote":[{
                "open":[100.0,null,105.0],"high":[105.0,107.0,107.5],
                "low":[99.0,103.0,104.0],"close":[104.0,106.0,106.5],
                "volume":[1000,900,1100]}]}}]}}"#;
        let bars = parse_yahoo_chart("AAPL", Interval::D1, raw, 10, AFTER_FIXTURES_MS);
        // Middle row has a null open -> skipped.
        assert_eq!(bars.len(), 2);
        assert!(bars[0].ts_open_ms < bars[1].ts_open_ms);
        assert_eq!(bars[1].close, 106.5);
        assert!(bars.iter().all(|b| b.complete && b.interval == Interval::D1));
        // Capping keeps the newest.
        let capped = parse_yahoo_chart("AAPL", Interval::D1, raw, 1, AFTER_FIXTURES_MS);
        assert_eq!(capped.len(), 1);
        assert_eq!(capped[0].close, 106.5);
        assert!(parse_yahoo_chart("AAPL", Interval::D1, "junk", 10, AFTER_FIXTURES_MS).is_empty());
        assert!(parse_yahoo_chart("AAPL", Interval::D1, "{}", 10, AFTER_FIXTURES_MS).is_empty());
    }

    /// Intraday bars keep Yahoo's true opens; D1 floors to UTC midnight.
    /// 2025-07-02 (EDT): 13:00 UTC = 09:00 ET pre-market hourly, 13:30 UTC
    /// = the 09:30-anchored RTH hourly. Flooring both to the 13:00 bucket
    /// used to collapse them into one bar (the store replaces same-ts tails)
    /// and shade the first regular hour as pre-market.
    #[test]
    fn intraday_keeps_true_opens_daily_floors() {
        let raw = r#"{"chart":{"result":[{"timestamp":[1751461200,1751463000],
            "indicators":{"quote":[{
                "open":[100.0,101.0],"high":[101.0,103.0],
                "low":[99.5,100.5],"close":[100.8,102.4],
                "volume":[500,9000]}]}}]}}"#;

        let h1 = parse_yahoo_chart("AAPL", Interval::H1, raw, 10, AFTER_FIXTURES_MS);
        assert_eq!(h1.len(), 2, "pre-market and RTH bars must both survive");
        assert_eq!(h1[0].ts_open_ms, 1_751_461_200_000); // 09:00 ET, as sent
        assert_eq!(h1[1].ts_open_ms, 1_751_463_000_000); // 09:30 ET, not floored
        let m5 = parse_yahoo_chart("AAPL", Interval::M5, raw, 10, AFTER_FIXTURES_MS);
        assert_eq!(m5[0].ts_open_ms, 1_751_461_200_000);

        let d1 = parse_yahoo_chart("AAPL", Interval::D1, raw, 10, AFTER_FIXTURES_MS);
        // Both land in the same UTC day; the same-bucket tail replaces.
        assert!(d1.iter().all(|b| b.ts_open_ms == 1_751_414_400_000));

        // Those true opens are exactly the grid live aggregation uses, so the
        // two sources cannot interleave two hourly grids in one store series.
        assert_eq!(
            crate::agg::bar_bucket("AAPL", Interval::H1, 1_751_463_000_000 + 900_000),
            1_751_463_000_000
        );
        assert_eq!(
            crate::agg::bar_bucket("AAPL", Interval::H1, 1_751_461_200_000 + 600_000),
            1_751_461_200_000
        );
    }

    /// Yahoo hands back the in-progress bucket as its last row. It must not be
    /// labelled `complete` — `scanner::read_bars` and `regimes::classify` gate
    /// on that flag precisely to exclude forming bars, and a half session
    /// walking through resets days_in_state and divides a partial-day volume by
    /// 20 full-day averages.
    #[test]
    fn forming_bucket_row_is_not_marked_complete() {
        // Rows at 2025-07-02 09:00 ET (13:00 UTC) and 09:30 ET (13:30 UTC).
        let raw = r#"{"chart":{"result":[{"timestamp":[1751461200,1751463000],
            "indicators":{"quote":[{
                "open":[100.0,101.0],"high":[101.0,103.0],
                "low":[99.5,100.5],"close":[100.8,102.4],
                "volume":[500,9000]}]}}]}}"#;

        // Wall clock inside the 09:30 RTH hourly: the earlier row is finished,
        // the 09:30 one is still forming.
        let now = 1_751_463_000_000 + 20 * 60_000; // 09:50 ET
        let h1 = parse_yahoo_chart("AAPL", Interval::H1, raw, 10, now);
        assert_eq!(h1.len(), 2);
        assert!(h1[0].complete, "the 09:00 hourly has ended");
        assert!(!h1[1].complete, "the 09:30 hourly is still forming");
        // The partial row is KEPT (the chart draws it, and the live aggregator
        // seeds its forming bucket from it) — only the label changes.
        assert_eq!(h1[1].volume, 9000.0);

        // Same rule for the daily series: today's session is not a finished bar.
        let d1 = parse_yahoo_chart("AAPL", Interval::D1, raw, 10, now);
        assert!(d1.iter().all(|b| !b.complete));
        // A day later it is.
        let d1_after = parse_yahoo_chart("AAPL", Interval::D1, raw, 10, now + 86_400_000);
        assert!(d1_after.iter().all(|b| b.complete));
    }

    /// The venue's own trade time, not our wall clock, decides which bucket a
    /// delayed quote lands in and whether it counts as a regular-hours print.
    #[test]
    fn trade_time_resolves_eastern_and_rejects_nonsense() {
        // 2026-07-02 is EDT (UTC-4): 16:00 ET = 20:00 UTC.
        let edt_now = 1_783_022_400_000; // 2026-07-02T20:00:00Z
        assert_eq!(
            parse_trade_time_ms("2026-07-02T16:00:00", edt_now),
            Some(1_783_022_400_000)
        );
        // 2026-01-15 is EST (UTC-5): 16:00 ET = 21:00 UTC.
        let est_now = 1_768_510_800_000; // 2026-01-15T21:00:00Z
        assert_eq!(
            parse_trade_time_ms("2026-01-15T16:00:00", est_now),
            Some(1_768_510_800_000)
        );
        // Space separator and fractional seconds also parse.
        assert_eq!(
            parse_trade_time_ms("2026-07-02 16:00:00.000", edt_now),
            Some(1_783_022_400_000)
        );
        // An explicit offset is honoured as sent.
        assert_eq!(
            parse_trade_time_ms("2026-07-02T20:00:00+00:00", edt_now),
            Some(1_783_022_400_000)
        );
        // Empty / malformed / implausible -> None, so the caller falls back to
        // `now - FEED_DELAY_MS` instead of trusting a guess.
        assert!(parse_trade_time_ms("", edt_now).is_none());
        assert!(parse_trade_time_ms("not a time", edt_now).is_none());
        assert!(
            parse_trade_time_ms("2027-07-02T16:00:00", edt_now).is_none(),
            "a feed 15 minutes behind us can never be ahead of us"
        );
        assert!(parse_trade_time_ms("2019-07-02T16:00:00", edt_now).is_none());
    }

    /// Live equity bars used to carry volume 0 because the cumulative session
    /// volume was parsed and dropped: the chart's volume pane skips zero-volume
    /// bars, so the live tail read as "no trading".
    #[test]
    fn traded_volume_is_the_cumulative_delta_never_negative() {
        assert_eq!(traded_delta(None, 75_400_626.0), 0.0, "no baseline yet");
        assert_eq!(traded_delta(Some(75_400_626.0), 75_412_000.0), 11_374.0);
        // Session rollover: cumulative resets, and a negative size is not a
        // thing. Same for a NaN on either side of the difference.
        assert_eq!(traded_delta(Some(75_412_000.0), 1_200.0), 0.0);
        assert_eq!(traded_delta(Some(f64::NAN), 1_200.0), 0.0);
        assert_eq!(traded_delta(Some(1_000.0), f64::NAN), 0.0);
    }
}

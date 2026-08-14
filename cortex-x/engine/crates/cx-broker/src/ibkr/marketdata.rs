//! Live IBKR EQUITY market data — the `reqMktDepth` L2 ladder and the
//! `reqTickByTick(AllLast)` trade tape. Compiled ONLY under the `ibkr` feature.
//!
//! ## Why this sits BESIDE the order adapter, not inside it
//! The order path ([`super::IbkrBroker`] + [`super::wire`]) is the real-money
//! surface: it is guarded, reconciled and deliberately boring. Market data is
//! high-volume, best-effort and allowed to fail all day long. Wiring the two
//! through one socket would let a depth stall, a resubscribe storm or a
//! market-data reconnect perturb order routing, so this module opens its OWN
//! `ibapi::Client` on its OWN client id (see [`MarketDataConfig::from_broker`]).
//! IB Gateway multiplexes API clients by id; two sockets to the same Gateway is
//! the supported way to get this isolation. Nothing here can place, cancel or
//! observe an order.
//!
//! ## Why it takes SINKS instead of publishing itself
//! `cx-broker` must not depend on the market-data connectors (cx-md): the
//! sanctioned emitters for real equity depth/tape are `cx_md::publish_ibkr_depth`
//! / `publish_ibkr_tape`, and cortexd — which depends on both — closes that
//! seam. So this module builds honest [`BookDepth`] / [`TapePrint`] values and
//! hands them to a caller-supplied [`MarketDataSink`]. Feed HEALTH (a
//! [`FeedStatus`] / [`AgentThought`]) is not market data and is published
//! straight to the bus, exactly as the order adapter already does.
//!
//! ## One symbol at a time
//! Depth is bandwidth-expensive and the operator looks at one ladder. cortexd's
//! `next_active_depth` already resolves Subscribe/UnsubscribeDepth into a single
//! active symbol and pushes it down a `tokio::sync::watch` channel; this loop
//! listens on the SAME channel (never a second signal). A symbol change CANCELS
//! both subscriptions before the next pair is opened, so nothing keeps streaming
//! for a symbol the operator navigated away from, and no task is leaked — the
//! whole feed is ONE task with the subscriptions owned as locals.
//!
//! ## Failure posture
//! An operator WITHOUT an L2 / tick-by-tick entitlement is the COMMON case, not
//! an exception. Every failure mode here — refused subscription, TWS notice,
//! stream error, dropped socket — becomes a visible [`FeedStatus`] plus (for the
//! ones the operator must act on) a thought, and is then RETRIED with backoff.
//! Nothing panics (release is `panic = "abort"`; one bad quote must not kill the
//! trading process) and the loop never returns on a transient error — a returned
//! task is dead for the life of the process with no UI signal.

use std::sync::Arc;
use std::time::{Duration, Instant};

use ibapi::market_data::realtime::{MarketDepths, Trade};
use ibapi::prelude::*;

use cx_core::bus::Bus;
use cx_core::config::BrokerConfig;
use cx_core::events::{
    AgentThought, BookDepth, EngineEvent, FeedHealth, FeedStatus, TapePrint,
};
use cx_core::time::now_ms;
use cx_core::types::{asset_class_of, AssetClass, Severity};

use super::book::{DepthBook, DepthUpdate};
use crate::translate::{route_or_smart, SMART};

/// Book rows requested from IBKR. Matches the Coinbase L2 publisher's 20 so
/// both ladders render at the same depth; `DepthBook` clamps it to its own hard
/// cap regardless of what is configured.
pub const DEPTH_ROWS: usize = 20;

/// Minimum interval between depth PUBLISHES. Every wire edit is still applied
/// to the maintained book — only the render cadence is bounded (~10/s), the
/// same throttle the Coinbase L2 feed uses. Without it a liquid name floods the
/// broadcast bus and the app's ladder with edits no human can read.
const DEPTH_MIN_INTERVAL: Duration = Duration::from_millis(100);
/// How long a depth stream may go completely silent before the feed is called
/// degraded. A stream that stops producing without erroring blocks its `select!`
/// arm forever, so nothing else would ever notice.
const DEPTH_STALL_TIMEOUT: Duration = Duration::from_secs(20);

/// How many CONSECUTIVE stream errors on one subscription are tolerated before
/// the session is declared lost and the socket rebuilt. A single decode hiccup
/// must not tear down a healthy feed; a wedged stream must not be nursed
/// forever.
const MAX_CONSECUTIVE_STREAM_ERRORS: u32 = 5;

/// Reconnect / resubscribe backoff bounds.
const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(30);

/// Feed identity on the status bus. Two names because the entitlements are
/// separately purchasable: an operator commonly has one and not the other, and
/// collapsing them would hide which half is dark.
const FEED_DEPTH: &str = "ibkr-depth";
const FEED_TAPE: &str = "ibkr-tape";

/// Provenance for the tape. `is_live = true` is only ever set from a genuine
/// `reqTickByTick(AllLast)` stream — see [`emit_trade`].
const TAPE_SOURCE: &str = "ibkr tickByTick AllLast";

/// How this feed connects and what it asks for. Derived from the SAME
/// [`BrokerConfig`] the order adapter reads, so depth and orders can never
/// disagree about which Gateway or which venue a symbol means.
#[derive(Debug, Clone)]
pub struct MarketDataConfig {
    pub host: String,
    pub port: u16,
    /// A DISTINCT API client id from the order adapter's — IB Gateway rejects a
    /// duplicate id, and the separation is the point (module docs).
    pub client_id: i32,
    /// The configured equity route ("SMART" or a direct venue). Depth is
    /// requested on the same venue orders are routed to.
    pub route: String,
    /// Rows requested per side (`reqMktDepth` numRows).
    pub rows: usize,
}

impl MarketDataConfig {
    /// Derive the feed's connection from the broker config. The client id is
    /// the order adapter's + 1: same Gateway, its own session. `saturating_add`
    /// because an operator-supplied `i32::MAX` must wrap into a panic-free
    /// value, not overflow.
    pub fn from_broker(cfg: &BrokerConfig) -> Self {
        Self {
            host: cfg.ibkr_host.clone(),
            port: cfg.ibkr_port,
            client_id: cfg.ibkr_client_id.saturating_add(1),
            route: cfg.ibkr_route.clone(),
            rows: DEPTH_ROWS,
        }
    }

    fn addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }

    /// The contract's destination exchange — identical to what
    /// [`crate::translate::translate`] puts on an order contract.
    fn exchange(&self) -> String {
        route_or_smart(&self.route)
    }

    /// SMART depth AGGREGATES the book across exchanges and needs its own
    /// entitlement; a direct venue route wants that venue's own book, so smart
    /// depth is off. Requesting smart depth on a direct route would silently
    /// return a different book than the one being traded.
    fn wants_smart_depth(&self) -> bool {
        self.exchange() == SMART
    }

    /// The `source` string stamped on every emitted [`BookDepth`]. It names the
    /// REAL subscription and the REAL venue, because the app renders it as the
    /// book's provenance next to a LIVE badge.
    fn depth_source(&self) -> String {
        if self.wants_smart_depth() {
            "ibkr reqMktDepth L2 (SMART)".to_string()
        } else {
            format!("ibkr reqMktDepth L2 ({})", self.exchange())
        }
    }
}

/// Where finished market data goes. Deliberately a pair of callbacks rather
/// than a `Bus`: cx-broker must not reach into cx-md's publishers, so cortexd
/// supplies closures that call `cx_md::publish_ibkr_depth` / `publish_ibkr_tape`
/// (module docs).
pub struct MarketDataSink {
    depth: Box<dyn Fn(BookDepth) + Send + Sync>,
    tape: Box<dyn Fn(TapePrint) + Send + Sync>,
}

impl MarketDataSink {
    pub fn new(
        depth: impl Fn(BookDepth) + Send + Sync + 'static,
        tape: impl Fn(TapePrint) + Send + Sync + 'static,
    ) -> Self {
        Self {
            depth: Box::new(depth),
            tape: Box::new(tape),
        }
    }

    fn emit_depth(&self, d: BookDepth) {
        (self.depth)(d);
    }

    fn emit_tape(&self, t: TapePrint) {
        (self.tape)(t);
    }
}

/// Spawn [`run_market_data`] as a background task. Returns the handle so the
/// caller can abort the feed on shutdown; the task itself never exits on a
/// transient error.
pub fn spawn_market_data(
    bus: Arc<Bus>,
    cfg: MarketDataConfig,
    depth_rx: tokio::sync::watch::Receiver<Option<String>>,
    sink: MarketDataSink,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(run_market_data(bus, cfg, depth_rx, sink))
}

/// The live equity market-data feed. Runs until the active-depth `watch` sender
/// is dropped (engine shutdown) — every other exit path loops and retries.
///
/// Shape: resolve the active symbol -> ensure a connected client -> stream that
/// ONE symbol's depth + tape until the symbol changes or the session breaks ->
/// cancel, and go round again.
pub async fn run_market_data(
    bus: Arc<Bus>,
    cfg: MarketDataConfig,
    mut depth_rx: tokio::sync::watch::Receiver<Option<String>>,
    sink: MarketDataSink,
) {
    let mut reporter = Reporter::new(bus);
    let mut backoff = Backoff::new();
    // Held across symbol switches: reconnecting per ladder open would cost a
    // second of latency every time the operator changes symbol.
    let mut client: Option<Arc<Client>> = None;

    loop {
        // The active symbol, per cortexd's ONE-at-a-time depth signal. `None`
        // (nothing open in the app) means we hold NO subscription at all —
        // idle bandwidth is zero, which is the whole reason the signal exists.
        // Cloned out of the `watch::Ref` immediately: holding that borrow across
        // the `changed().await` below would keep the watch lock over an await
        // point (and the borrow checker rightly refuses it).
        let active = depth_rx.borrow_and_update().clone();
        let symbol = match active {
            Some(s) if !s.trim().is_empty() => s.trim().to_string(),
            _ => {
                reporter.idle();
                // A closed channel means the command side is gone — engine
                // shutdown, not a transient error. This is the ONLY return.
                if depth_rx.changed().await.is_err() {
                    return;
                }
                continue;
            }
        };

        // v1 streams US equities only, mirroring the order adapter's preflight.
        // Crypto depth already arrives live from Coinbase; asking IBKR for it
        // would duplicate a book under a different provenance label.
        if asset_class_of(&symbol) != AssetClass::Equity {
            reporter.non_equity(&symbol);
            if depth_rx.changed().await.is_err() {
                return;
            }
            continue;
        }

        let active = match client.clone() {
            Some(c) => c,
            None => match Client::connect(&cfg.addr(), cfg.client_id).await {
                Ok(c) => {
                    let c = Arc::new(c);
                    client = Some(Arc::clone(&c));
                    backoff.reset();
                    c
                }
                Err(e) => {
                    reporter.connect_failed(&cfg, &e.to_string());
                    backoff.wait().await;
                    continue;
                }
            },
        };

        match serve_symbol(&active, &cfg, &symbol, &sink, &mut depth_rx, &mut reporter).await {
            // The operator moved on. Subscriptions are already cancelled; keep
            // the socket and open the next ladder immediately.
            Outcome::SymbolChanged => backoff.reset(),
            Outcome::Shutdown => return,
            // Subscriptions refused but the socket looks fine (the entitlement
            // case). Keep the client, wait, try again — the operator may enable
            // the subscription in Account Management without restarting us.
            Outcome::Resubscribe => backoff.wait().await,
            // The stream died: assume the socket is gone and rebuild it.
            Outcome::SessionLost(reason) => {
                reporter.session_lost(&reason);
                if let Some(c) = client.take() {
                    c.disconnect().await;
                }
                backoff.wait().await;
            }
        }
    }
}

/// Whether an update was withheld purely by the rate gate and therefore still
/// owes the screen a render. `No` covers both "published" and "deliberately
/// suppressed" — only `Yes` arms the flush.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Deferred {
    Yes,
    No,
}

/// Sleep until the rate gate would next admit a publish. With no prior publish
/// there is nothing to defer, so this parks forever and its `select!` arm never
/// fires.
async fn sleep_until_flush(last_pub: Option<Instant>) {
    match last_pub {
        Some(t) => {
            let elapsed = t.elapsed();
            if elapsed < DEPTH_MIN_INTERVAL {
                tokio::time::sleep(DEPTH_MIN_INTERVAL - elapsed).await;
            }
        }
        None => std::future::pending::<()>().await,
    }
}

/// Why [`serve_symbol`] stopped. Each variant maps to a different recovery, and
/// none of them ends the feed.
enum Outcome {
    /// The active-depth signal named a different symbol (or none).
    SymbolChanged,
    /// The active-depth sender was dropped — engine shutdown.
    Shutdown,
    /// Nothing could be subscribed; retry on the same socket after a backoff.
    Resubscribe,
    /// The session is unusable; drop the socket and reconnect.
    SessionLost(String),
}

/// Stream ONE symbol's depth + tape until the active symbol changes or the
/// session breaks. Both subscriptions are owned as locals here, so leaving this
/// function by ANY path cancels them — there is no way to leak a stream for a
/// symbol the operator navigated away from.
async fn serve_symbol(
    client: &Client,
    cfg: &MarketDataConfig,
    symbol: &str,
    sink: &MarketDataSink,
    depth_rx: &mut tokio::sync::watch::Receiver<Option<String>>,
    reporter: &mut Reporter,
) -> Outcome {
    // Same contract shape the order path builds (see `wire::submit_intent`):
    // STK on the configured route, USD. If depth and orders disagreed about the
    // contract, the ladder would be a different instrument than the one filled.
    let contract = Contract::stock(symbol)
        .on_exchange(cfg.exchange().as_str())
        .in_currency("USD")
        .build();

    // A fresh subscription REPLAYS the book from position 0, so the ladder must
    // start empty — otherwise a retained row is silently mixed into the new
    // venue book and every later positional edit lands off by one. A book built
    // here per subscription satisfies that by construction; the explicit
    // `reset` pins the invariant so a future refactor that hoists the book out
    // of this function cannot quietly break it.
    let mut book = DepthBook::new(symbol, cfg.depth_source(), cfg.rows);
    book.reset();

    let smart = if cfg.wants_smart_depth() {
        SmartDepth::Yes
    } else {
        SmartDepth::No
    };
    let rows = cfg.rows.min(i32::MAX as usize) as i32;
    let mut depth_sub = match client
        .market_depth(&contract, rows)
        .smart_depth(smart)
        .subscribe()
        .await
    {
        Ok(s) => {
            reporter.depth_up(symbol, &cfg.depth_source());
            Some(s)
        }
        Err(e) => {
            reporter.depth_unavailable(symbol, &e.to_string());
            None
        }
    };

    // `number_of_ticks = 0` = pure streaming, no historical tick backfill: the
    // tape is a live-from-now feed, and backfilled ticks would land on the tape
    // out of order behind the ones already rendered.
    let mut tape_sub = match client.tick_by_tick(&contract, 0).all_last().await {
        Ok(s) => {
            reporter.tape_up(symbol);
            Some(s)
        }
        Err(e) => {
            reporter.tape_unavailable(symbol, &e.to_string());
            None
        }
    };

    if depth_sub.is_none() && tape_sub.is_none() {
        // Neither half came up. Don't spin the Gateway: the caller backs off and
        // retries on this same socket (the operator may be enabling the
        // subscription right now).
        return Outcome::Resubscribe;
    }

    let mut last_pub: Option<Instant> = None;
    // A render withheld by the rate gate still owes the screen an update; the
    // flush arm below settles it so the final edit of a burst is never lost.
    let mut deferred = Deferred::No;
    let aggregated = cfg.wants_smart_depth();
    let mut depth_errors: u32 = 0;
    let mut tape_errors: u32 = 0;
    // Rejections and crossed books are counted and logged at a bounded rate: a
    // silent drop is exactly how a desynced ladder survives a whole session.
    let mut reject_log = Throttle::new(5_000);
    let mut crossed_log = Throttle::new(5_000);

    let outcome = loop {
        tokio::select! {
            // The active-symbol signal wins: a switch must tear the old
            // subscriptions down before a busy book can enqueue more work.
            biased;

            changed = depth_rx.changed() => {
                if changed.is_err() {
                    break Outcome::Shutdown;
                }
                let next = depth_rx.borrow_and_update().clone();
                let same = next.as_deref().map(str::trim) == Some(symbol);
                if !same {
                    break Outcome::SymbolChanged;
                }
                // The same symbol re-asserted (a re-open of the same ladder):
                // keep the live subscriptions rather than churning the Gateway.
            }

            item = next_item(&mut depth_sub) => match item {
                None => break Outcome::SessionLost("depth stream ended".into()),
                Some(Err(e)) => {
                    depth_errors += 1;
                    tracing::warn!(symbol, "IBKR depth stream error: {e}");
                    if depth_errors >= MAX_CONSECUTIVE_STREAM_ERRORS {
                        break Outcome::SessionLost(format!("depth stream errors: {e}"));
                    }
                }
                Some(Ok(SubscriptionItem::Notice(n))) => {
                    // TWS delivers entitlement / bad-contract messages HERE, not
                    // as a subscribe error. This is the message an operator
                    // without an L2 subscription actually sees.
                    reporter.depth_notice(symbol, &n.to_string());
                }
                Some(Ok(SubscriptionItem::Data(d))) => {
                    depth_errors = 0;
                    apply_depth(&mut book, &d, &mut reject_log);
                    deferred = publish_depth(
                        &book, sink, &mut last_pub, &mut crossed_log, reporter, aggregated,
                    );
                }
            },

            // Settle a render the rate gate withheld. Without this the LAST
            // edit before a quiet period never reaches the ladder, so a level
            // the venue just deleted stays on screen indefinitely.
            () = sleep_until_flush(last_pub), if deferred == Deferred::Yes => {
                deferred = publish_depth(
                    &book, sink, &mut last_pub, &mut crossed_log, reporter, aggregated,
                );
            }

            // A stream that simply stops producing — no error, no end — parks its
            // arm forever, so nothing else would ever notice. Say so rather than
            // letting a dead feed keep reading healthy.
            _ = tokio::time::sleep(DEPTH_STALL_TIMEOUT) => {
                reporter.depth_degraded(&format!(
                    "{symbol}: no depth update for {}s — the stream may have stalled",
                    DEPTH_STALL_TIMEOUT.as_secs()
                ));
            }

            item = next_item(&mut tape_sub) => match item {
                None => break Outcome::SessionLost("tape stream ended".into()),
                Some(Err(e)) => {
                    tape_errors += 1;
                    tracing::warn!(symbol, "IBKR tape stream error: {e}");
                    if tape_errors >= MAX_CONSECUTIVE_STREAM_ERRORS {
                        break Outcome::SessionLost(format!("tape stream errors: {e}"));
                    }
                }
                Some(Ok(SubscriptionItem::Notice(n))) => {
                    reporter.tape_notice(symbol, &n.to_string());
                }
                Some(Ok(SubscriptionItem::Data(t))) => {
                    tape_errors = 0;
                    emit_trade(symbol, &t, sink);
                }
            },
        }
    };

    // Explicit cancels. `Subscription`'s Drop also sends one, but Drop can only
    // SPAWN the send — cancelling here means the Gateway has released the depth
    // line before the next symbol's request goes out, which matters when the
    // account is at its market-data line limit.
    if let Some(s) = depth_sub.as_ref() {
        s.cancel().await;
    }
    if let Some(s) = tape_sub.as_ref() {
        s.cancel().await;
    }
    drop(depth_sub);
    drop(tape_sub);
    reporter.streams_closed(symbol);
    outcome
}

/// `Subscription::next` for an optional subscription: when the half is absent
/// (not entitled) this never resolves, so `select!` simply serves the other
/// half. Cancel-safe — it delegates to `StreamExt::next`, which is.
async fn next_item<T: Send + 'static>(
    sub: &mut Option<Subscription<T>>,
) -> Option<Result<SubscriptionItem<T>, Error>> {
    match sub {
        Some(s) => s.next().await,
        None => std::future::pending().await,
    }
}

/// Map ONE `ibapi` depth message onto the always-compiled ladder. Every field
/// passes through verbatim — no side inversion, no operation remap: IBKR's
/// `side` (0 = ask, 1 = bid) and `operation` ARE [`DepthBook`]'s vocabulary, and
/// "helpfully" normalising either here is how a book ends up mirrored.
fn apply_depth(book: &mut DepthBook, msg: &MarketDepths, log: &mut Throttle) {
    let update = match msg {
        MarketDepths::MarketDepth(m) => {
            DepthUpdate::unattributed(m.position, m.operation, m.side, m.price, m.size)
        }
        // `market_maker` is the exchange under smart depth and the MPID
        // otherwise — real venue attribution either way, never synthesised.
        MarketDepths::MarketDepthL2(m) => DepthUpdate::attributed(
            m.position,
            m.operation,
            m.side,
            m.price,
            m.size,
            m.market_maker.as_str(),
        ),
    };
    if let Some(reason) = book.apply(&update).reject_reason() {
        if log.ready() {
            tracing::warn!(
                symbol = book.symbol(),
                reason,
                rejected_total = book.rejected_total(),
                "IBKR depth edit rejected (ladder may be missing a level until the venue \
                 re-sends it)"
            );
        }
    }
}

/// Hand the current ladder to the sink, throttled, and NEVER when it is
/// crossed. A crossed ladder on a trading screen reads as free money; it means
/// our book desynced from the venue's positional list, so the honest move is to
/// hold the last good render and say so rather than paint a lie.
fn publish_depth(
    book: &DepthBook,
    sink: &MarketDataSink,
    last_pub: &mut Option<Instant>,
    crossed_log: &mut Throttle,
    reporter: &mut Reporter,
    aggregated: bool,
) -> Deferred {
    // WHETHER a cross means corruption depends on the subscription.
    //
    // On an AGGREGATED (SMART) book — the shipped default — locked and briefly
    // crossed tops are ordinary market structure: two venues quoting the same
    // price, or one lagging the other by microseconds. Suppressing there froze a
    // ladder that the app still badged LIVE, with no age check on the client to
    // catch it. A human trading against a frozen book that claims to be live is
    // the worst thing this module can produce, so aggregated books always
    // publish and the operator sees the market as it actually is.
    //
    // On a SINGLE-VENUE book one exchange cannot offer below its own bid, so a
    // cross really is a dropped or misapplied edit. There we hold the ladder —
    // but we mark the feed degraded IMMEDIATELY rather than on the throttled
    // path, because the moment we stop publishing, "live" stops being true and
    // the client must be told before it renders another frame.
    if aggregated {
        if book.is_crossed() && crossed_log.ready() {
            tracing::debug!(
                symbol = book.symbol(),
                "aggregated book momentarily crossed (bid {:?} > ask {:?}) — publishing anyway",
                book.best_bid(),
                book.best_ask()
            );
        }
    } else if book.is_crossed() || book.is_locked() {
        let detail = format!(
            "{} single-venue book is crossed (bid {:?} vs ask {:?}) — holding the last ladder",
            book.symbol(),
            book.best_bid(),
            book.best_ask()
        );
        // Unthrottled: the FIRST suppressed frame is the one the operator needs
        // to know about, and a 5s-throttled warning leaves the ladder reading
        // LIVE for five seconds after it stopped updating.
        reporter.depth_degraded(&detail);
        if crossed_log.ready() {
            tracing::warn!("IBKR depth: {detail}");
        }
        return Deferred::No;
    }
    // First render is immediate (the ladder must fill the instant it opens);
    // after that the cadence is bounded. Every edit is already in the book.
    let fresh = match last_pub {
        Some(t) => t.elapsed() >= DEPTH_MIN_INTERVAL,
        None => true,
    };
    if !fresh {
        // Withheld by the rate gate, NOT dropped. The caller arms a flush so the
        // final edit of a burst still reaches the screen: without it, the last
        // update before a quiet period is lost, and a 5,000-share bid that the
        // venue just deleted stays on the ladder indefinitely.
        return Deferred::Yes;
    }
    *last_pub = Some(Instant::now());
    sink.emit_depth(book.to_depth(now_ms()));
    Deferred::No
}

/// Map one `reqTickByTick(AllLast)` print onto the wire tape.
///
/// `aggressor` is **always `None`**: AllLast does NOT disclose the taker side.
/// Inferring it from an uptick/downtick would fabricate the single field the
/// FLOW desk's cumulative delta is built on — a guessed aggressor produces a
/// confident, wrong delta, which is strictly worse than an honest zero
/// (`FlowRead` documents unknown-aggressor prints as contributing 0).
fn emit_trade(symbol: &str, t: &Trade, sink: &MarketDataSink) {
    // Hostile-input policy: a non-finite/non-positive price or a negative size
    // is dropped, never coerced. `size` may legitimately be 0 on some
    // condition codes, and a 0-size print is still a print.
    if !t.price.is_finite() || t.price <= 0.0 || !t.size.is_finite() || t.size < 0.0 {
        return;
    }
    sink.emit_tape(TapePrint {
        symbol: symbol.to_string(),
        px: t.price,
        sz: t.size,
        aggressor: None,
        ts_ms: trade_ts_ms(t),
        is_live: true,
    });
}

/// The print's OWN exchange timestamp in epoch ms — not arrival time, which
/// would smear a burst of prints onto whenever our task happened to be polled
/// and defeat any tape-based timing read.
///
/// `unix_timestamp_nanos` is an `i128`; the ms division cannot overflow `i64`
/// for any real date, but a garbage decode (epoch 0, or a value outside our
/// range) falls back to now rather than emitting a 1970 print that would blow
/// out every chart window it lands in.
fn trade_ts_ms(t: &Trade) -> i64 {
    let ms = t.time.unix_timestamp_nanos() / 1_000_000;
    match i64::try_from(ms) {
        Ok(v) if v > 0 => v,
        _ => now_ms(),
    }
}

/// A monotonic minimum-interval gate for log lines fed by a socket. Uses
/// [`Instant`] (never wall-clock) so an NTP step cannot mute or unmute it.
struct Throttle {
    every: Duration,
    last: Option<Instant>,
}

impl Throttle {
    fn new(every_ms: u64) -> Self {
        Self {
            every: Duration::from_millis(every_ms),
            last: None,
        }
    }

    fn ready(&mut self) -> bool {
        let now = Instant::now();
        let ok = match self.last {
            Some(t) => now.duration_since(t) >= self.every,
            None => true,
        };
        if ok {
            self.last = Some(now);
        }
        ok
    }
}

/// Exponential reconnect/resubscribe backoff, bounded so a permanently missing
/// entitlement settles at one retry every [`BACKOFF_MAX`] instead of hammering
/// the Gateway forever.
struct Backoff {
    next: Duration,
}

impl Backoff {
    fn new() -> Self {
        Self { next: BACKOFF_MIN }
    }

    fn reset(&mut self) {
        self.next = BACKOFF_MIN;
    }

    async fn wait(&mut self) {
        let d = self.next;
        self.next = (self.next * 2).min(BACKOFF_MAX);
        tokio::time::sleep(d).await;
    }
}

/// Publishes the feed's HEALTH so a dark ladder is never silent.
///
/// De-duplicated on `(feed, health, detail)`: the failure modes here repeat
/// every retry, and a thought storm trains the operator to ignore the panel —
/// the opposite of visible. State CHANGES are always published.
struct Reporter {
    bus: Arc<Bus>,
    last_depth: Option<(FeedHealth, String)>,
    last_tape: Option<(FeedHealth, String)>,
}

/// Whether a feed slot is already reporting DOWN — the guard that stops a
/// retry loop from re-publishing the same actionable thought every backoff.
fn is_down(slot: &Option<(FeedHealth, String)>) -> bool {
    matches!(slot, Some((FeedHealth::Down, _)))
}

impl Reporter {
    fn new(bus: Arc<Bus>) -> Self {
        Self {
            bus,
            last_depth: None,
            last_tape: None,
        }
    }

    /// Publish a feed status if it differs from the last one for that feed.
    fn feed(&mut self, feed: &str, health: FeedHealth, detail: String) {
        let slot = if feed == FEED_DEPTH {
            &mut self.last_depth
        } else {
            &mut self.last_tape
        };
        if slot.as_ref() == Some(&(health.clone(), detail.clone())) {
            return;
        }
        *slot = Some((health.clone(), detail.clone()));
        self.bus.publish(EngineEvent::FeedStatus(FeedStatus {
            feed: feed.to_string(),
            health,
            detail,
            ts_ms: now_ms(),
        }));
    }

    /// A thought the operator is meant to ACT on (buy the subscription, start
    /// the Gateway). Warning, not critical: no market data is a degraded deck,
    /// never an unsafe position — the order path is untouched by all of this.
    fn thought(&self, text: String, symbol: Option<String>) {
        self.bus.publish(EngineEvent::Thought(AgentThought {
            agent: "ibkr-md".into(),
            squadron: "market-data".into(),
            severity: Severity::Warning,
            text,
            tags: vec!["market-data".into(), "ibkr".into(), "depth".into()],
            confidence: 1.0,
            symbol,
            ts_ms: now_ms(),
        }));
    }

    fn idle(&mut self) {
        // No ladder open is a normal resting state, not a fault: report it as
        // such so the badge doesn't read DOWN while nothing was ever requested.
        self.feed(
            FEED_DEPTH,
            FeedHealth::Degraded,
            "no active depth symbol".into(),
        );
        self.feed(
            FEED_TAPE,
            FeedHealth::Degraded,
            "no active depth symbol".into(),
        );
    }

    fn non_equity(&mut self, symbol: &str) {
        let detail = format!("{symbol} is not a US equity; IBKR depth/tape not requested");
        self.feed(FEED_DEPTH, FeedHealth::Degraded, detail.clone());
        self.feed(FEED_TAPE, FeedHealth::Degraded, detail);
    }

    fn connect_failed(&mut self, cfg: &MarketDataConfig, err: &str) {
        // Host/port/client-id are operator-local connection facts, not secrets
        // (the account id, which IS one, never appears in this module).
        let detail = format!(
            "cannot reach IB Gateway at {} (client id {}): {err}",
            cfg.addr(),
            cfg.client_id
        );
        tracing::warn!("IBKR market data: {detail}");
        let first = !is_down(&self.last_depth);
        self.feed(FEED_DEPTH, FeedHealth::Down, detail.clone());
        self.feed(FEED_TAPE, FeedHealth::Down, detail.clone());
        if first {
            self.thought(
                format!(
                    "Live equity depth/tape unavailable: {detail}. Equities fall back to the \
                     DELAYED single-level book (is_live = false). Start IB Gateway/TWS and \
                     enable API access to restore the live ladder."
                ),
                None,
            );
        }
    }

    fn depth_up(&mut self, symbol: &str, source: &str) {
        self.feed(
            FEED_DEPTH,
            FeedHealth::Live,
            format!("{symbol} via {source}"),
        );
    }

    fn tape_up(&mut self, symbol: &str) {
        self.feed(
            FEED_TAPE,
            FeedHealth::Live,
            format!("{symbol} via {TAPE_SOURCE}"),
        );
    }

    /// The COMMON case: the account has no Level-2 subscription. It must read
    /// as an explicit, actionable message — silence here is what makes an
    /// operator think the engine is broken.
    fn depth_unavailable(&mut self, symbol: &str, err: &str) {
        let detail = format!("no live L2 for {symbol}: {err}");
        tracing::warn!("IBKR depth unavailable: {detail}");
        let announce = !is_down(&self.last_depth);
        self.feed(FEED_DEPTH, FeedHealth::Down, detail.clone());
        if announce {
            self.thought(
                format!(
                    "No live IBKR order book for {symbol} ({err}). This usually means the \
                     account has no Level-2 / depth-of-book market-data subscription. The \
                     ladder stays on the DELAYED single-level book (is_live = false) until \
                     one is enabled — it is not being faked as live."
                ),
                Some(symbol.to_string()),
            );
        }
    }

    fn tape_unavailable(&mut self, symbol: &str, err: &str) {
        let detail = format!("no live tape for {symbol}: {err}");
        tracing::warn!("IBKR tape unavailable: {detail}");
        let announce = !is_down(&self.last_tape);
        self.feed(FEED_TAPE, FeedHealth::Down, detail.clone());
        if announce {
            self.thought(
                format!(
                    "No live IBKR Time & Sales for {symbol} ({err}). This usually means the \
                     account lacks a real-time top-of-book market-data subscription. No tape \
                     prints will be published for it."
                ),
                Some(symbol.to_string()),
            );
        }
    }

    /// TWS notices arrive mid-stream and carry the real reason (entitlement,
    /// unknown contract, depth line limit). Surface the text verbatim.
    fn depth_notice(&mut self, symbol: &str, notice: &str) {
        tracing::warn!(symbol, "IBKR depth notice: {notice}");
        self.feed(
            FEED_DEPTH,
            FeedHealth::Degraded,
            format!("{symbol}: {notice}"),
        );
    }

    fn tape_notice(&mut self, symbol: &str, notice: &str) {
        tracing::warn!(symbol, "IBKR tape notice: {notice}");
        self.feed(
            FEED_TAPE,
            FeedHealth::Degraded,
            format!("{symbol}: {notice}"),
        );
    }

    fn depth_degraded(&mut self, detail: &str) {
        self.feed(FEED_DEPTH, FeedHealth::Degraded, detail.to_string());
    }

    fn session_lost(&mut self, reason: &str) {
        let detail = format!("IBKR market-data session lost: {reason}; reconnecting");
        tracing::warn!("{detail}");
        self.feed(FEED_DEPTH, FeedHealth::Down, detail.clone());
        self.feed(FEED_TAPE, FeedHealth::Down, detail);
    }

    /// Both halves are down for this symbol because we tore them down — say so,
    /// so the badge cannot linger on LIVE for a ladder that is no longer fed.
    fn streams_closed(&mut self, symbol: &str) {
        let detail = format!("{symbol} subscriptions cancelled");
        self.feed(FEED_DEPTH, FeedHealth::Degraded, detail.clone());
        self.feed(FEED_TAPE, FeedHealth::Degraded, detail);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn broker_cfg(route: &str) -> BrokerConfig {
        BrokerConfig {
            ibkr_route: route.into(),
            ibkr_client_id: 11,
            ..Default::default()
        }
    }

    /// The feed must NOT share the order adapter's client id — IB Gateway
    /// rejects a duplicate, and the isolation is the point.
    #[test]
    fn market_data_uses_its_own_client_id() {
        let cfg = MarketDataConfig::from_broker(&broker_cfg("SMART"));
        assert_ne!(cfg.client_id, 11);
        assert_eq!(cfg.client_id, 12);
    }

    /// A blank route resolves to SMART exactly as the ORDER path does, so the
    /// ladder and the fill can never be on different venues.
    #[test]
    fn contract_venue_matches_the_order_route() {
        let smart = MarketDataConfig::from_broker(&broker_cfg("   "));
        assert_eq!(smart.exchange(), "SMART");
        assert!(smart.wants_smart_depth());

        let dma = MarketDataConfig::from_broker(&broker_cfg("ARCA"));
        assert_eq!(dma.exchange(), "ARCA");
        assert!(!dma.wants_smart_depth(), "a direct route wants that venue's own book");
    }

    /// `source` is provenance the app renders next to a LIVE badge: it must name
    /// the real subscription AND the real venue.
    #[test]
    fn depth_source_names_the_real_subscription() {
        let smart = MarketDataConfig::from_broker(&broker_cfg("SMART"));
        assert_eq!(smart.depth_source(), "ibkr reqMktDepth L2 (SMART)");
        let dma = MarketDataConfig::from_broker(&broker_cfg("ISLAND"));
        assert_eq!(dma.depth_source(), "ibkr reqMktDepth L2 (ISLAND)");
    }

    /// An operator-supplied absurd client id must saturate, not overflow —
    /// release builds abort on panic.
    #[test]
    fn client_id_saturates_instead_of_overflowing() {
        let mut c = broker_cfg("SMART");
        c.ibkr_client_id = i32::MAX;
        assert_eq!(MarketDataConfig::from_broker(&c).client_id, i32::MAX);
    }

    #[test]
    fn throttle_opens_once_then_closes() {
        let mut t = Throttle::new(60_000);
        assert!(t.ready(), "first call always passes");
        assert!(!t.ready(), "second call inside the window is muted");
    }

    #[test]
    fn backoff_grows_and_is_bounded() {
        let mut b = Backoff::new();
        assert_eq!(b.next, BACKOFF_MIN);
        for _ in 0..20 {
            let d = b.next;
            b.next = (b.next * 2).min(BACKOFF_MAX);
            assert!(d <= BACKOFF_MAX);
        }
        assert_eq!(b.next, BACKOFF_MAX, "settles at the ceiling, never unbounded");
        b.reset();
        assert_eq!(b.next, BACKOFF_MIN);
    }
}

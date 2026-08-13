//! cx-oms — order management, realistic paper execution, positions, PnL.
//!
//! Invariants:
//! - Every order lifecycle transition publishes exactly one [`OrderUpdate`];
//!   every fill additionally publishes [`Fill`], [`Position`] and
//!   [`AccountSnapshot`] immediately.
//! - Position accounting is signed average-cost: adds re-weight the basis,
//!   reductions realize `(px - avg_px) * closed_qty * sign(old_qty)`, and a
//!   cross through zero realizes the closed leg fully then opens the residual
//!   at the fill price.
//! - `equity = cash + Σ signed_qty · mark_px`; cash already reflects every
//!   purchase, sale and fee, so no PnL term is double counted.
//! - Tick-driven `Position` events are throttled to one per symbol per 250ms
//!   and `AccountSnapshot` to one per 500ms; fill-driven events never wait.
//! - Reduce-only is enforced at fill time against the LIVE position: a
//!   reduce-only order cancels when there is nothing left to reduce and
//!   clamps to the live quantity otherwise, so it can never flip a position.
//! - All math on network-derived numbers is NaN-safe; the account snapshot is
//!   computable at any instant.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use cx_core::bus::Bus;
use cx_core::config::PaperConfig;
use cx_core::events::{
    AccountSnapshot, EngineEvent, Fill, OrderIntent, OrderSource, OrderStatus, OrderUpdate,
    Position,
};
use cx_core::ids::next_order_id;
use cx_core::portfolio::PortfolioView;
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Liquidity, OrderType, Side, Tif, Venue};
use tokio::sync::broadcast::error::RecvError;
use tokio::task::JoinHandle;

const EPS: f64 = 1e-12;
const POSITION_THROTTLE_MS: i64 = 250;
const ACCOUNT_THROTTLE_MS: i64 = 500;
const FLUSH_TICK_MS: u64 = 100;
const DAY_MS: i64 = 86_400_000;

/// Collapse non-finite input to a fallback — the NaN firewall for every
/// number that ever touched the network.
fn finite_or(x: f64, fallback: f64) -> f64 {
    if x.is_finite() {
        x
    } else {
        fallback
    }
}

/// A stop's trigger test: a BUY stop arms once price rises TO or THROUGH its
/// `stop_px`; a SELL stop once price falls to or through it. A non-finite
/// `price` (a NaN tick) never arms a stop — both comparisons read false.
fn stop_triggered(side: Side, stop_px: f64, price: f64) -> bool {
    match side {
        Side::Buy => price >= stop_px,
        Side::Sell => price <= stop_px,
    }
}

/// Whether a limit is immediately fillable against `price`: a buy limit is
/// marketable at or below its price, a sell limit at or above.
fn limit_marketable(side: Side, limit_px: f64, price: f64) -> bool {
    match side {
        Side::Buy => price <= limit_px,
        Side::Sell => price >= limit_px,
    }
}

#[derive(Debug, Default, Clone)]
struct Pos {
    /// Signed: positive long, negative short. Exactly 0.0 when flat.
    qty: f64,
    avg_px: f64,
    mark_px: f64,
    realized: f64,
}

impl Pos {
    fn unrealized(&self) -> f64 {
        finite_or((self.mark_px - self.avg_px) * self.qty, 0.0)
    }
    /// Signed market value: negative for shorts.
    fn market_value(&self) -> f64 {
        finite_or(self.qty * self.mark_px, 0.0)
    }
    fn event(&self, symbol: &str, ts_ms: i64) -> Position {
        Position {
            symbol: symbol.to_string(),
            qty: self.qty,
            avg_px: self.avg_px,
            mark_px: self.mark_px,
            unrealized_pnl: self.unrealized(),
            realized_pnl: self.realized,
            ts_ms,
        }
    }
}

#[derive(Debug, Clone)]
struct OpenOrder {
    intent: OrderIntent,
    /// `Accepted` while inside the simulated latency window, `Working` once
    /// resting on the book. Anything else leaves the map.
    status: OrderStatus,
    ts_ms: i64,
}

struct Inner {
    cash: f64,
    fees_paid: f64,
    realized_day: f64,
    daily_trades: u32,
    /// UTC day index (unix ms / 86_400_000) the daily clocks belong to.
    utc_day: i64,
    day_peak: f64,
    total_peak: f64,
    positions: HashMap<String, Pos>,
    orders: HashMap<u64, OpenOrder>,
    last_pos_pub: HashMap<String, i64>,
    dirty_pos: HashSet<String>,
    last_acct_pub: i64,
    acct_dirty: bool,
}

/// Order management + paper execution venue. One instance owns all position
/// and account state; everything else observes it via the bus or the sync
/// snapshot accessors.
pub struct Oms {
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    cfg: PaperConfig,
    inner: Mutex<Inner>,
}

impl Oms {
    pub fn new(bus: Arc<Bus>, store: Arc<BarStore>, cfg: PaperConfig) -> Arc<Self> {
        let starting = if cfg.starting_cash.is_finite() && cfg.starting_cash > 0.0 {
            cfg.starting_cash
        } else {
            100_000.0
        };
        Arc::new(Self {
            bus,
            store,
            cfg,
            inner: Mutex::new(Inner {
                cash: starting,
                fees_paid: 0.0,
                realized_day: 0.0,
                daily_trades: 0,
                utc_day: now_ms().div_euclid(DAY_MS),
                day_peak: starting,
                total_peak: starting,
                positions: HashMap::new(),
                orders: HashMap::new(),
                last_pos_pub: HashMap::new(),
                dirty_pos: HashSet::new(),
                last_acct_pub: 0,
                acct_dirty: false,
            }),
        })
    }

    /// Marker task: marks positions to every tick, fills resting limit orders
    /// on crossings, and flushes throttled Position/Account events. The
    /// subscription is taken synchronously so no tick published after this
    /// call returns can be missed.
    pub fn spawn_marker(self: &Arc<Self>) -> JoinHandle<()> {
        let oms = Arc::clone(self);
        let mut rx = self.bus.subscribe();
        tokio::spawn(async move {
            let mut flush = tokio::time::interval(Duration::from_millis(FLUSH_TICK_MS));
            flush.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tokio::select! {
                    ev = rx.recv() => match ev {
                        Ok(ev) => {
                            if let EngineEvent::Tick(t) = ev.as_ref() {
                                oms.on_tick(&t.symbol, t.price);
                            }
                        }
                        Err(RecvError::Lagged(_)) => {}
                        Err(RecvError::Closed) => break,
                    },
                    _ = flush.tick() => oms.flush(),
                }
            }
        })
    }

    /// Accept, wait the simulated latency, then execute. Market orders fill
    /// at last price worsened by slippage (taker); marketable limits fill at
    /// the limit price (taker); non-marketable limits rest for the marker
    /// (IOC limits cancel instead). Returns the order id in every case.
    pub async fn submit(&self, intent: OrderIntent) -> u64 {
        let mut intent = intent;
        if intent.id == 0 {
            intent.id = next_order_id();
        }
        let order_id = intent.id;

        let limit_ok = intent
            .limit_px
            .map(|p| p.is_finite() && p > 0.0)
            .unwrap_or(false);
        let stop_ok = intent
            .stop_px
            .map(|p| p.is_finite() && p > 0.0)
            .unwrap_or(false);
        let base_ok =
            intent.qty.is_finite() && intent.qty > 0.0 && !intent.symbol.is_empty();
        // Reject with the SPECIFIC missing input so the operator learns why:
        // every order type carries exactly the prices it needs — a stop needs
        // a trigger, a limit needs a price, a stop-limit needs both.
        let reject: Option<&str> = if !base_ok {
            Some("invalid order")
        } else {
            match intent.order_type {
                OrderType::Market => None,
                OrderType::Limit => {
                    (!limit_ok).then_some("limit order requires a limit price")
                }
                OrderType::Stop => (!stop_ok).then_some("stop order requires a stop price"),
                OrderType::StopLimit => {
                    if !stop_ok {
                        Some("stop order requires a stop price")
                    } else if !limit_ok {
                        Some("stop-limit order requires a limit price")
                    } else {
                        None
                    }
                }
            }
        };
        if let Some(reason) = reject {
            self.publish_update(
                &intent,
                OrderStatus::Canceled {
                    reason: reason.into(),
                },
            );
            return order_id;
        }

        {
            let mut inner = self.lock();
            inner.orders.insert(
                order_id,
                OpenOrder {
                    intent: intent.clone(),
                    status: OrderStatus::Accepted,
                    ts_ms: now_ms(),
                },
            );
        }
        self.publish_update(&intent, OrderStatus::Accepted);

        if self.cfg.latency_ms > 0 {
            tokio::time::sleep(Duration::from_millis(self.cfg.latency_ms)).await;
        }

        let mut inner = self.lock();
        if !inner.orders.contains_key(&order_id) {
            // Canceled during the simulated latency window.
            return order_id;
        }
        match intent.order_type {
            OrderType::Market => match self.store.last_price(&intent.symbol) {
                Some(last) => {
                    let slip = finite_or(self.cfg.slippage_bps, 0.0).max(0.0);
                    let px = last * (1.0 + intent.side.sign() * slip / 1e4);
                    self.execute_fill(&mut inner, &intent, px, Liquidity::Taker);
                }
                None => {
                    inner.orders.remove(&order_id);
                    drop(inner);
                    self.publish_update(
                        &intent,
                        OrderStatus::Canceled {
                            reason: "no market".into(),
                        },
                    );
                }
            },
            OrderType::Limit => {
                let limit = intent.limit_px.unwrap_or(0.0); // validated above
                let marketable = self
                    .store
                    .last_price(&intent.symbol)
                    .map(|last| match intent.side {
                        Side::Buy => last <= limit,
                        Side::Sell => last >= limit,
                    })
                    .unwrap_or(false);
                if marketable {
                    self.execute_fill(&mut inner, &intent, limit, Liquidity::Taker);
                } else if intent.tif == Tif::Ioc {
                    inner.orders.remove(&order_id);
                    drop(inner);
                    self.publish_update(
                        &intent,
                        OrderStatus::Canceled {
                            reason: "ioc not marketable".into(),
                        },
                    );
                } else {
                    if let Some(o) = inner.orders.get_mut(&order_id) {
                        o.status = OrderStatus::Working;
                    }
                    drop(inner);
                    self.publish_update(&intent, OrderStatus::Working);
                }
            }
            // A stop rests as Working until price reaches its trigger, then
            // fills as a market order. If the market is ALREADY through the
            // trigger at placement (e.g. a buy stop set below the last price),
            // it fires immediately; otherwise the marker watches it per tick.
            OrderType::Stop => {
                let stop = intent.stop_px.unwrap_or(0.0); // validated finite > 0
                let last = self.store.last_price(&intent.symbol);
                if last
                    .map(|l| stop_triggered(intent.side, stop, l))
                    .unwrap_or(false)
                {
                    let last = last.unwrap_or(0.0); // Some by the guard above
                    let slip = finite_or(self.cfg.slippage_bps, 0.0).max(0.0);
                    let px = last * (1.0 + intent.side.sign() * slip / 1e4);
                    self.execute_fill(&mut inner, &intent, px, Liquidity::Taker);
                } else {
                    if let Some(o) = inner.orders.get_mut(&order_id) {
                        o.status = OrderStatus::Working;
                    }
                    drop(inner);
                    self.publish_update(&intent, OrderStatus::Working);
                }
            }
            // A stop-limit becomes a resting LIMIT once triggered: it fills at
            // the limit if the trigger tick is already marketable, otherwise it
            // rests and the marker fills it per limit rules. Until triggered it
            // rests as Working with the marker watching its stop.
            OrderType::StopLimit => {
                let stop = intent.stop_px.unwrap_or(0.0); // validated finite > 0
                let limit = intent.limit_px.unwrap_or(0.0); // validated finite > 0
                let last = self.store.last_price(&intent.symbol);
                if last
                    .map(|l| stop_triggered(intent.side, stop, l))
                    .unwrap_or(false)
                {
                    let last = last.unwrap_or(0.0); // Some by the guard above
                    if limit_marketable(intent.side, limit, last) {
                        self.execute_fill(&mut inner, &intent, limit, Liquidity::Taker);
                    } else if intent.tif == Tif::Ioc {
                        inner.orders.remove(&order_id);
                        drop(inner);
                        self.publish_update(
                            &intent,
                            OrderStatus::Canceled {
                                reason: "ioc not marketable".into(),
                            },
                        );
                    } else {
                        // Triggered but through the limit: rest as a plain
                        // limit for the marker to fill per limit rules.
                        intent.order_type = OrderType::Limit;
                        if let Some(o) = inner.orders.get_mut(&order_id) {
                            o.intent.order_type = OrderType::Limit;
                            o.status = OrderStatus::Working;
                        }
                        drop(inner);
                        self.publish_update(&intent, OrderStatus::Working);
                    }
                } else {
                    if let Some(o) = inner.orders.get_mut(&order_id) {
                        o.status = OrderStatus::Working;
                    }
                    drop(inner);
                    self.publish_update(&intent, OrderStatus::Working);
                }
            }
        }
        order_id
    }

    /// Cancels an order still Accepted (in the latency window) or Working
    /// (resting). Returns false for unknown or already-terminal orders.
    pub async fn cancel(&self, order_id: u64, reason: &str) -> bool {
        let removed = {
            let mut inner = self.lock();
            match inner.orders.get(&order_id) {
                Some(o) if matches!(o.status, OrderStatus::Accepted | OrderStatus::Working) => {
                    inner.orders.remove(&order_id)
                }
                _ => None,
            }
        };
        match removed {
            Some(o) => {
                self.publish_update(
                    &o.intent,
                    OrderStatus::Canceled {
                        reason: reason.to_string(),
                    },
                );
                true
            }
            None => false,
        }
    }

    /// Emergency exit: cancels every open order, then submits one reduce-only
    /// market order per nonzero position (source `RiskFlatten`). Returns the
    /// flatten order ids.
    pub async fn flatten_all(&self, reason: &str) -> Vec<u64> {
        let (to_cancel, to_flatten) = {
            let inner = self.lock();
            let cancels: Vec<u64> = inner.orders.keys().copied().collect();
            let flats: Vec<(String, f64)> = inner
                .positions
                .iter()
                .filter(|(_, p)| p.qty.abs() > EPS)
                .map(|(s, p)| (s.clone(), p.qty))
                .collect();
            (cancels, flats)
        };
        for id in to_cancel {
            let _ = self.cancel(id, reason).await;
        }
        let mut ids = Vec::with_capacity(to_flatten.len());
        for (symbol, qty) in to_flatten {
            let intent = OrderIntent {
                id: next_order_id(),
                symbol,
                side: if qty > 0.0 { Side::Sell } else { Side::Buy },
                qty: qty.abs(),
                order_type: OrderType::Market,
                limit_px: None,
                stop_px: None,
                tif: Tif::Ioc,
                reduce_only: true,
                source: OrderSource::RiskFlatten,
                rationale: reason.to_string(),
                ts_ms: now_ms(),
            };
            ids.push(self.submit(intent).await);
        }
        ids
    }

    /// Read-only snapshot handed INTO risk checks.
    pub fn view(&self) -> PortfolioView {
        let mut inner = self.lock();
        Self::roll_day(&mut inner, now_ms());
        let equity = Self::equity_of(&inner);
        let gross: f64 = inner
            .positions
            .values()
            .map(|p| p.market_value().abs())
            .sum();
        PortfolioView {
            equity,
            cash: inner.cash,
            gross_exposure: gross,
            positions: inner
                .positions
                .iter()
                .filter(|(_, p)| p.qty.abs() > EPS)
                .map(|(s, p)| (s.clone(), (p.qty, p.mark_px)))
                .collect(),
            open_orders: inner.orders.len() as u32,
            daily_trades: inner.daily_trades,
        }
    }

    pub fn account(&self) -> AccountSnapshot {
        let mut inner = self.lock();
        self.snapshot_locked(&mut inner, now_ms())
    }

    /// Every tracked position (flat ones keep their realized PnL visible),
    /// sorted by symbol for deterministic output.
    pub fn positions(&self) -> Vec<Position> {
        let inner = self.lock();
        let ts = now_ms();
        let mut v: Vec<Position> = inner
            .positions
            .iter()
            .map(|(s, p)| p.event(s, ts))
            .collect();
        v.sort_by(|a, b| a.symbol.cmp(&b.symbol));
        v
    }

    /// Live snapshot of one tracked position, if any (flat entries are
    /// still returned while they carry realized PnL).
    pub fn position(&self, symbol: &str) -> Option<Position> {
        let inner = self.lock();
        inner
            .positions
            .get(symbol)
            .map(|p| p.event(symbol, now_ms()))
    }

    /// Orders still Accepted or Working, sorted by order id.
    pub fn open_orders(&self) -> Vec<OrderUpdate> {
        let inner = self.lock();
        let mut v: Vec<OrderUpdate> = inner
            .orders
            .iter()
            .map(|(id, o)| OrderUpdate {
                order_id: *id,
                intent: o.intent.clone(),
                status: o.status.clone(),
                filled_qty: 0.0,
                avg_fill_px: 0.0,
                ts_ms: o.ts_ms,
            })
            .collect();
        v.sort_by_key(|u| u.order_id);
        v
    }

    // ---- internals ----------------------------------------------------

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn publish_update(&self, intent: &OrderIntent, status: OrderStatus) {
        self.bus.publish(EngineEvent::OrderUpdate(OrderUpdate {
            order_id: intent.id,
            intent: intent.clone(),
            status,
            filled_qty: 0.0,
            avg_fill_px: 0.0,
            ts_ms: now_ms(),
        }));
    }

    fn equity_of(inner: &Inner) -> f64 {
        let mv: f64 = inner.positions.values().map(Pos::market_value).sum();
        finite_or(inner.cash + mv, inner.cash)
    }

    /// Daily clocks reset exactly once per UTC day change.
    fn roll_day(inner: &mut Inner, ts_ms: i64) {
        let day = ts_ms.div_euclid(DAY_MS);
        if day != inner.utc_day {
            inner.utc_day = day;
            inner.daily_trades = 0;
            inner.realized_day = 0.0;
            inner.day_peak = Self::equity_of(inner);
        }
    }

    fn snapshot_locked(&self, inner: &mut Inner, ts_ms: i64) -> AccountSnapshot {
        Self::roll_day(inner, ts_ms);
        let equity = Self::equity_of(inner);
        if equity > inner.day_peak {
            inner.day_peak = equity;
        }
        if equity > inner.total_peak {
            inner.total_peak = equity;
        }
        let gross: f64 = inner
            .positions
            .values()
            .map(|p| p.market_value().abs())
            .sum();
        let net: f64 = inner.positions.values().map(Pos::market_value).sum();
        let unrealized: f64 = inner.positions.values().map(Pos::unrealized).sum();
        let dd = |peak: f64| {
            if peak > EPS {
                finite_or((peak - equity) / peak, 0.0).clamp(0.0, 1.0)
            } else {
                0.0
            }
        };
        AccountSnapshot {
            equity,
            cash: inner.cash,
            gross_exposure: gross,
            net_exposure: net,
            unrealized_pnl: unrealized,
            realized_pnl_day: inner.realized_day,
            fees_paid: inner.fees_paid,
            open_orders: inner.orders.len() as u32,
            daily_trades: inner.daily_trades,
            drawdown_day: dd(inner.day_peak),
            drawdown_total: dd(inner.total_peak),
            ts_ms,
        }
    }

    /// Full fill at `px`: signed average-cost position math, cash and fee
    /// accounting, then the immediate OrderUpdate/Fill/Position/Account
    /// publishes. Caller guarantees `px` finite > 0 and `qty` finite > 0.
    ///
    /// Reduce-only is enforced HERE, at the single fill choke point: the
    /// LIVE position is re-checked under the lock, because racing closes
    /// (e.g. ATR trail vs flatten/manual) can each pass submit-time checks
    /// during the latency window. A reduce-only order cancels when there is
    /// nothing left to reduce and clamps to the live quantity otherwise, so
    /// a reduce-only fill can never flip a position's sign.
    fn execute_fill(&self, inner: &mut Inner, intent: &OrderIntent, px: f64, liquidity: Liquidity) {
        let ts = now_ms();
        Self::roll_day(inner, ts);
        let sign = intent.side.sign();
        let qty = if intent.reduce_only {
            let live = inner
                .positions
                .get(&intent.symbol)
                .map(|p| p.qty)
                .unwrap_or(0.0);
            if live.abs() < EPS || (live > 0.0) == (sign > 0.0) {
                // Flat, or the order points WITH the position: filling
                // would open/extend, which reduce-only forbids.
                inner.orders.remove(&intent.id);
                self.publish_update(
                    intent,
                    OrderStatus::Canceled {
                        reason: "reduce-only: nothing to reduce".into(),
                    },
                );
                return;
            }
            intent.qty.min(live.abs())
        } else {
            intent.qty
        };
        let fee_bps = match liquidity {
            Liquidity::Maker => self.cfg.maker_fee_bps,
            Liquidity::Taker => self.cfg.taker_fee_bps,
        };
        let fee = (qty * px).abs() * finite_or(fee_bps, 0.0).max(0.0) / 1e4;

        let (pos_ev, realized) = {
            let pos = inner.positions.entry(intent.symbol.clone()).or_default();
            if pos.qty.abs() < EPS {
                pos.qty = 0.0;
            }
            let realized = if pos.qty == 0.0 || (pos.qty > 0.0) == (sign > 0.0) {
                // Opening or adding: re-weight the average cost basis.
                pos.avg_px = (pos.qty.abs() * pos.avg_px + qty * px) / (pos.qty.abs() + qty);
                pos.qty += sign * qty;
                0.0
            } else {
                // Reducing (possibly through zero): realize the closed leg.
                let closed = qty.min(pos.qty.abs());
                let r = (px - pos.avg_px) * closed * pos.qty.signum();
                let new_qty = pos.qty + sign * qty;
                if new_qty.abs() < EPS {
                    pos.qty = 0.0;
                    pos.avg_px = 0.0;
                } else if (new_qty > 0.0) != (pos.qty > 0.0) {
                    // Crossed zero: residual opens at the fill price.
                    pos.qty = new_qty;
                    pos.avg_px = px;
                } else {
                    pos.qty = new_qty;
                }
                r
            };
            pos.realized += realized;
            pos.mark_px = px;
            (pos.event(&intent.symbol, ts), realized)
        };

        inner.cash -= sign * qty * px + fee;
        inner.fees_paid += fee;
        inner.realized_day += realized;
        inner.daily_trades += 1;
        inner.orders.remove(&intent.id);
        inner.last_pos_pub.insert(intent.symbol.clone(), ts);
        inner.dirty_pos.remove(&intent.symbol);

        self.bus.publish(EngineEvent::OrderUpdate(OrderUpdate {
            order_id: intent.id,
            intent: intent.clone(),
            status: OrderStatus::Filled,
            filled_qty: qty,
            avg_fill_px: px,
            ts_ms: ts,
        }));
        self.bus.publish(EngineEvent::Fill(Fill {
            order_id: intent.id,
            symbol: intent.symbol.clone(),
            side: intent.side,
            qty,
            px,
            fee,
            liquidity,
            venue: Venue::Paper,
            ts_ms: ts,
        }));
        self.bus.publish(EngineEvent::Position(pos_ev));
        let snap = self.snapshot_locked(inner, ts);
        inner.last_acct_pub = ts;
        inner.acct_dirty = false;
        self.bus.publish(EngineEvent::Account(snap));
    }

    /// Marker path for one tick: fill crossed resting limits (maker), then
    /// re-mark the position, throttling tick-driven Position events.
    fn on_tick(&self, symbol: &str, price: f64) {
        if !(price.is_finite() && price > 0.0) {
            return;
        }
        let mut inner = self.lock();
        let now = now_ms();
        Self::roll_day(&mut inner, now);

        // 1. Working stops whose trigger this tick reaches. A triggered Stop
        //    fills as a market taker at the tick; a triggered StopLimit fills
        //    at its limit when the tick is already marketable, else converts
        //    to a resting limit that later ticks fill per limit rules.
        let triggered: Vec<u64> = inner
            .orders
            .iter()
            .filter(|(_, o)| {
                matches!(o.status, OrderStatus::Working)
                    && o.intent.symbol == symbol
                    && matches!(o.intent.order_type, OrderType::Stop | OrderType::StopLimit)
                    && o.intent
                        .stop_px
                        .map(|s| stop_triggered(o.intent.side, s, price))
                        .unwrap_or(false)
            })
            .map(|(id, _)| *id)
            .collect();
        for id in triggered {
            let Some(intent) = inner.orders.get(&id).map(|o| o.intent.clone()) else {
                continue;
            };
            match intent.order_type {
                OrderType::StopLimit => {
                    let limit = intent.limit_px.unwrap_or(0.0);
                    if limit_marketable(intent.side, limit, price) {
                        self.execute_fill(&mut inner, &intent, limit, Liquidity::Taker);
                    } else if let Some(o) = inner.orders.get_mut(&id) {
                        // Rest as a plain limit; future ticks fill it per the
                        // crossed-limit pass below.
                        o.intent.order_type = OrderType::Limit;
                    }
                }
                // Stop fills as a market taker at the tick, worsened by slippage.
                _ => {
                    let slip = finite_or(self.cfg.slippage_bps, 0.0).max(0.0);
                    let px = price * (1.0 + intent.side.sign() * slip / 1e4);
                    self.execute_fill(&mut inner, &intent, px, Liquidity::Taker);
                }
            }
        }

        // 2. Resting limits (including stop-limits that have converted) whose
        //    price this tick crosses fill at the limit as maker. Un-triggered
        //    stop-limits are excluded here by the `Limit`-only guard so they
        //    never fill before their stop arms.
        let crossed: Vec<OrderIntent> = inner
            .orders
            .values()
            .filter(|o| {
                matches!(o.status, OrderStatus::Working)
                    && o.intent.symbol == symbol
                    && matches!(o.intent.order_type, OrderType::Limit)
            })
            .filter(|o| match (o.intent.side, o.intent.limit_px) {
                (Side::Buy, Some(l)) => price <= l,
                (Side::Sell, Some(l)) => price >= l,
                _ => false,
            })
            .map(|o| o.intent.clone())
            .collect();
        for intent in crossed {
            let px = intent.limit_px.unwrap_or(price); // Working limits always carry a price
            self.execute_fill(&mut inner, &intent, px, Liquidity::Maker);
        }

        let pos_ev = match inner.positions.get_mut(symbol) {
            Some(pos) if pos.qty.abs() > EPS && pos.mark_px != price => {
                pos.mark_px = price;
                Some(pos.event(symbol, now))
            }
            _ => None,
        };
        if let Some(ev) = pos_ev {
            inner.acct_dirty = true;
            let last = inner.last_pos_pub.get(symbol).copied().unwrap_or(0);
            if now - last >= POSITION_THROTTLE_MS {
                inner.last_pos_pub.insert(symbol.to_string(), now);
                inner.dirty_pos.remove(symbol);
                self.bus.publish(EngineEvent::Position(ev));
            } else {
                inner.dirty_pos.insert(symbol.to_string());
            }
        }
    }

    /// Trailing-edge flush so the final mark of a burst is never lost.
    fn flush(&self) {
        let mut inner = self.lock();
        let now = now_ms();
        Self::roll_day(&mut inner, now);
        let due: Vec<String> = inner
            .dirty_pos
            .iter()
            .filter(|s| {
                now - inner.last_pos_pub.get(s.as_str()).copied().unwrap_or(0)
                    >= POSITION_THROTTLE_MS
            })
            .cloned()
            .collect();
        for s in due {
            inner.dirty_pos.remove(&s);
            inner.last_pos_pub.insert(s.clone(), now);
            if let Some(p) = inner.positions.get(&s) {
                let ev = p.event(&s, now);
                self.bus.publish(EngineEvent::Position(ev));
            }
        }
        if inner.acct_dirty && now - inner.last_acct_pub >= ACCOUNT_THROTTLE_MS {
            let snap = self.snapshot_locked(&mut inner, now);
            inner.acct_dirty = false;
            inner.last_acct_pub = now;
            self.bus.publish(EngineEvent::Account(snap));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::bus::BusEvent;
    use cx_core::events::Tick;
    use tokio::sync::broadcast;

    fn cfg(latency: u64, slip_bps: f64, taker_bps: f64, maker_bps: f64) -> PaperConfig {
        PaperConfig {
            starting_cash: 100_000.0,
            maker_fee_bps: maker_bps,
            taker_fee_bps: taker_bps,
            latency_ms: latency,
            slippage_bps: slip_bps,
        }
    }

    fn intent(
        symbol: &str,
        side: Side,
        qty: f64,
        order_type: OrderType,
        limit_px: Option<f64>,
    ) -> OrderIntent {
        OrderIntent {
            id: 0,
            symbol: symbol.into(),
            side,
            qty,
            order_type,
            limit_px,
            stop_px: None,
            tif: Tif::Gtc,
            reduce_only: false,
            source: OrderSource::Manual,
            rationale: "test".into(),
            ts_ms: now_ms(),
        }
    }

    fn close_intent(symbol: &str, side: Side, qty: f64) -> OrderIntent {
        let mut i = intent(symbol, side, qty, OrderType::Market, None);
        i.reduce_only = true;
        i
    }

    /// A stop / stop-limit order intent. `limit_px` is None for a plain stop.
    fn stop_intent(
        symbol: &str,
        side: Side,
        qty: f64,
        order_type: OrderType,
        stop_px: Option<f64>,
        limit_px: Option<f64>,
    ) -> OrderIntent {
        OrderIntent {
            id: 0,
            symbol: symbol.into(),
            side,
            qty,
            order_type,
            limit_px,
            stop_px,
            tif: Tif::Gtc,
            reduce_only: false,
            source: OrderSource::Manual,
            rationale: "test stop".into(),
            ts_ms: now_ms(),
        }
    }

    fn setup(cfg: PaperConfig) -> (Arc<Bus>, Arc<BarStore>, Arc<Oms>) {
        let bus = Bus::new(1024);
        let store = Arc::new(BarStore::new());
        let oms = Oms::new(bus.clone(), store.clone(), cfg);
        (bus, store, oms)
    }

    async fn next_update_for(
        rx: &mut broadcast::Receiver<BusEvent>,
        order_id: u64,
    ) -> OrderUpdate {
        loop {
            let ev = tokio::time::timeout(Duration::from_secs(2), rx.recv())
                .await
                .expect("timed out waiting for order update")
                .expect("bus closed");
            if let EngineEvent::OrderUpdate(u) = ev.as_ref() {
                if u.order_id == order_id {
                    return u.clone();
                }
            }
        }
    }

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "expected {b}, got {a}");
    }

    #[tokio::test]
    async fn long_round_trip_realized_pnl_and_fees_exact() {
        let (_bus, store, oms) = setup(cfg(0, 10.0, 10.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        oms.submit(intent("BTC-USD", Side::Buy, 2.0, OrderType::Market, None))
            .await;
        store.set_last_price_untracked("BTC-USD", 110.0);
        oms.submit(intent("BTC-USD", Side::Sell, 2.0, OrderType::Market, None))
            .await;

        let buy_px = 100.0 * (1.0 + 10.0 / 1e4);
        let sell_px = 110.0 * (1.0 - 10.0 / 1e4);
        let buy_fee = 2.0 * buy_px * 10.0 / 1e4;
        let sell_fee = 2.0 * sell_px * 10.0 / 1e4;
        let realized = (sell_px - buy_px) * 2.0;

        let positions = oms.positions();
        assert_eq!(positions.len(), 1);
        approx(positions[0].qty, 0.0);
        approx(positions[0].realized_pnl, realized);

        let acct = oms.account();
        approx(acct.fees_paid, buy_fee + sell_fee);
        approx(acct.realized_pnl_day, realized);
        approx(
            acct.cash,
            100_000.0 - 2.0 * buy_px - buy_fee + 2.0 * sell_px - sell_fee,
        );
        approx(acct.equity, acct.cash); // flat -> equity is pure cash
        assert_eq!(acct.daily_trades, 2);
        assert_eq!(acct.open_orders, 0);
    }

    #[tokio::test]
    async fn short_round_trip_symmetric() {
        let (_bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("ETH-USD", 50.0);
        oms.submit(intent("ETH-USD", Side::Sell, 3.0, OrderType::Market, None))
            .await;

        // Short at entry: equity unchanged (cash up, negative MV down).
        let acct = oms.account();
        approx(acct.cash, 100_150.0);
        approx(acct.net_exposure, -150.0);
        approx(acct.gross_exposure, 150.0);
        approx(acct.equity, 100_000.0);

        store.set_last_price_untracked("ETH-USD", 45.0);
        oms.submit(intent("ETH-USD", Side::Buy, 3.0, OrderType::Market, None))
            .await;
        let acct = oms.account();
        approx(acct.realized_pnl_day, (50.0 - 45.0) * 3.0);
        approx(acct.cash, 100_015.0);
        approx(acct.equity, 100_015.0);
    }

    #[tokio::test]
    async fn average_cost_weights_adds() {
        let (_bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Market, None))
            .await;
        approx(oms.account().equity, 100_000.0); // buy at mark moves no equity
        store.set_last_price_untracked("BTC-USD", 110.0);
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Market, None))
            .await;

        let positions = oms.positions();
        approx(positions[0].qty, 2.0);
        approx(positions[0].avg_px, 105.0);
        approx(positions[0].mark_px, 110.0);
        approx(positions[0].unrealized_pnl, 10.0);
        approx(positions[0].realized_pnl, 0.0);
    }

    #[tokio::test]
    async fn cross_through_zero_realizes_then_reopens() {
        let (_bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("SOL-USD", 100.0);
        oms.submit(intent("SOL-USD", Side::Buy, 2.0, OrderType::Market, None))
            .await;
        store.set_last_price_untracked("SOL-USD", 120.0);
        oms.submit(intent("SOL-USD", Side::Sell, 5.0, OrderType::Market, None))
            .await;

        let positions = oms.positions();
        approx(positions[0].qty, -3.0);
        approx(positions[0].avg_px, 120.0); // residual short opened at fill
        approx(positions[0].realized_pnl, (120.0 - 100.0) * 2.0);
        approx(positions[0].unrealized_pnl, 0.0);
    }

    #[tokio::test]
    async fn resting_limit_fills_on_crossing_tick_via_marker() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 5.0, 2.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let _marker = oms.spawn_marker();
        let mut rx = bus.subscribe();

        // last=100, buy limit 95 -> not marketable -> rests Working.
        let id = oms
            .submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Limit, Some(95.0)))
            .await;
        assert_eq!(oms.open_orders().len(), 1);
        assert!(matches!(
            oms.open_orders()[0].status,
            OrderStatus::Working
        ));

        bus.publish(EngineEvent::Tick(Tick {
            symbol: "BTC-USD".into(),
            ts_ms: now_ms(),
            price: 94.0,
            size: 0.5,
            aggressor: None,
            venue: Venue::Paper,
        }));

        // Full lifecycle on the bus: Accepted -> Working -> Filled.
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Accepted));
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Working));
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Filled));
        approx(update.avg_fill_px, 95.0); // limit price, not tick price
        approx(update.filled_qty, 1.0);

        let positions = oms.positions();
        approx(positions[0].qty, 1.0);
        approx(positions[0].avg_px, 95.0);
        approx(oms.account().fees_paid, 95.0 * 2.0 / 1e4); // maker fee
        assert!(oms.open_orders().is_empty());
    }

    #[tokio::test]
    async fn marketable_limit_fills_immediately_at_limit_as_taker() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 5.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let mut rx = bus.subscribe();
        let id = oms
            .submit(intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::Limit,
                Some(101.0),
            ))
            .await;
        // Accepted then Filled, no Working.
        let first = next_update_for(&mut rx, id).await;
        assert!(matches!(first.status, OrderStatus::Accepted));
        let second = next_update_for(&mut rx, id).await;
        assert!(matches!(second.status, OrderStatus::Filled));
        approx(second.avg_fill_px, 101.0);
        approx(oms.account().fees_paid, 101.0 * 5.0 / 1e4);
    }

    #[tokio::test]
    async fn market_without_last_price_cancels() {
        let (bus, _store, oms) = setup(cfg(0, 0.0, 5.0, 0.0));
        let mut rx = bus.subscribe();
        let id = oms
            .submit(intent("NOPE-USD", Side::Buy, 1.0, OrderType::Market, None))
            .await;
        let first = next_update_for(&mut rx, id).await;
        assert!(matches!(first.status, OrderStatus::Accepted));
        let second = next_update_for(&mut rx, id).await;
        match &second.status {
            OrderStatus::Canceled { reason } => assert_eq!(reason, "no market"),
            other => panic!("expected cancel, got {other:?}"),
        }
        assert!(oms.open_orders().is_empty());
        approx(oms.account().cash, 100_000.0);
    }

    #[tokio::test]
    async fn invalid_order_is_nan_safe_and_cancels() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 5.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let mut rx = bus.subscribe();
        let id = oms
            .submit(intent("BTC-USD", Side::Buy, f64::NAN, OrderType::Market, None))
            .await;
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Canceled { .. }));
        let id = oms
            .submit(intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::Limit,
                Some(f64::INFINITY),
            ))
            .await;
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Canceled { .. }));
        assert_eq!(oms.account().daily_trades, 0);
        approx(oms.account().cash, 100_000.0);
    }

    #[tokio::test]
    async fn cancel_only_hits_resting_or_working() {
        let (_bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let id = oms
            .submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Limit, Some(90.0)))
            .await;
        assert!(oms.cancel(id, "operator").await);
        assert!(oms.open_orders().is_empty());
        assert!(!oms.cancel(id, "again").await); // already terminal
        assert!(!oms.cancel(999_999, "unknown").await);
    }

    #[tokio::test]
    async fn flatten_all_closes_everything() {
        let (_bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        store.set_last_price_untracked("ETH-USD", 50.0);
        oms.submit(intent("BTC-USD", Side::Buy, 2.0, OrderType::Market, None))
            .await;
        oms.submit(intent("ETH-USD", Side::Sell, 4.0, OrderType::Market, None))
            .await;
        // A resting order that must not survive the flatten.
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Limit, Some(90.0)))
            .await;

        let ids = oms.flatten_all("risk halt").await;
        assert_eq!(ids.len(), 2);
        for p in oms.positions() {
            approx(p.qty, 0.0);
        }
        assert!(oms.open_orders().is_empty());
        assert_eq!(oms.view().open_position_count(), 0);
        approx(oms.account().equity, 100_000.0); // zero-fee round trips at flat prices
    }

    #[tokio::test]
    async fn daily_trade_counter_counts_fills_not_orders() {
        let (_bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Market, None))
            .await;
        assert_eq!(oms.account().daily_trades, 1);
        // Resting limit: an order, not a fill.
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Limit, Some(90.0)))
            .await;
        assert_eq!(oms.account().daily_trades, 1);
        oms.submit(intent("BTC-USD", Side::Sell, 1.0, OrderType::Market, None))
            .await;
        assert_eq!(oms.account().daily_trades, 2);
    }

    #[tokio::test]
    async fn marker_marks_positions_and_view_reflects_it() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let _marker = oms.spawn_marker();
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Market, None))
            .await;
        let mut rx = bus.subscribe();
        bus.publish(EngineEvent::Tick(Tick {
            symbol: "BTC-USD".into(),
            ts_ms: now_ms(),
            price: 130.0,
            size: 1.0,
            aggressor: Some(Side::Buy),
            venue: Venue::Paper,
        }));
        // Wait until the marker has consumed the tick (mark visible).
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            if oms.positions()[0].mark_px == 130.0 {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline, "mark never updated");
            let _ = tokio::time::timeout(Duration::from_millis(50), rx.recv()).await;
        }
        approx(oms.positions()[0].unrealized_pnl, 30.0);
        approx(oms.account().equity, 100_030.0);
        let view = oms.view();
        approx(view.position_notional("BTC-USD"), 130.0);
        // NaN-hostile tick must be ignored.
        bus.publish(EngineEvent::Tick(Tick {
            symbol: "BTC-USD".into(),
            ts_ms: now_ms(),
            price: f64::NAN,
            size: 1.0,
            aggressor: None,
            venue: Venue::Paper,
        }));
        tokio::time::sleep(Duration::from_millis(50)).await;
        approx(oms.positions()[0].mark_px, 130.0);
    }

    #[tokio::test]
    async fn racing_reduce_only_closes_fill_once_and_cancel_once() {
        let (bus, store, oms) = setup(cfg(50, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        oms.submit(intent("BTC-USD", Side::Buy, 2.0, OrderType::Market, None))
            .await;

        // Two full closes overlap inside the latency window (submit
        // releases the lock before the sleep): ATR trail vs flatten.
        let mut rx = bus.subscribe();
        let a = tokio::spawn({
            let oms = Arc::clone(&oms);
            async move { oms.submit(close_intent("BTC-USD", Side::Sell, 2.0)).await }
        });
        let b = tokio::spawn({
            let oms = Arc::clone(&oms);
            async move { oms.submit(close_intent("BTC-USD", Side::Sell, 2.0)).await }
        });
        let ids = [a.await.expect("join"), b.await.expect("join")];

        let mut filled = 0;
        let mut canceled = 0;
        while let Ok(ev) = rx.try_recv() {
            if let EngineEvent::OrderUpdate(u) = ev.as_ref() {
                if !ids.contains(&u.order_id) {
                    continue;
                }
                match &u.status {
                    OrderStatus::Filled => {
                        filled += 1;
                        approx(u.filled_qty, 2.0);
                    }
                    OrderStatus::Canceled { reason } => {
                        canceled += 1;
                        assert_eq!(reason, "reduce-only: nothing to reduce");
                    }
                    _ => {}
                }
            }
        }
        assert_eq!(filled, 1, "exactly one close fills");
        assert_eq!(canceled, 1, "the loser cancels instead of flipping");
        approx(oms.positions()[0].qty, 0.0); // flat, NEVER short
        assert_eq!(oms.account().daily_trades, 2); // entry + one close
    }

    #[tokio::test]
    async fn racing_partial_reduce_only_closes_clamp_and_never_flip() {
        let (bus, store, oms) = setup(cfg(50, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        oms.submit(intent("BTC-USD", Side::Buy, 2.0, OrderType::Market, None))
            .await;

        let mut rx = bus.subscribe();
        let a = tokio::spawn({
            let oms = Arc::clone(&oms);
            async move { oms.submit(close_intent("BTC-USD", Side::Sell, 1.5)).await }
        });
        let b = tokio::spawn({
            let oms = Arc::clone(&oms);
            async move { oms.submit(close_intent("BTC-USD", Side::Sell, 1.5)).await }
        });
        let ids = [a.await.expect("join"), b.await.expect("join")];

        // 1.5 + 1.5 > 2.0 held: the loser clamps to the residual 0.5 so
        // the position lands exactly flat instead of flipping short.
        let mut fills: Vec<f64> = Vec::new();
        while let Ok(ev) = rx.try_recv() {
            if let EngineEvent::OrderUpdate(u) = ev.as_ref() {
                if ids.contains(&u.order_id) && matches!(u.status, OrderStatus::Filled) {
                    fills.push(u.filled_qty);
                }
            }
        }
        fills.sort_by(|x, y| x.partial_cmp(y).expect("finite"));
        assert_eq!(fills.len(), 2);
        approx(fills[0], 0.5);
        approx(fills[1], 1.5);
        approx(oms.positions()[0].qty, 0.0); // sign never flipped
    }

    #[tokio::test]
    async fn reduce_only_cancels_when_flat_or_same_side() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let mut rx = bus.subscribe();

        // Flat book: nothing to reduce.
        let id = oms.submit(close_intent("BTC-USD", Side::Sell, 1.0)).await;
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Accepted));
        let update = next_update_for(&mut rx, id).await;
        match &update.status {
            OrderStatus::Canceled { reason } => {
                assert_eq!(reason, "reduce-only: nothing to reduce")
            }
            other => panic!("expected cancel, got {other:?}"),
        }

        // Long book + reduce-only BUY points WITH the position.
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Market, None))
            .await;
        let id = oms.submit(close_intent("BTC-USD", Side::Buy, 1.0)).await;
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Accepted));
        let update = next_update_for(&mut rx, id).await;
        assert!(matches!(update.status, OrderStatus::Canceled { .. }));
        approx(oms.positions()[0].qty, 1.0); // untouched
        assert_eq!(oms.account().daily_trades, 1);
    }

    #[tokio::test]
    async fn cancel_during_latency_window_prevents_execution() {
        let (_bus, store, oms) = setup(cfg(150, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let oms2 = Arc::clone(&oms);
        let submit = tokio::spawn(async move {
            oms2.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Market, None))
                .await
        });
        tokio::time::sleep(Duration::from_millis(30)).await;
        let id = oms.open_orders().first().map(|o| o.order_id).expect("accepted");
        assert!(oms.cancel(id, "changed my mind").await);
        let returned = submit.await.expect("join");
        assert_eq!(returned, id);
        assert!(oms.positions().is_empty());
        approx(oms.account().cash, 100_000.0);
        assert_eq!(oms.account().daily_trades, 0);
    }

    fn tick(symbol: &str, price: f64) -> EngineEvent {
        EngineEvent::Tick(Tick {
            symbol: symbol.into(),
            ts_ms: now_ms(),
            price,
            size: 1.0,
            aggressor: None,
            venue: Venue::Paper,
        })
    }

    #[tokio::test]
    async fn buy_stop_triggers_only_at_or_above_stop_then_fills() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let _marker = oms.spawn_marker();
        let mut rx = bus.subscribe();

        // Buy stop at 105 with last 100 -> not yet triggered -> rests Working.
        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::Stop,
                Some(105.0),
                None,
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Working));
        assert_eq!(oms.open_orders().len(), 1);

        // A tick BELOW the trigger must not fill.
        bus.publish(tick("BTC-USD", 104.0));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(matches!(oms.open_orders()[0].status, OrderStatus::Working));
        assert!(oms.positions().is_empty());

        // A tick AT the trigger fills as a market taker at the tick price.
        bus.publish(tick("BTC-USD", 105.0));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Filled));
        approx(u.avg_fill_px, 105.0);
        approx(u.filled_qty, 1.0);
        approx(oms.positions()[0].qty, 1.0);
        approx(oms.positions()[0].avg_px, 105.0);
        assert_eq!(oms.account().daily_trades, 1);
        assert!(oms.open_orders().is_empty());
    }

    #[tokio::test]
    async fn sell_stop_triggers_only_at_or_below_stop_then_fills() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("ETH-USD", 100.0);
        let _marker = oms.spawn_marker();
        let mut rx = bus.subscribe();

        // Sell stop at 95 with last 100 -> a stop BELOW the current price does
        // NOT fire immediately (a sell stop arms only as price falls to it).
        let id = oms
            .submit(stop_intent(
                "ETH-USD",
                Side::Sell,
                2.0,
                OrderType::Stop,
                Some(95.0),
                None,
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Working));

        // A tick ABOVE the trigger must not fill.
        bus.publish(tick("ETH-USD", 96.0));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(matches!(oms.open_orders()[0].status, OrderStatus::Working));
        assert!(oms.positions().is_empty());

        // A tick at the trigger fills; the short opens at the tick price.
        bus.publish(tick("ETH-USD", 95.0));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Filled));
        approx(u.avg_fill_px, 95.0);
        approx(oms.positions()[0].qty, -2.0);
        approx(oms.positions()[0].avg_px, 95.0);
    }

    #[tokio::test]
    async fn stop_through_market_at_placement_fills_immediately() {
        // Both sides: a BUY stop set BELOW last (last >= stop) and a SELL stop
        // set ABOVE last (last <= stop) are already through their trigger, so
        // they fire at placement without waiting for a tick.
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let mut rx = bus.subscribe();

        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::Stop,
                Some(90.0),
                None,
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Filled)); // no Working — immediate
        approx(u.avg_fill_px, 100.0);
        approx(oms.positions()[0].qty, 1.0);

        store.set_last_price_untracked("SOL-USD", 50.0);
        let id = oms
            .submit(stop_intent(
                "SOL-USD",
                Side::Sell,
                1.0,
                OrderType::Stop,
                Some(60.0),
                None,
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Filled));
        approx(u.avg_fill_px, 50.0);
        approx(oms.position("SOL-USD").unwrap().qty, -1.0);
    }

    #[tokio::test]
    async fn stop_limit_becomes_resting_limit_and_fills_per_limit_rules() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 5.0, 2.0));
        store.set_last_price_untracked("BTC-USD", 95.0);
        let _marker = oms.spawn_marker();
        let mut rx = bus.subscribe();

        // Buy stop-limit: stop 100, limit 99 (limit BELOW the stop). Last 95
        // -> rests as a working stop-limit.
        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::StopLimit,
                Some(100.0),
                Some(99.0),
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Working));

        // Tick to 100 arms the stop, but 100 is THROUGH the 99 limit (not
        // marketable): it converts to a resting limit and does not fill.
        bus.publish(tick("BTC-USD", 100.0));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(oms.open_orders().len(), 1);
        assert!(matches!(oms.open_orders()[0].status, OrderStatus::Working));
        assert!(oms.positions().is_empty());

        // Price falls to the limit -> fills at 99 as a resting maker.
        bus.publish(tick("BTC-USD", 98.0));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Filled));
        approx(u.avg_fill_px, 99.0);
        approx(oms.positions()[0].qty, 1.0);
        approx(oms.positions()[0].avg_px, 99.0);
        approx(oms.account().fees_paid, 99.0 * 2.0 / 1e4); // maker fee
    }

    #[tokio::test]
    async fn stop_limit_triggered_and_marketable_fills_at_limit_as_taker() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 5.0, 2.0));
        store.set_last_price_untracked("BTC-USD", 95.0);
        let _marker = oms.spawn_marker();
        let mut rx = bus.subscribe();

        // Buy stop-limit: stop 100, limit 101 (limit ABOVE the stop). Rests,
        // then a tick at 100 arms it and 100 <= 101 is marketable -> fills at
        // the limit as a crossing taker.
        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::StopLimit,
                Some(100.0),
                Some(101.0),
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Working));

        bus.publish(tick("BTC-USD", 100.0));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Filled));
        approx(u.avg_fill_px, 101.0);
        approx(oms.positions()[0].qty, 1.0);
        approx(oms.account().fees_paid, 101.0 * 5.0 / 1e4); // taker fee
    }

    #[tokio::test]
    async fn working_stop_limit_does_not_fill_as_a_limit_before_its_stop_arms() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 95.0);
        let _marker = oms.spawn_marker();
        let mut rx = bus.subscribe();

        // Buy stop-limit: stop 100, limit 99. It rests. A naive limit scan
        // would see a buy limit at 99 and fill on any tick <= 99 — but the
        // stop has NOT armed (price is below 100), so it must NOT fill.
        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::StopLimit,
                Some(100.0),
                Some(99.0),
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Working));

        // A tick THROUGH the limit but below the stop must leave it resting.
        bus.publish(tick("BTC-USD", 98.0));
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(oms.open_orders().len(), 1);
        assert!(matches!(oms.open_orders()[0].status, OrderStatus::Working));
        assert!(oms.positions().is_empty());
        assert_eq!(oms.account().daily_trades, 0);
    }

    #[tokio::test]
    async fn stop_without_stop_px_is_rejected_with_a_clear_reason() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let mut rx = bus.subscribe();

        // Absent stop_px: rejected before ever being Accepted.
        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Buy,
                1.0,
                OrderType::Stop,
                None,
                None,
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        match &u.status {
            OrderStatus::Canceled { reason } => {
                assert_eq!(reason, "stop order requires a stop price")
            }
            other => panic!("expected cancel, got {other:?}"),
        }

        // NaN stop_px on a stop-limit is likewise rejected.
        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Sell,
                1.0,
                OrderType::StopLimit,
                Some(f64::NAN),
                Some(100.0),
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        match &u.status {
            OrderStatus::Canceled { reason } => {
                assert_eq!(reason, "stop order requires a stop price")
            }
            other => panic!("expected cancel, got {other:?}"),
        }

        // A stop-limit with a stop but no limit is rejected for the limit.
        let id = oms
            .submit(stop_intent(
                "BTC-USD",
                Side::Sell,
                1.0,
                OrderType::StopLimit,
                Some(95.0),
                None,
            ))
            .await;
        let u = next_update_for(&mut rx, id).await;
        match &u.status {
            OrderStatus::Canceled { reason } => {
                assert_eq!(reason, "stop-limit order requires a limit price")
            }
            other => panic!("expected cancel, got {other:?}"),
        }

        assert!(oms.open_orders().is_empty());
        assert_eq!(oms.account().daily_trades, 0);
        approx(oms.account().cash, 100_000.0);
    }

    #[tokio::test]
    async fn protective_sell_stop_reduces_long_and_never_flips() {
        let (bus, store, oms) = setup(cfg(0, 0.0, 0.0, 0.0));
        store.set_last_price_untracked("BTC-USD", 100.0);
        let _marker = oms.spawn_marker();

        // Open a 1.0 long.
        oms.submit(intent("BTC-USD", Side::Buy, 1.0, OrderType::Market, None))
            .await;

        // A reduce-only protective sell stop for MORE than the position (5.0):
        // when it triggers, the reduce-only clamp holds it to the live 1.0 so
        // the position lands flat instead of flipping short.
        let mut stop = stop_intent("BTC-USD", Side::Sell, 5.0, OrderType::Stop, Some(95.0), None);
        stop.reduce_only = true;
        let mut rx = bus.subscribe();
        let id = oms.submit(stop).await;
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Accepted));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Working));

        // Price falls through the stop.
        bus.publish(tick("BTC-USD", 95.0));
        let u = next_update_for(&mut rx, id).await;
        assert!(matches!(u.status, OrderStatus::Filled));
        approx(u.filled_qty, 1.0); // clamped to the live position, not 5.0
        approx(oms.positions()[0].qty, 0.0); // flat, NEVER short
    }
}

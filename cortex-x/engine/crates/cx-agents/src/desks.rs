//! Asset-class AI DESKS — three desks ("desk-crypto", "desk-equity",
//! "desk-options") sharing ONE bus-driven task (same shape as analyst.rs).
//! Each desk produces throttled [`AgentThought`]s (never a per-cycle
//! heartbeat), tighten-only [`CautionUpdate`]s, and at most ADVISORY
//! [`StrategySignal`]s:
//! - CRYPTO desk (dashed symbols): 24/7 dynamics — weekend-liquidity
//!   caution (Sat/Sun UTC), vol-regime band shifts from
//!   bar features, round-number proximity notes, and a BTC-dominance style
//!   cross-signal (BTC's trend regime colors the other cryptos at low
//!   conviction).
//! - EQUITY desk (bare symbols): >2% gap vs prior session close, scanner
//!   top/bottom-decile entry commentary (consumes [`EngineEvent::Scan`]),
//!   and a breadth-divergence caution (price up while breadth is thin).
//! - OPTIONS desk: consumes [`EngineEvent::OptionsChain`] — ATM IV,
//!   25-delta put/call skew, IV-vs-20d-realized premium; thoughts on IV
//!   spikes and steep put skew (fear -> tighten-only caution 0.15 on the
//!   underlying); an advisory signal ONLY when skew + IV agree with the
//!   underlying's regime (conviction <= 0.4).
//!
//! Advisory-signal path (verified): fusion (cx-strategy/src/fusion.rs)
//! blends every signal on the bus; its `initial_weight` starts UNKNOWN
//! strategy names — including "desk-crypto" / "desk-equity" /
//! "desk-options" — at weight 0.4, and the online Hedge layer then learns
//! each desk's real worth bar by bar (renormalized to mean 1.0, clamped
//! into [0.15, 3.0]). A desk can never dominate the blend by fiat; it must
//! earn weight. Desk cautions ride the risk engine's CautionBook, which
//! enforces tighten-only and expires entries after ~30 minutes — so every
//! condition caution (weekend liquidity, breadth divergence, steep put
//! skew) is REPUBLISHED on each evaluation while its condition holds,
//! while the accompanying thoughts stay entry-latched (no spam). All
//! numbers are NaN-firewalled on ingest; chains can be stale or sparse,
//! so IV-bearing contract counts are guarded.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use cx_core::events::{
    AgentThought, Bar, CautionUpdate, EngineEvent, OptionContract, OptionRight, OptionsChain,
    RegimeBoard, ScanBoard, StrategySignal,
};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{asset_class_of, AssetClass, Interval, Severity};
use cx_core::Bus;
use cx_ta::{compute_features, detect_regime, detect_regime_with, Regime};

use crate::ledger::{fin, fmt_px, regime_label};

/// Desk identifiers: agent name, squadron AND advisory strategy name are
/// one vocabulary, so the ledger, the UI and fusion all key on the same
/// three strings.
const CRYPTO: &str = "desk-crypto";
const EQUITY: &str = "desk-equity";
const OPTIONS: &str = "desk-options";

const CYCLE: Duration = Duration::from_secs(60);
const LOOKBACK: usize = 120;
/// Below this many bars the features are too cold to speak about.
const MIN_BARS: usize = 25;
const DAY_MS: i64 = 86_400_000;

// --- crypto desk -------------------------------------------------------------
const WEEKEND_CAUTION: f64 = 0.15;
/// vol_ewma history per symbol (one sample per cycle).
const VOL_HISTORY: usize = 100;
const MIN_VOL_HISTORY: usize = 20;
/// A price within this many percent of a round level is "at the magnet".
const ROUND_NEAR_PCT: f64 = 0.5;
/// The note re-arms once price is this far from the noted level.
const ROUND_REARM_PCT: f64 = 1.5;
/// BTC-dominance cross-signals are deliberately faint.
const CROSS_CONVICTION: f64 = 0.35;
const CROSS_DIRECTION: f64 = 0.5;

// --- equity desk -------------------------------------------------------------
/// A session gap larger than this (percent, either side) is worth a note.
const GAP_PCT: f64 = 2.0;
/// Breadth divergence: price up while pct_above_200d sits below this.
const BREADTH_FLOOR: f64 = 40.0;
const BREADTH_CAUTION: f64 = 0.10;
/// Composite is a 0-100 cross-sectional percentile blend (cx-intel).
const DECILE_TOP: f64 = 90.0;
const DECILE_BOTTOM: f64 = 10.0;

// --- options desk ------------------------------------------------------------
/// Sparse-chain guard: fewer IV-BEARING contracts than this is refused
/// (raw row counts would flatter chains whose quotes carry no IV at all).
const MIN_CONTRACTS: usize = 4;
/// The ATM read is refused when the nearest IV-bearing strike sits farther
/// than this from spot (|strike/spot - 1|): a lone deep-OTM wing IV must
/// never masquerade as ATM.
const ATM_MONEYNESS_BAND: f64 = 0.05;
/// ATM IV at or above this multiple of 20d realized is a spike.
const IV_SPIKE_RATIO: f64 = 1.5;
/// 25d put IV this far above call IV (vol fraction) is steep fear.
const STEEP_PUT_SKEW: f64 = 0.05;
/// "Calm" premium ceiling for the bullish-agreement signal.
const CALM_PREMIUM: f64 = 1.1;
/// A contract only counts as "25-delta" within this distance of target.
const DELTA_TOLERANCE: f64 = 0.15;
const SKEW_CAUTION: f64 = 0.15;
/// Advisory conviction is hard-capped at 0.4 for this desk.
const FEAR_CONVICTION: f64 = 0.35;
const CALM_CONVICTION: f64 = 0.30;
/// 21 D1 closes -> 20 close-to-close returns.
const D1_VOL_LOOKBACK: usize = 21;
const TRADING_DAYS: f64 = 252.0;

fn thought(
    desk: &'static str,
    severity: Severity,
    symbol: Option<String>,
    confidence: f64,
    text: String,
) -> EngineEvent {
    EngineEvent::Thought(AgentThought {
        agent: desk.into(),
        squadron: desk.into(),
        severity,
        text,
        tags: vec![desk.into()],
        confidence: if confidence.is_finite() {
            confidence.clamp(0.0, 1.0)
        } else {
            0.5
        },
        symbol,
        ts_ms: now_ms(),
    })
}

fn caution(desk: &'static str, scope: Option<String>, value: f64, reason: String) -> EngineEvent {
    EngineEvent::Caution(CautionUpdate {
        scope,
        value,
        reason,
        agent: desk.into(),
        ts_ms: now_ms(),
    })
}

fn signal(
    desk: &'static str,
    symbol: String,
    direction: f64,
    conviction: f64,
    rationale: String,
) -> EngineEvent {
    EngineEvent::Signal(StrategySignal {
        strategy: desk.into(),
        symbol,
        direction,
        conviction,
        rationale,
        features: BTreeMap::new(),
        ts_ms: now_ms(),
    })
}

// ---- crypto desk ------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum VolBand {
    Low,
    Normal,
    High,
}

fn band_label(b: VolBand) -> &'static str {
    match b {
        VolBand::Low => "low",
        VolBand::Normal => "normal",
        VolBand::High => "high",
    }
}

#[derive(Default)]
struct VolMemory {
    hist: VecDeque<f64>,
    band: Option<VolBand>,
}

#[derive(Default)]
pub(crate) struct CryptoDesk {
    /// Saturday day-number of the last weekend the liquidity summary
    /// THOUGHT fired (cautions republish on every weekend cycle).
    weekend_fired: Option<i64>,
    vol: HashMap<String, VolMemory>,
    /// Round level currently noted per symbol; None = armed.
    round: HashMap<String, Option<f64>>,
    /// Last seen BTC regime backing the dominance cross-signal throttle.
    btc_regime: Option<Regime>,
}

impl CryptoDesk {
    /// Sat/Sun UTC: one symbol-scoped tighten-only caution per crypto
    /// symbol on EVERY cycle while the weekend holds — the CautionBook
    /// expires entries after ~30 minutes, so a once-per-weekend caution
    /// would cover ~1% of the 48h window — plus one summary thought at
    /// most once per weekend (keyed by the Saturday's UTC day number).
    pub fn weekend_caution(&mut self, now: i64, symbols: &[String]) -> Vec<EngineEvent> {
        let Some(sat) = weekend_saturday(now) else {
            return Vec::new();
        };
        if symbols.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for sym in symbols {
            out.push(caution(
                CRYPTO,
                Some(sym.clone()),
                WEEKEND_CAUTION,
                "weekend crypto liquidity is thin (Sat/Sun UTC)".into(),
            ));
        }
        if self.weekend_fired != Some(sat) {
            self.weekend_fired = Some(sat);
            out.push(thought(
                CRYPTO,
                Severity::Warning,
                None,
                0.8,
                format!(
                    "weekend liquidity window (UTC) — requested caution {WEEKEND_CAUTION:.2} on {}",
                    symbols.join(", ")
                ),
            ));
        }
        out
    }

    /// Fold one vol_ewma sample (cx_ta feature); a note fires only when the
    /// low/normal/high band CHANGES against the symbol's own p25/p75. First
    /// classification baselines silently; non-finite samples are dropped.
    pub fn observe_vol(&mut self, symbol: &str, vol_ewma: f64) -> Option<String> {
        if !(vol_ewma.is_finite() && vol_ewma >= 0.0) {
            return None;
        }
        let mem = self.vol.entry(symbol.to_string()).or_default();
        mem.hist.push_back(vol_ewma);
        if mem.hist.len() > VOL_HISTORY {
            mem.hist.pop_front();
        }
        if mem.hist.len() < MIN_VOL_HISTORY {
            return None;
        }
        let mut sorted: Vec<f64> = mem.hist.iter().copied().collect();
        sorted.sort_unstable_by(f64::total_cmp);
        let p25 = percentile(&sorted, 0.25);
        let p75 = percentile(&sorted, 0.75);
        let band = if vol_ewma > p75 {
            VolBand::High
        } else if vol_ewma < p25 {
            VolBand::Low
        } else {
            VolBand::Normal
        };
        let note = match mem.band {
            Some(prev) if prev != band => Some(format!(
                "vol regime shift: {} -> {} (vol_ewma {vol_ewma:.3e}, p25 {p25:.3e} / p75 {p75:.3e})",
                band_label(prev),
                band_label(band),
            )),
            _ => None,
        };
        mem.band = Some(band);
        note
    }

    /// Note once when price comes within [`ROUND_NEAR_PCT`] of a round
    /// level (the half-magnitude grid — 65k/70k for BTC-scale, 3.0k/3.5k
    /// for ETH-scale); re-arms silently once price moves
    /// [`ROUND_REARM_PCT`] away from the noted level.
    pub fn observe_round(&mut self, symbol: &str, px: f64) -> Option<String> {
        let level = nearest_round(px)?;
        let noted = self.round.entry(symbol.to_string()).or_default();
        match *noted {
            Some(l) => {
                if (px / l - 1.0).abs() * 100.0 > ROUND_REARM_PCT {
                    *noted = None; // release re-arms silently
                }
                None
            }
            None => {
                let dist_pct = (px / level - 1.0).abs() * 100.0;
                if dist_pct <= ROUND_NEAR_PCT {
                    *noted = Some(level);
                    Some(format!(
                        "price {} within {dist_pct:.2}% of round number {} — magnet/reaction level",
                        fmt_px(px),
                        fmt_px(level),
                    ))
                } else {
                    None
                }
            }
        }
    }

    /// BTC-dominance style cross-signal: when BTC's trend regime CHANGES to
    /// trending, color the OTHER crypto symbols with faint advisory signals
    /// in the same direction (fusion starts the desk at weight 0.4 and the
    /// Hedge layer learns from there). Fires once per regime change.
    pub fn observe_btc(&mut self, regime: Regime, others: &[String]) -> Vec<EngineEvent> {
        let prev = self.btc_regime.replace(regime);
        if prev == Some(regime) || others.is_empty() {
            return Vec::new();
        }
        let direction = match regime {
            Regime::TrendingUp => CROSS_DIRECTION,
            Regime::TrendingDown => -CROSS_DIRECTION,
            _ => return Vec::new(),
        };
        let mut out = Vec::new();
        for sym in others {
            out.push(signal(
                CRYPTO,
                sym.clone(),
                direction,
                CROSS_CONVICTION,
                format!(
                    "btc-dominance cross-signal: BTC {} colors {sym} (advisory)",
                    regime_label(regime),
                ),
            ));
        }
        out.push(thought(
            CRYPTO,
            Severity::Insight,
            None,
            CROSS_CONVICTION,
            format!(
                "BTC {} — advisory {direction:+.2} tint on {} at conviction {CROSS_CONVICTION:.2}",
                regime_label(regime),
                others.join(", "),
            ),
        ));
        out
    }
}

// ---- equity desk ------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DecileZone {
    Top,
    Mid,
    Bottom,
}

#[derive(Default)]
pub(crate) struct EquityDesk {
    /// UTC day the gap thought last fired, per symbol.
    gap_day: HashMap<String, i64>,
    /// Scanner composite decile zone per symbol (change-detected).
    decile: HashMap<String, DecileZone>,
    /// Breadth-divergence condition active per symbol (fires on entry).
    diverging: HashMap<String, bool>,
    /// Latest breadth from the REGIMES board; None until one arrives.
    pct_above_200d: Option<f64>,
}

impl EquityDesk {
    /// >[`GAP_PCT`]% gap vs prior session close — one note per UTC day per
    /// symbol; NaN/zero closes are refused.
    pub fn observe_gap(
        &mut self,
        symbol: &str,
        last: f64,
        prior_close: f64,
        day: i64,
    ) -> Option<String> {
        if !(last.is_finite() && last > 0.0 && prior_close.is_finite() && prior_close > 0.0) {
            return None;
        }
        let gap = (last / prior_close - 1.0) * 100.0;
        if !gap.is_finite() || gap.abs() <= GAP_PCT || self.gap_day.get(symbol) == Some(&day) {
            return None;
        }
        self.gap_day.insert(symbol.to_string(), day);
        Some(format!(
            "gap {gap:+.1}% vs prior session close {}",
            fmt_px(prior_close),
        ))
    }

    /// Scanner-rank commentary: one thought when a configured symbol ENTERS
    /// the top or bottom composite decile; leaving to mid re-arms silently.
    pub fn observe_scan(&mut self, board: &ScanBoard, symbols: &[String]) -> Vec<EngineEvent> {
        let mut out = Vec::new();
        for row in &board.rows {
            if !symbols.contains(&row.symbol) || !row.composite.is_finite() {
                continue;
            }
            let zone = if row.composite >= DECILE_TOP {
                DecileZone::Top
            } else if row.composite <= DECILE_BOTTOM {
                DecileZone::Bottom
            } else {
                DecileZone::Mid
            };
            let prev = self.decile.insert(row.symbol.clone(), zone);
            if prev == Some(zone) || zone == DecileZone::Mid {
                continue;
            }
            let (label, severity) = match zone {
                DecileZone::Top => ("top", Severity::Insight),
                DecileZone::Bottom => ("bottom", Severity::Warning),
                DecileZone::Mid => unreachable!("mid entries are silent"),
            };
            out.push(thought(
                EQUITY,
                severity,
                Some(row.symbol.clone()),
                0.7,
                format!(
                    "entered {label} composite decile on the scanner (composite {:.0}, momentum {:.0}, trend {:.0})",
                    fin(row.composite),
                    fin(row.momentum),
                    fin(row.trend),
                ),
            ));
        }
        out
    }

    /// Fold the latest REGIMES-board breadth (NaN reads as absent).
    pub fn observe_board(&mut self, board: &RegimeBoard) {
        self.pct_above_200d = board.breadth.pct_above_200d.filter(|p| p.is_finite());
    }

    /// Breadth divergence: symbol trades UP vs its prior session close
    /// while breadth is thin (pct_above_200d < [`BREADTH_FLOOR`]) —
    /// tighten-only caution [`BREADTH_CAUTION`] on the symbol republished
    /// on EVERY evaluation while the divergence persists (the CautionBook
    /// TTL is ~30 minutes), plus a warning thought once per condition
    /// ENTRY; clearing re-arms.
    pub fn observe_breadth_divergence(
        &mut self,
        symbol: &str,
        last: f64,
        prior_close: f64,
    ) -> Vec<EngineEvent> {
        let price_up = last.is_finite()
            && prior_close.is_finite()
            && prior_close > 0.0
            && last > prior_close;
        let thin = matches!(self.pct_above_200d, Some(p) if p < BREADTH_FLOOR);
        let active = price_up && thin;
        let was = self
            .diverging
            .insert(symbol.to_string(), active)
            .unwrap_or(false);
        if !active {
            return Vec::new();
        }
        let pct = self.pct_above_200d.unwrap_or(0.0);
        let mut out = vec![caution(
            EQUITY,
            Some(symbol.to_string()),
            BREADTH_CAUTION,
            format!("breadth divergence: price up while only {pct:.0}% above 200d"),
        )];
        if !was {
            out.push(thought(
                EQUITY,
                Severity::Warning,
                Some(symbol.to_string()),
                0.7,
                format!(
                    "{symbol} up vs prior close while breadth is thin ({pct:.0}% above 200d < {BREADTH_FLOOR:.0}%) — requested caution {BREADTH_CAUTION:.2}",
                ),
            ));
        }
        out
    }
}

// ---- options desk -----------------------------------------------------------

/// NaN-firewalled readings computed from one chain.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct ChainReadings {
    /// Mean of the finite call/put IVs at the strike nearest spot.
    pub atm_iv: f64,
    /// 25-delta put IV minus 25-delta call IV (positive = fear).
    pub skew_25d: Option<f64>,
    /// ATM IV / annualized 20d realized; None without realized vol.
    pub premium: Option<f64>,
}

#[derive(Default)]
pub(crate) struct OptionsDesk {
    /// IV-spike condition active per underlying (fires on entry).
    spiking: HashMap<String, bool>,
    /// Steep-put-skew condition active per underlying (fires on entry).
    fearful: HashMap<String, bool>,
}

impl OptionsDesk {
    /// Fold one chain. Thoughts fire once per condition ENTRY (IV spike,
    /// steep put skew); while the skew stays steep the tighten-only
    /// caution on the underlying is REPUBLISHED on every qualifying chain
    /// (chains arrive every ~15 minutes, inside the CautionBook's
    /// ~30-minute TTL, so an entry-latched caution would lapse while fear
    /// persists). The advisory signal publishes on every qualifying chain
    /// but ONLY when skew + IV premium agree with the underlying's regime,
    /// conviction <= 0.4. Stale/sparse/unpriceable chains skip silently.
    pub fn on_chain(
        &mut self,
        chain: &OptionsChain,
        realized_ann: Option<f64>,
        regime: Option<Regime>,
    ) -> Vec<EngineEvent> {
        let Some(r) = chain_readings(chain, realized_ann) else {
            return Vec::new();
        };
        let sym = chain.underlying.clone();
        let mut out = Vec::new();

        let spiking = r.premium.is_some_and(|p| p >= IV_SPIKE_RATIO);
        let was = self.spiking.insert(sym.clone(), spiking).unwrap_or(false);
        if spiking && !was {
            out.push(thought(
                OPTIONS,
                Severity::Warning,
                Some(sym.clone()),
                0.7,
                format!(
                    "IV spike: ATM IV {:.0}% is {:.2}x the 20d realized {:.0}% (expiry {})",
                    r.atm_iv * 100.0,
                    r.premium.unwrap_or(0.0),
                    realized_ann.map(fin).unwrap_or(0.0) * 100.0,
                    chain.expiry,
                ),
            ));
        }

        let fearful = r.skew_25d.is_some_and(|s| s >= STEEP_PUT_SKEW);
        let was = self.fearful.insert(sym.clone(), fearful).unwrap_or(false);
        if fearful {
            out.push(caution(
                OPTIONS,
                Some(sym.clone()),
                SKEW_CAUTION,
                "steep 25-delta put skew (downside fear priced)".into(),
            ));
            if !was {
                let s = r.skew_25d.unwrap_or(0.0);
                out.push(thought(
                    OPTIONS,
                    Severity::Warning,
                    Some(sym.clone()),
                    0.7,
                    format!(
                        "steep put skew: 25d puts {:+.1} vol pts over calls — requested caution {SKEW_CAUTION:.2} on {sym}",
                        s * 100.0,
                    ),
                ));
            }
        }

        let calm = r.skew_25d.is_some_and(|s| s <= 0.0)
            && r.premium.is_some_and(|p| p <= CALM_PREMIUM);
        match regime {
            Some(Regime::TrendingDown) if fearful && spiking => {
                out.push(signal(
                    OPTIONS,
                    sym,
                    -CROSS_DIRECTION,
                    FEAR_CONVICTION,
                    format!(
                        "options fear agrees with the downtrend: put skew {:+.1} vol pts, ATM IV {:.2}x realized",
                        r.skew_25d.unwrap_or(0.0) * 100.0,
                        r.premium.unwrap_or(0.0),
                    ),
                ));
            }
            Some(Regime::TrendingUp) if calm => {
                out.push(signal(
                    OPTIONS,
                    sym,
                    CROSS_DIRECTION,
                    CALM_CONVICTION,
                    format!(
                        "options calm agrees with the uptrend: skew {:+.1} vol pts, ATM IV {:.2}x realized",
                        r.skew_25d.unwrap_or(0.0) * 100.0,
                        r.premium.unwrap_or(0.0),
                    ),
                ));
            }
            _ => {}
        }
        out
    }
}

fn finite_iv(c: &OptionContract) -> Option<f64> {
    c.iv.filter(|v| v.is_finite() && *v > 0.0)
}

/// Mean of the finite call/put IVs at the IV-bearing strike nearest spot;
/// None when even that strike sits outside [`ATM_MONEYNESS_BAND`] — an
/// "ATM" IV read off a distant wing would be a skew reading in disguise.
fn atm_iv(chain: &OptionsChain, spot: f64) -> Option<f64> {
    let best_strike = chain
        .contracts
        .iter()
        .filter(|c| c.strike.is_finite() && c.strike > 0.0 && finite_iv(c).is_some())
        .min_by(|a, b| (a.strike - spot).abs().total_cmp(&(b.strike - spot).abs()))
        .map(|c| c.strike)?;
    if (best_strike / spot - 1.0).abs() > ATM_MONEYNESS_BAND {
        return None;
    }
    let ivs: Vec<f64> = chain
        .contracts
        .iter()
        .filter(|c| c.strike == best_strike)
        .filter_map(finite_iv)
        .collect();
    (!ivs.is_empty()).then(|| ivs.iter().sum::<f64>() / ivs.len() as f64)
}

/// IV of the contract whose delta is nearest `target` for the given right,
/// within [`DELTA_TOLERANCE`]; None when the chain has no such wing.
fn nearest_delta_iv(chain: &OptionsChain, right: OptionRight, target: f64) -> Option<f64> {
    chain
        .contracts
        .iter()
        .filter(|c| c.right == right)
        .filter_map(|c| {
            let d = c.delta.filter(|d| d.is_finite())?;
            let iv = finite_iv(c)?;
            ((d - target).abs() <= DELTA_TOLERANCE).then_some((d, iv))
        })
        .min_by(|a, b| (a.0 - target).abs().total_cmp(&(b.0 - target).abs()))
        .map(|(_, iv)| iv)
}

/// 25-delta put IV minus 25-delta call IV (positive = downside fear).
fn skew_25d(chain: &OptionsChain) -> Option<f64> {
    let put = nearest_delta_iv(chain, OptionRight::Put, -0.25)?;
    let call = nearest_delta_iv(chain, OptionRight::Call, 0.25)?;
    let s = put - call;
    s.is_finite().then_some(s)
}

/// All chain readings behind one NaN firewall. Sparse chains (fewer than
/// [`MIN_CONTRACTS`] IV-BEARING contracts), bad spot prices, and chains
/// whose nearest IV-bearing strike falls outside the ATM moneyness band
/// are refused outright.
pub(crate) fn chain_readings(
    chain: &OptionsChain,
    realized_ann: Option<f64>,
) -> Option<ChainReadings> {
    let iv_bearing = chain
        .contracts
        .iter()
        .filter(|c| finite_iv(c).is_some())
        .count();
    if iv_bearing < MIN_CONTRACTS {
        return None;
    }
    let spot = chain.underlying_px;
    if !(spot.is_finite() && spot > 0.0) {
        return None;
    }
    let atm = atm_iv(chain, spot)?;
    if !(atm.is_finite() && atm > 0.0) {
        return None;
    }
    let premium = realized_ann
        .filter(|rv| rv.is_finite() && *rv > 0.0)
        .map(|rv| atm / rv)
        .filter(|p| p.is_finite());
    Some(ChainReadings {
        atm_iv: atm,
        skew_25d: skew_25d(chain),
        premium,
    })
}

/// Annualized close-to-close vol over the last 20 D1 returns; None when
/// history is short, dirty (non-positive closes), or degenerate (zero var).
pub(crate) fn realized_vol_20d(closes: &[f64]) -> Option<f64> {
    if closes.len() < D1_VOL_LOOKBACK {
        return None;
    }
    let tail = &closes[closes.len() - D1_VOL_LOOKBACK..];
    let rets: Vec<f64> = tail
        .windows(2)
        .filter(|w| w[0] > 0.0 && w[1] > 0.0)
        .map(|w| (w[1] / w[0]).ln())
        .filter(|r| r.is_finite())
        .collect();
    if rets.len() < D1_VOL_LOOKBACK - 1 {
        return None; // dirty history is refused, never papered over
    }
    let n = rets.len() as f64;
    let mean = rets.iter().sum::<f64>() / n;
    let var = rets.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / (n - 1.0);
    let vol = (var * TRADING_DAYS).sqrt();
    (vol.is_finite() && vol > 0.0).then_some(vol)
}

// ---- shared math ------------------------------------------------------------

/// The Saturday day-number of the weekend containing `ts_ms`, when it falls
/// on a Sat/Sun UTC; None on weekdays. (Epoch day 0 was a Thursday.)
fn weekend_saturday(ts_ms: i64) -> Option<i64> {
    let day = ts_ms.div_euclid(DAY_MS);
    match (day + 4).rem_euclid(7) {
        6 => Some(day),     // Saturday
        0 => Some(day - 1), // Sunday belongs to its Saturday
        _ => None,
    }
}

/// Nearest "round number" on the half-magnitude grid: multiples of
/// 10^floor(log10(px)) / 2 — 5,000 steps at BTC scale (65k / 70k), 500
/// steps at ETH scale (3.0k / 3.5k). None for non-finite/non-positive px.
fn nearest_round(px: f64) -> Option<f64> {
    if !(px.is_finite() && px > 0.0) {
        return None;
    }
    let step = 10f64.powf(px.log10().floor()) / 2.0;
    if !(step.is_finite() && step > 0.0) {
        return None;
    }
    let level = (px / step).round() * step;
    (level.is_finite() && level > 0.0).then_some(level)
}

/// Nearest-rank percentile of a sorted finite slice; 0.0 when empty.
fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * q.clamp(0.0, 1.0)).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

/// Close of the most recent COMPLETE D1 bar from a UTC day before `today`;
/// None when stored history hasn't reached the prior session yet.
fn prior_session_close(d1: &[Bar], today: i64) -> Option<f64> {
    d1.iter()
        .rev()
        .find(|b| {
            b.complete
                && b.ts_open_ms.div_euclid(DAY_MS) < today
                && b.close.is_finite()
                && b.close > 0.0
        })
        .map(|b| b.close)
}

// ---- the one task -----------------------------------------------------------

/// All three desks' change-detection state; pure so it is directly testable
/// (a [`BarStore`] is plain in-memory state, constructible in tests).
pub(crate) struct DesksState {
    crypto_symbols: Vec<String>,
    equity_symbols: Vec<String>,
    pub crypto: CryptoDesk,
    pub equity: EquityDesk,
    pub options: OptionsDesk,
}

impl DesksState {
    pub fn new(symbols: &[String]) -> Self {
        Self {
            crypto_symbols: symbols
                .iter()
                .filter(|s| asset_class_of(s) == AssetClass::Crypto)
                .cloned()
                .collect(),
            equity_symbols: symbols
                .iter()
                .filter(|s| asset_class_of(s) == AssetClass::Equity)
                .cloned()
                .collect(),
            crypto: CryptoDesk::default(),
            equity: EquityDesk::default(),
            options: OptionsDesk::default(),
        }
    }

    /// One 60s cycle: crypto weekend/vol/round/BTC-cross checks over M1
    /// bars, equity gap + breadth-divergence checks over D1 history and the
    /// mirrored last price. Everything inside speaks only on change.
    pub fn on_cycle(&mut self, store: &BarStore, now: i64) -> Vec<EngineEvent> {
        let mut out = Vec::new();

        out.extend(self.crypto.weekend_caution(now, &self.crypto_symbols));
        let mut btc_regime = None;
        for sym in &self.crypto_symbols {
            let bars = store.recent(sym, Interval::M1, LOOKBACK);
            if bars.len() < MIN_BARS {
                continue;
            }
            let feats = compute_features(&bars);
            let (regime, conf) = detect_regime_with(&feats, &bars);
            if sym.starts_with("BTC-") {
                btc_regime = Some(regime);
            }
            if let Some(&v) = feats.get("vol_ewma") {
                if let Some(note) = self.crypto.observe_vol(sym, v) {
                    out.push(thought(CRYPTO, Severity::Insight, Some(sym.clone()), conf, note));
                }
            }
            let last = store
                .last_price(sym)
                .or_else(|| bars.last().map(|b| b.close));
            if let Some(px) = last {
                if let Some(note) = self.crypto.observe_round(sym, px) {
                    out.push(thought(CRYPTO, Severity::Insight, Some(sym.clone()), 0.6, note));
                }
            }
        }
        if let Some(regime) = btc_regime {
            let others: Vec<String> = self
                .crypto_symbols
                .iter()
                .filter(|s| !s.starts_with("BTC-"))
                .cloned()
                .collect();
            out.extend(self.crypto.observe_btc(regime, &others));
        }

        let today = now.div_euclid(DAY_MS);
        for sym in &self.equity_symbols {
            let d1 = store.recent(sym, Interval::D1, 10);
            let Some(prior) = prior_session_close(&d1, today) else {
                continue;
            };
            let last = store
                .last_price(sym)
                .or_else(|| store.recent(sym, Interval::M1, 1).last().map(|b| b.close));
            let Some(last) = last else {
                continue;
            };
            if let Some(note) = self.equity.observe_gap(sym, last, prior, today) {
                out.push(thought(EQUITY, Severity::Insight, Some(sym.clone()), 0.7, note));
            }
            out.extend(self.equity.observe_breadth_divergence(sym, last, prior));
        }

        out
    }
}

pub(crate) fn spawn(bus: Arc<Bus>, store: Arc<BarStore>, symbols: Vec<String>) {
    // Subscribe synchronously (same rule as the ledger): no Scan/RegimeMap/
    // OptionsChain published after `start` returns can be missed by racing
    // the spawn.
    let mut rx = bus.subscribe();
    tokio::spawn(async move {
        let mut state = DesksState::new(&symbols);
        let mut iv = tokio::time::interval(CYCLE);
        iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = iv.tick() => {
                    for e in state.on_cycle(&store, now_ms()) {
                        bus.publish(e);
                    }
                }
                ev = rx.recv() => match ev {
                    Ok(ev) => {
                        let outs = match ev.as_ref() {
                            EngineEvent::Scan(board) => {
                                state.equity.observe_scan(board, &state.equity_symbols)
                            }
                            EngineEvent::RegimeMap(board) => {
                                state.equity.observe_board(board);
                                Vec::new()
                            }
                            // Only configured equities: on-demand chains for
                            // researched tickers never move the desk.
                            EngineEvent::OptionsChain(chain)
                                if state.equity_symbols.contains(&chain.underlying) =>
                            {
                                let d1 = store.recent(&chain.underlying, Interval::D1, LOOKBACK);
                                let closes: Vec<f64> = d1.iter().map(|b| b.close).collect();
                                let realized = realized_vol_20d(&closes);
                                let regime =
                                    (d1.len() >= MIN_BARS).then(|| detect_regime(&d1).0);
                                state.options.on_chain(chain, realized, regime)
                            }
                            _ => Vec::new(),
                        };
                        for e in outs {
                            bus.publish(e);
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                },
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::{Breadth, RegimeRow, ScanRow};
    use cx_core::events::RegimeState;

    fn caution_count(evs: &[EngineEvent]) -> usize {
        evs.iter()
            .filter(|e| matches!(e, EngineEvent::Caution(_)))
            .count()
    }

    fn signals(evs: &[EngineEvent]) -> Vec<&StrategySignal> {
        evs.iter()
            .filter_map(|e| match e {
                EngineEvent::Signal(s) => Some(s),
                _ => None,
            })
            .collect()
    }

    fn thoughts(evs: &[EngineEvent]) -> Vec<&AgentThought> {
        evs.iter()
            .filter_map(|e| match e {
                EngineEvent::Thought(t) => Some(t),
                _ => None,
            })
            .collect()
    }

    // ---- crypto: weekend liquidity ---------------------------------------

    #[test]
    fn weekend_caution_republishes_thought_latches_per_weekend() {
        // Epoch day 2 (1970-01-03) was a Saturday; day 3 its Sunday.
        let mut desk = CryptoDesk::default();
        let syms = vec!["BTC-USD".to_string(), "ETH-USD".to_string()];
        // Friday: silence.
        assert!(desk.weekend_caution(DAY_MS, &syms).is_empty());
        // Saturday: one symbol-scoped caution per symbol + one thought.
        let out = desk.weekend_caution(2 * DAY_MS, &syms);
        assert_eq!(caution_count(&out), 2);
        match &out[0] {
            EngineEvent::Caution(c) => {
                assert_eq!(c.scope.as_deref(), Some("BTC-USD"));
                assert!((c.value - WEEKEND_CAUTION).abs() < 1e-12);
                assert_eq!(c.agent, CRYPTO);
            }
            other => panic!("expected caution first, got {other:?}"),
        }
        assert_eq!(thoughts(&out).len(), 1);
        // Later that Saturday: the cautions REPUBLISH every cycle (the
        // CautionBook TTL is ~30 min) but the summary thought is latched.
        let again = desk.weekend_caution(2 * DAY_MS + 3_600_000, &syms);
        assert_eq!(caution_count(&again), 2);
        assert!(thoughts(&again).is_empty());
        // Its Sunday: still republishing, still no fresh thought.
        let sunday = desk.weekend_caution(3 * DAY_MS + 1_000, &syms);
        assert_eq!(caution_count(&sunday), 2);
        assert!(thoughts(&sunday).is_empty());
        // Monday: silence; NEXT Saturday: cautions + one fresh thought.
        assert!(desk.weekend_caution(4 * DAY_MS, &syms).is_empty());
        let next = desk.weekend_caution(9 * DAY_MS, &syms);
        assert_eq!(caution_count(&next), 2);
        assert_eq!(thoughts(&next).len(), 1);
        // No crypto symbols configured: never fires.
        let mut bare = CryptoDesk::default();
        assert!(bare.weekend_caution(2 * DAY_MS, &[]).is_empty());
    }

    #[test]
    fn weekend_saturday_maps_utc_days() {
        assert_eq!(weekend_saturday(2 * DAY_MS), Some(2)); // Sat 1970-01-03
        assert_eq!(weekend_saturday(3 * DAY_MS), Some(2)); // Sun -> its Sat
        assert_eq!(weekend_saturday(4 * DAY_MS), None); // Monday
        assert_eq!(weekend_saturday(DAY_MS), None); // Friday
    }

    // ---- crypto: vol regime bands ----------------------------------------

    #[test]
    fn vol_band_shift_notes_on_transition_only() {
        let mut desk = CryptoDesk::default();
        // Warm the history; the first classification baselines silently.
        for _ in 0..MIN_VOL_HISTORY {
            assert!(desk.observe_vol("BTC-USD", 1.0).is_none());
        }
        // A clear spike above p75 -> one note.
        let note = desk.observe_vol("BTC-USD", 2.0).expect("shift note");
        assert!(note.contains("normal -> high"), "{note}");
        // Still high: silent.
        assert!(desk.observe_vol("BTC-USD", 2.0).is_none());
        // Back inside the band: one note.
        let note = desk.observe_vol("BTC-USD", 1.0).expect("release note");
        assert!(note.contains("high -> normal"), "{note}");
        // NaN / negative samples are dropped without touching state.
        assert!(desk.observe_vol("BTC-USD", f64::NAN).is_none());
        assert!(desk.observe_vol("BTC-USD", -1.0).is_none());
    }

    // ---- crypto: round numbers -------------------------------------------

    #[test]
    fn nearest_round_uses_the_half_magnitude_grid() {
        assert_eq!(nearest_round(67_432.0), Some(65_000.0));
        assert_eq!(nearest_round(3_012.0), Some(3_000.0));
        assert_eq!(nearest_round(101.0), Some(100.0));
        assert_eq!(nearest_round(f64::NAN), None);
        assert_eq!(nearest_round(0.0), None);
        assert_eq!(nearest_round(-5.0), None);
    }

    #[test]
    fn round_number_note_fires_once_and_rearms() {
        let mut desk = CryptoDesk::default();
        // 3% away from the 100 level: armed but silent.
        assert!(desk.observe_round("ETH-USD", 97.0).is_none());
        // Within 0.5%: one note.
        let note = desk.observe_round("ETH-USD", 100.2).expect("round note");
        assert!(note.contains("round number 100.00"), "{note}");
        // Hovering at the level: silent.
        assert!(desk.observe_round("ETH-USD", 100.4).is_none());
        // Leaving by more than the re-arm distance: silent release ...
        assert!(desk.observe_round("ETH-USD", 102.0).is_none());
        // ... then a re-approach notes again.
        assert!(desk.observe_round("ETH-USD", 100.3).is_some());
        // NaN-safe.
        assert!(desk.observe_round("ETH-USD", f64::NAN).is_none());
    }

    // ---- crypto: BTC-dominance cross-signal --------------------------------

    #[test]
    fn btc_cross_colors_others_on_trend_change_only() {
        let mut desk = CryptoDesk::default();
        let others = vec!["ETH-USD".to_string(), "SOL-USD".to_string()];
        let out = desk.observe_btc(Regime::TrendingUp, &others);
        let sigs = signals(&out);
        assert_eq!(sigs.len(), 2);
        for s in &sigs {
            assert_eq!(s.strategy, CRYPTO);
            assert!((s.direction - CROSS_DIRECTION).abs() < 1e-12);
            assert!((s.conviction - CROSS_CONVICTION).abs() < 1e-12);
        }
        assert_eq!(thoughts(&out).len(), 1);
        // Same regime again: throttled.
        assert!(desk.observe_btc(Regime::TrendingUp, &others).is_empty());
        // Non-trending regimes color nothing.
        assert!(desk.observe_btc(Regime::Ranging, &others).is_empty());
        assert!(desk.observe_btc(Regime::HighVol, &others).is_empty());
        // A fresh downtrend fires short tints.
        let out = desk.observe_btc(Regime::TrendingDown, &others);
        assert!((signals(&out)[0].direction + CROSS_DIRECTION).abs() < 1e-12);
        // No siblings configured: nothing to color.
        let mut solo = CryptoDesk::default();
        assert!(solo.observe_btc(Regime::TrendingUp, &[]).is_empty());
    }

    // ---- equity: gaps -------------------------------------------------------

    #[test]
    fn gap_note_once_per_day_and_nan_safe() {
        let mut desk = EquityDesk::default();
        let note = desk.observe_gap("AAPL", 103.0, 100.0, 10).expect("gap");
        assert!(note.contains("gap +3.0%"), "{note}");
        assert!(note.contains("100.00"), "{note}");
        // Same day: throttled; next day: a fresh gap notes again.
        assert!(desk.observe_gap("AAPL", 104.0, 100.0, 10).is_none());
        assert!(desk.observe_gap("AAPL", 96.5, 100.0, 11).is_some());
        // Below the 2% bar: silence.
        assert!(desk.observe_gap("AAPL", 101.5, 100.0, 12).is_none());
        // NaN / non-positive closes are refused.
        assert!(desk.observe_gap("AAPL", f64::NAN, 100.0, 13).is_none());
        assert!(desk.observe_gap("AAPL", 103.0, f64::NAN, 13).is_none());
        assert!(desk.observe_gap("AAPL", 103.0, 0.0, 13).is_none());
    }

    // ---- equity: scanner deciles -------------------------------------------

    fn scan_row(sym: &str, composite: f64) -> ScanRow {
        ScanRow {
            symbol: sym.into(),
            asset_class: "equity".into(),
            composite,
            momentum: 50.0,
            trend: 50.0,
            breakout: 50.0,
            meanrev: 50.0,
            vol_state: 50.0,
            rsi_14: None,
            zscore_20: None,
            kalman_tstat: None,
            ret_1w: None,
            ret_1m: None,
            ret_3m: None,
            dist_52w_high: None,
            vol_surge: None,
            regime: None,
            flags: vec![],
            last_close: 100.0,
            sector: None, shares_outstanding: None, public_float_usd: None, short_interest: None,
        }
    }

    fn scan_board(rows: Vec<ScanRow>) -> ScanBoard {
        ScanBoard {
            rows,
            alerts: Vec::new(),
            weights_used: Default::default(),
            source: "test".into(),
            ts_ms: 0,
        }
    }

    #[test]
    fn scan_decile_entry_notes_and_throttles() {
        let mut desk = EquityDesk::default();
        let syms = vec!["AAPL".to_string()];
        // Entering the top decile (even on first sight) notes once.
        let out = desk.observe_scan(&scan_board(vec![scan_row("AAPL", 95.0)]), &syms);
        assert_eq!(out.len(), 1);
        let t = &thoughts(&out)[0];
        assert_eq!(t.severity, Severity::Insight);
        assert!(t.text.contains("top composite decile"), "{}", t.text);
        // Republished top decile: throttled.
        assert!(desk
            .observe_scan(&scan_board(vec![scan_row("AAPL", 93.0)]), &syms)
            .is_empty());
        // Back to mid: silent re-arm; bottom decile: one Warning.
        assert!(desk
            .observe_scan(&scan_board(vec![scan_row("AAPL", 50.0)]), &syms)
            .is_empty());
        let out = desk.observe_scan(&scan_board(vec![scan_row("AAPL", 5.0)]), &syms);
        assert_eq!(out.len(), 1);
        let t = &thoughts(&out)[0];
        assert_eq!(t.severity, Severity::Warning);
        assert!(t.text.contains("bottom composite decile"), "{}", t.text);
        // Unconfigured symbols and NaN composites never note.
        assert!(desk
            .observe_scan(&scan_board(vec![scan_row("DOGE-USD", 99.0)]), &syms)
            .is_empty());
        assert!(desk
            .observe_scan(&scan_board(vec![scan_row("AAPL", f64::NAN)]), &syms)
            .is_empty());
    }

    // ---- equity: breadth divergence ----------------------------------------

    fn regime_board(pct_above_200d: Option<f64>) -> RegimeBoard {
        RegimeBoard {
            rows: vec![RegimeRow {
                symbol: "AAPL".into(),
                state: RegimeState::Bull,
                drawdown_pct: 0.02,
                runup_pct: 0.1,
                days_in_state: 5,
                dist_50_200_pct: None,
                last_close: 100.0,
            }],
            breadth: Breadth {
                pct_above_200d,
                pct_above_50d: None,
                bulls: 1,
                bears: 1,
                entering_bull: 0,
                entering_bear: 0,
                universe_size: 2,
            },
            source: "test".into(),
            ts_ms: 0,
        }
    }

    #[test]
    fn breadth_divergence_caution_republishes_thought_on_entry() {
        let mut desk = EquityDesk::default();
        // No breadth seen yet: never fires.
        assert!(desk.observe_breadth_divergence("AAPL", 105.0, 100.0).is_empty());
        desk.observe_board(&regime_board(Some(35.0)));
        // Price up + thin breadth: one caution + one warning thought.
        let out = desk.observe_breadth_divergence("AAPL", 105.0, 100.0);
        assert_eq!(caution_count(&out), 1);
        match &out[0] {
            EngineEvent::Caution(c) => {
                assert_eq!(c.scope.as_deref(), Some("AAPL"));
                assert!((c.value - BREADTH_CAUTION).abs() < 1e-12);
                assert_eq!(c.agent, EQUITY);
            }
            other => panic!("expected caution first, got {other:?}"),
        }
        assert_eq!(thoughts(&out).len(), 1);
        // Condition persists: the caution REPUBLISHES on every evaluation
        // (CautionBook TTL ~30 min), the thought stays latched.
        let again = desk.observe_breadth_divergence("AAPL", 106.0, 100.0);
        assert_eq!(caution_count(&again), 1);
        assert!(thoughts(&again).is_empty());
        // Price rolls over: silent re-arm; a fresh entry fires both again.
        assert!(desk.observe_breadth_divergence("AAPL", 95.0, 100.0).is_empty());
        let re = desk.observe_breadth_divergence("AAPL", 105.0, 100.0);
        assert_eq!(caution_count(&re), 1);
        assert_eq!(thoughts(&re).len(), 1);
        // Healthy breadth clears the condition.
        desk.observe_board(&regime_board(Some(62.0)));
        assert!(desk.observe_breadth_divergence("AAPL", 110.0, 100.0).is_empty());
        // NaN breadth reads as absent.
        desk.observe_board(&regime_board(Some(f64::NAN)));
        assert!(desk.observe_breadth_divergence("AAPL", 111.0, 100.0).is_empty());
    }

    // ---- options: IV / skew math against hand-computed fixtures -------------

    fn contract(right: OptionRight, strike: f64, iv: Option<f64>, delta: Option<f64>) -> OptionContract {
        OptionContract {
            symbol: "TST".into(),
            right,
            strike,
            expiry: "2026-08-21".into(),
            bid: 1.0,
            ask: 1.2,
            last: 1.1,
            volume: 10.0,
            open_interest: 100.0,
            iv,
            delta,
            gamma: None,
            theta: None,
            vega: None,
            greeks_source: "test".into(),
        }
    }

    fn chain(spot: f64, contracts: Vec<OptionContract>) -> OptionsChain {
        OptionsChain {
            underlying: "AAPL".into(),
            underlying_px: spot,
            expirations: vec!["2026-08-21".into()],
            expiry: "2026-08-21".into(),
            contracts,
            source: "test".into(),
            as_of: None,
            ts_ms: 0,
        }
    }

    /// Fixture: spot 100.5 -> ATM strike 100; ATM IV = (0.30 + 0.32) / 2 =
    /// 0.31; 25d skew = put(Δ -0.24, iv 0.38) - call(Δ +0.27, iv 0.28) =
    /// 0.10; premium = 0.31 / 0.20 = 1.55.
    fn fear_chain() -> OptionsChain {
        chain(
            100.5,
            vec![
                contract(OptionRight::Call, 100.0, Some(0.30), Some(0.52)),
                contract(OptionRight::Put, 100.0, Some(0.32), Some(-0.48)),
                contract(OptionRight::Put, 95.0, Some(0.38), Some(-0.24)),
                contract(OptionRight::Call, 105.0, Some(0.28), Some(0.27)),
            ],
        )
    }

    #[test]
    fn chain_readings_match_hand_computed_fixture() {
        let r = chain_readings(&fear_chain(), Some(0.20)).expect("readings");
        assert!((r.atm_iv - 0.31).abs() < 1e-12, "atm_iv {}", r.atm_iv);
        assert!((r.skew_25d.unwrap() - 0.10).abs() < 1e-12, "{r:?}");
        assert!((r.premium.unwrap() - 1.55).abs() < 1e-12, "{r:?}");
        // Without realized vol the premium is honestly absent.
        let r = chain_readings(&fear_chain(), None).expect("readings");
        assert_eq!(r.premium, None);
        // Degenerate realized vol never divides.
        let r = chain_readings(&fear_chain(), Some(0.0)).expect("readings");
        assert_eq!(r.premium, None);
    }

    #[test]
    fn chain_readings_guard_sparse_and_junk_chains() {
        // Fewer than MIN_CONTRACTS IV-bearing contracts: refused.
        let sparse = chain(
            100.0,
            vec![
                contract(OptionRight::Call, 100.0, Some(0.3), Some(0.5)),
                contract(OptionRight::Put, 100.0, Some(0.3), Some(-0.5)),
            ],
        );
        assert_eq!(chain_readings(&sparse, Some(0.2)), None);
        // Bad spot: refused.
        let mut bad = fear_chain();
        bad.underlying_px = f64::NAN;
        assert_eq!(chain_readings(&bad, Some(0.2)), None);
        // No finite IV anywhere: refused.
        let ivless = chain(
            100.0,
            vec![
                contract(OptionRight::Call, 100.0, None, Some(0.5)),
                contract(OptionRight::Put, 100.0, Some(f64::NAN), Some(-0.5)),
                contract(OptionRight::Put, 95.0, None, Some(-0.25)),
                contract(OptionRight::Call, 105.0, None, Some(0.25)),
            ],
        );
        assert_eq!(chain_readings(&ivless, Some(0.2)), None);
        // No wing within the delta tolerance: skew is absent, ATM survives.
        let no_wings = chain(
            100.0,
            vec![
                contract(OptionRight::Call, 100.0, Some(0.30), Some(0.52)),
                contract(OptionRight::Put, 100.0, Some(0.32), Some(-0.48)),
                contract(OptionRight::Put, 80.0, Some(0.45), Some(-0.05)),
                contract(OptionRight::Call, 120.0, Some(0.26), Some(0.05)),
            ],
        );
        let r = chain_readings(&no_wings, Some(0.2)).expect("readings");
        assert_eq!(r.skew_25d, None);
    }

    #[test]
    fn chain_readings_enforce_atm_moneyness_and_iv_bearing_gate() {
        // Four IV-bearing contracts, ALL deep OTM (>5% from spot): a lone
        // far wing IV must never masquerade as ATM -> refused outright.
        let wings = chain(
            100.0,
            vec![
                contract(OptionRight::Call, 140.0, Some(0.55), Some(0.05)),
                contract(OptionRight::Call, 150.0, Some(0.60), Some(0.03)),
                contract(OptionRight::Put, 60.0, Some(0.70), Some(-0.04)),
                contract(OptionRight::Put, 50.0, Some(0.80), Some(-0.02)),
            ],
        );
        assert_eq!(chain_readings(&wings, Some(0.2)), None);
        // Nearest IV-bearing strike just inside the 5% band still reads,
        // even when other strikes sit far outside it.
        let near = chain(
            100.0,
            vec![
                contract(OptionRight::Call, 104.0, Some(0.30), Some(0.40)),
                contract(OptionRight::Put, 104.0, Some(0.32), Some(-0.60)),
                contract(OptionRight::Put, 94.0, Some(0.36), Some(-0.24)),
                contract(OptionRight::Call, 112.0, Some(0.28), Some(0.27)),
            ],
        );
        let r = chain_readings(&near, Some(0.2)).expect("readings");
        assert!((r.atm_iv - 0.31).abs() < 1e-12, "atm_iv {}", r.atm_iv);
        // MIN_CONTRACTS gates on IV-BEARING contracts, not raw rows: four
        // rows with only three carrying IV -> refused ...
        let mut thin = fear_chain();
        thin.contracts[3].iv = None;
        assert_eq!(chain_readings(&thin, Some(0.2)), None);
        // ... and padding with IV-less rows never rescues it.
        thin.contracts
            .push(contract(OptionRight::Call, 110.0, None, Some(0.2)));
        thin.contracts
            .push(contract(OptionRight::Put, 90.0, None, Some(-0.2)));
        assert_eq!(chain_readings(&thin, Some(0.2)), None);
    }

    #[test]
    fn realized_vol_20d_matches_closed_form() {
        // 10 up-1% and 10 down-1% days: mean and variance in closed form.
        let mut closes = vec![100.0];
        for i in 0..20 {
            let prev = *closes.last().unwrap();
            closes.push(if i % 2 == 0 { prev * 1.01 } else { prev * 0.99 });
        }
        let a = 1.01f64.ln();
        let b = 0.99f64.ln();
        let m = (a + b) / 2.0;
        let var = (10.0 * (a - m).powi(2) + 10.0 * (b - m).powi(2)) / 19.0;
        let expect = (var * TRADING_DAYS).sqrt();
        let got = realized_vol_20d(&closes).expect("vol");
        assert!((got - expect).abs() < 1e-12, "got {got}, expect {expect}");
        // Short history: refused.
        assert_eq!(realized_vol_20d(&closes[..20]), None);
        // Dirty history (a zero close) is refused, never papered over.
        let mut dirty = closes.clone();
        dirty[5] = 0.0;
        assert_eq!(realized_vol_20d(&dirty), None);
        // Degenerate constant series has no vol to speak of.
        assert_eq!(realized_vol_20d(&vec![100.0; 21]), None);
    }

    // ---- options: desk transitions + agreement signal ------------------------

    #[test]
    fn options_desk_fires_on_entry_and_signals_only_on_agreement() {
        let mut desk = OptionsDesk::default();
        // Fear chain + downtrend: IV-spike thought, skew caution + thought,
        // and ONE short advisory signal at conviction <= 0.4.
        let out = desk.on_chain(&fear_chain(), Some(0.20), Some(Regime::TrendingDown));
        assert_eq!(caution_count(&out), 1);
        match out
            .iter()
            .find(|e| matches!(e, EngineEvent::Caution(_)))
            .unwrap()
        {
            EngineEvent::Caution(c) => {
                assert_eq!(c.scope.as_deref(), Some("AAPL"));
                assert!((c.value - SKEW_CAUTION).abs() < 1e-12);
                assert_eq!(c.agent, OPTIONS);
            }
            _ => unreachable!(),
        }
        let ths = thoughts(&out);
        assert_eq!(ths.len(), 2);
        assert!(ths.iter().any(|t| t.text.contains("IV spike")), "{ths:?}");
        assert!(ths.iter().any(|t| t.text.contains("steep put skew")), "{ths:?}");
        let sigs = signals(&out);
        assert_eq!(sigs.len(), 1);
        assert_eq!(sigs[0].strategy, OPTIONS);
        assert!(sigs[0].direction < 0.0);
        assert!(sigs[0].conviction <= 0.4);
        // Same chain again: thoughts latched; the skew caution REPUBLISHES
        // while fear persists (chains land every ~15 min, inside the
        // CautionBook's ~30-min TTL) and the signal rides.
        let again = desk.on_chain(&fear_chain(), Some(0.20), Some(Regime::TrendingDown));
        assert_eq!(caution_count(&again), 1);
        assert!(thoughts(&again).is_empty());
        assert_eq!(signals(&again).len(), 1);
        // Fear without a downtrend: no signal (regime must agree).
        let mut fresh = OptionsDesk::default();
        let out = fresh.on_chain(&fear_chain(), Some(0.20), Some(Regime::Ranging));
        assert!(signals(&out).is_empty());
        let out = fresh.on_chain(&fear_chain(), Some(0.20), None);
        assert!(signals(&out).is_empty());
    }

    #[test]
    fn options_desk_calm_uptrend_signal_and_sparse_chain_silence() {
        // Calm chain: call skew (put iv below call iv) + modest premium.
        let calm = chain(
            100.5,
            vec![
                contract(OptionRight::Call, 100.0, Some(0.20), Some(0.52)),
                contract(OptionRight::Put, 100.0, Some(0.20), Some(-0.48)),
                contract(OptionRight::Put, 95.0, Some(0.19), Some(-0.24)),
                contract(OptionRight::Call, 105.0, Some(0.21), Some(0.27)),
            ],
        );
        let mut desk = OptionsDesk::default();
        let out = desk.on_chain(&calm, Some(0.20), Some(Regime::TrendingUp));
        assert_eq!(caution_count(&out), 0);
        assert!(thoughts(&out).is_empty());
        let sigs = signals(&out);
        assert_eq!(sigs.len(), 1);
        assert!(sigs[0].direction > 0.0);
        assert!(sigs[0].conviction <= 0.4);
        // Calm chain against a downtrend: silence.
        let mut fresh = OptionsDesk::default();
        assert!(fresh
            .on_chain(&calm, Some(0.20), Some(Regime::TrendingDown))
            .is_empty());
        // Sparse chains never speak at all.
        let sparse = chain(100.0, vec![contract(OptionRight::Call, 100.0, Some(0.3), Some(0.5))]);
        assert!(fresh
            .on_chain(&sparse, Some(0.20), Some(Regime::TrendingDown))
            .is_empty());
    }

    // ---- the cycle over a real BarStore --------------------------------------

    fn d1_bar(sym: &str, day: i64, close: f64) -> Bar {
        Bar {
            symbol: sym.into(),
            interval: Interval::D1,
            ts_open_ms: day * DAY_MS,
            open: close,
            high: close * 1.001,
            low: close * 0.999,
            close,
            volume: 1.0,
            trade_count: 1,
            vwap: close,
            complete: true,
        }
    }

    #[test]
    fn cycle_notes_equity_gap_from_store_once_per_day() {
        let store = BarStore::new();
        store.push(d1_bar("AAPL", 11, 100.0));
        store.set_last_price("AAPL", 103.0);
        let mut state = DesksState::new(&["AAPL".to_string(), "BTC-USD".to_string()]);
        // Day 12 (a Tuesday): no weekend caution can muddy the assert.
        let now = 12 * DAY_MS + 3_600_000;
        let out = state.on_cycle(&store, now);
        let ths = thoughts(&out);
        assert_eq!(ths.len(), 1, "{out:?}");
        assert_eq!(ths[0].agent, EQUITY);
        assert_eq!(ths[0].symbol.as_deref(), Some("AAPL"));
        assert!(ths[0].text.contains("gap +3.0%"), "{}", ths[0].text);
        // The same day cycles silently thereafter.
        assert!(state.on_cycle(&store, now + 60_000).is_empty());
    }

    #[test]
    fn prior_session_close_skips_today_and_junk() {
        let today = 12;
        let bars = vec![
            d1_bar("AAPL", 10, 98.0),
            d1_bar("AAPL", 11, 100.0),
            d1_bar("AAPL", 12, 103.0), // today: must be skipped
        ];
        assert_eq!(prior_session_close(&bars, today), Some(100.0));
        // An incomplete or NaN prior bar is skipped, falling further back.
        let mut bars2 = bars.clone();
        bars2[1].complete = false;
        assert_eq!(prior_session_close(&bars2, today), Some(98.0));
        let mut bars3 = bars.clone();
        bars3[1].close = f64::NAN;
        assert_eq!(prior_session_close(&bars3, today), Some(98.0));
        assert_eq!(prior_session_close(&[], today), None);
    }
}

//! MERIDIAN — the Dalio section. Geopolitical events (GDELT 2.0 DOC API,
//! keyless) -> theme buckets -> Five Forces gauges + fired causal chains.
//! Publishes `EngineEvent::Geo`; elevated external-conflict feeds a
//! tighten-only global caution, the same channel the macro sentinel uses.
//!
//! Honesty notes:
//! - Every gauge's `proxy` names its real driver (GDELT tone EWMA, article
//!   intensity vs 30d baseline, UST curve off the macro bus). Cold starts
//!   read neutral 50 and say so.
//! - No rule fires before 7 distinct baseline days exist for its theme.
//! - The ArtList JSON often ships without a `tone` field; absent tone is
//!   recorded as 0.0 (neutral) rather than invented.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use cx_core::config::Config;
use cx_core::egress::Egress;
use cx_core::events::{
    CausalChain, CautionUpdate, EngineEvent, ForceGauge, GeoEvent, GeoPulse,
};
use cx_core::time::now_ms;
use cx_core::Bus;

use crate::causal_rules::{self, FIRE_Z};

/// Theme id -> GDELT DOC query. Ids are the rulebook's theme keys.
pub const THEMES: &[(&str, &str)] = &[
    (
        "armed_conflict",
        r#"(war OR invasion OR airstrike OR "armed conflict" OR ceasefire) sourcelang:english"#,
    ),
    (
        "sanctions_trade",
        r#"(sanctions OR "trade war" OR tariffs OR embargo) sourcelang:english"#,
    ),
    (
        "energy_opec",
        r#"(OPEC OR "oil supply" OR "crude oil" OR "natural gas" OR "energy crisis") sourcelang:english"#,
    ),
    (
        "central_banks",
        r#"("central bank" OR "interest rates" OR inflation OR "federal reserve") sourcelang:english"#,
    ),
    (
        "sovereign_debt",
        r#"("sovereign debt" OR "debt crisis" OR "sovereign default" OR "IMF bailout") sourcelang:english"#,
    ),
    (
        "elections_instability",
        r#"(election OR coup OR protests OR "political crisis" OR unrest) sourcelang:english"#,
    ),
    (
        "tech_exports",
        r#"("export controls" OR "chip ban" OR "semiconductor exports" OR "tech war") sourcelang:english"#,
    ),
    (
        "natural_disasters",
        r#"(earthquake OR hurricane OR flood OR wildfire OR typhoon OR drought) sourcelang:english"#,
    ),
];

const DAY_MS: i64 = 86_400_000;
/// Event ring capacity (deduped by normalized title).
const RING_CAP: usize = 200;
/// Counting-dedup TTL: a title re-seen within this window is never "fresh".
/// Decoupled from the display ring so a single-theme news storm cannot evict
/// quiet themes' titles and inflate their counts on refetch.
const DEDUP_TTL_MS: i64 = 48 * 3_600_000;
/// Per-theme counting-dedup map cap (oldest-first eviction beyond this).
const DEDUP_CAP: usize = 500;
/// Events carried in each GeoPulse (newest first).
const PULSE_EVENTS: usize = 60;
/// Baseline retention (days of per-poll counts kept).
const BASELINE_RETAIN_MS: i64 = 31 * DAY_MS;
/// Minimum distinct baseline days before any rule may fire.
const MIN_BASELINE_DAYS: usize = 7;
/// Tone EWMA half-life (~7 days, timestamp-aware decay).
const TONE_HALF_LIFE_MS: f64 = 7.0 * DAY_MS as f64;
/// External-order caution: gauge threshold, value, and emission spacing.
const EXTERNAL_CAUTION_GAUGE: f64 = 75.0;
const EXTERNAL_CAUTION_VALUE: f64 = 0.25;
const CAUTION_GAP_MS: i64 = 6 * 3_600_000;
/// Spacing between per-theme GDELT queries.
const QUERY_GAP: Duration = Duration::from_millis(1_000);

const FORCE_DEBT: &str = "debt & money";
const FORCE_INTERNAL: &str = "internal order";
const FORCE_EXTERNAL: &str = "external order";
const FORCE_NATURE: &str = "nature";
const FORCE_TECH: &str = "technology";

/// Spawn the periodic GDELT poller (cadence `intel.gdelt_poll_secs`).
/// Also subscribes to the bus to cache the latest MacroSnapshot for the
/// debt-and-money force.
pub fn spawn_poller(bus: Arc<Bus>, cfg: Config) {
    tokio::spawn(async move {
        let cadence = Duration::from_secs(cfg.intel.gdelt_poll_secs.max(300));
        let egress = Egress::new();
        let mut state = MeridianState::default();
        let mut rx = bus.subscribe();
        let mut rx_open = true;
        let mut last_caution_ms: i64 = 0;
        let mut next_poll = tokio::time::Instant::now();
        loop {
            tokio::select! {
                _ = tokio::time::sleep_until(next_poll) => {
                    next_poll = tokio::time::Instant::now() + cadence;
                    match poll(&egress, &mut state).await {
                        Some(pulse) => {
                            let external = pulse
                                .forces
                                .iter()
                                .find(|f| f.force == FORCE_EXTERNAL)
                                .map(|f| f.value)
                                .unwrap_or(0.0);
                            let now = now_ms();
                            if external >= EXTERNAL_CAUTION_GAUGE
                                && now - last_caution_ms >= CAUTION_GAP_MS
                            {
                                last_caution_ms = now;
                                bus.publish(EngineEvent::Caution(CautionUpdate {
                                    scope: None,
                                    value: EXTERNAL_CAUTION_VALUE,
                                    reason: "MERIDIAN: external conflict elevated".into(),
                                    agent: "meridian".into(),
                                    ts_ms: now,
                                }));
                            }
                            bus.publish(EngineEvent::Geo(pulse));
                        }
                        None => tracing::debug!("meridian: no pulse this cycle"),
                    }
                }
                ev = rx.recv(), if rx_open => {
                    match ev {
                        Ok(ev) => {
                            if let EngineEvent::Macro(m) = ev.as_ref() {
                                state.set_macro(m.curve_regime.clone(), m.spread_2s10s_bps);
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::debug!(dropped = n, "meridian: bus lag; macro cache may be stale");
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            rx_open = false;
                        }
                    }
                }
            }
        }
    });
}

/// Rolling MERIDIAN state: per-theme article baselines, tone EWMAs, event
/// ring, macro inputs for the debt/money force.
#[derive(Default)]
pub struct MeridianState {
    /// Per-theme (poll ts_ms, new unique articles) history, ~31d retained.
    counts: HashMap<&'static str, VecDeque<(i64, u32)>>,
    /// Per-theme tone EWMA (~7d half-life).
    tones: HashMap<&'static str, ToneEwma>,
    /// Deduped event ring, oldest -> newest (display only).
    ring: VecDeque<GeoEvent>,
    /// Normalized titles currently in the ring (display dedupe only).
    ring_seen: HashSet<String>,
    /// Per-theme counting dedup: normalized title -> last_seen_ms. TTL- and
    /// cap-bounded, independent of ring eviction — freshness for COUNTING
    /// comes from here only.
    counted: HashMap<&'static str, HashMap<String, i64>>,
    /// Per-force (ts_ms, value) history for trend_7d (~8d retained).
    force_hist: HashMap<&'static str, VecDeque<(i64, f64)>>,
    /// Latest curve regime + 2s10s bps from the macro bus.
    macro_curve: Option<(String, Option<f64>)>,
}

impl MeridianState {
    pub fn set_macro(&mut self, curve_regime: String, spread_2s10s_bps: Option<f64>) {
        self.macro_curve = Some((curve_regime, spread_2s10s_bps));
    }

    /// Ingest one theme's freshly parsed articles at `now`: record the
    /// new-article count (zero counts matter — quiet days ARE the baseline),
    /// fold fresh tones into the theme EWMA, and dedupe into the display
    /// ring. COUNTING freshness comes from the per-theme TTL map only, so
    /// ring eviction under a single-theme storm cannot re-mint other themes'
    /// stale titles as fresh.
    fn ingest(&mut self, theme: &'static str, parsed: Vec<GeoEvent>, now: i64) -> u32 {
        let counted = self.counted.entry(theme).or_default();
        counted.retain(|_, last_seen| now - *last_seen <= DEDUP_TTL_MS);
        let mut fresh = 0u32;
        let mut tone_sum = 0.0;
        for ev in parsed {
            let key = normalize_title(&ev.title);
            if key.is_empty() {
                continue;
            }
            if counted.insert(key.clone(), now).is_none() {
                fresh += 1;
                tone_sum += if ev.tone.is_finite() { ev.tone } else { 0.0 };
            }
            // Display ring keeps its own dedupe; eviction here is cosmetic.
            if self.ring_seen.insert(key) {
                self.ring.push_back(ev);
                if self.ring.len() > RING_CAP {
                    if let Some(old) = self.ring.pop_front() {
                        self.ring_seen.remove(&normalize_title(&old.title));
                    }
                }
            }
        }
        // Cap the counting map, evicting least-recently-seen titles first.
        while counted.len() > DEDUP_CAP {
            let Some(oldest) = counted
                .iter()
                .min_by_key(|(_, last_seen)| **last_seen)
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            counted.remove(&oldest);
        }
        let hist = self.counts.entry(theme).or_default();
        hist.push_back((now, fresh));
        while hist.front().is_some_and(|(ts, _)| now - ts > BASELINE_RETAIN_MS) {
            hist.pop_front();
        }
        if fresh > 0 {
            self.tones
                .entry(theme)
                .or_default()
                .update(tone_sum / f64::from(fresh), now);
        }
        fresh
    }

    /// 24h article-count z-score vs the 30d daily baseline. None until at
    /// least [`MIN_BASELINE_DAYS`] distinct full days exist (cold-start
    /// honesty: no rule fires on an unknown baseline). The daily std is
    /// floored at 1.0 article so a perfectly quiet baseline still yields a
    /// finite, meaningful z.
    fn theme_z(&self, theme: &str, now: i64) -> Option<f64> {
        let hist = self.counts.get(theme)?;
        let mut daily: BTreeMap<i64, f64> = BTreeMap::new();
        let mut last_24h = 0.0f64;
        for (ts, n) in hist {
            if now - ts < DAY_MS {
                last_24h += f64::from(*n);
            } else {
                *daily.entry(ts.div_euclid(DAY_MS)).or_default() += f64::from(*n);
            }
        }
        if daily.len() < MIN_BASELINE_DAYS {
            return None;
        }
        let vals: Vec<f64> = daily.values().copied().collect();
        let mean = vals.iter().sum::<f64>() / vals.len() as f64;
        let var = vals.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / vals.len() as f64;
        let std = var.sqrt().max(1.0);
        Some((last_24h - mean) / std)
    }

    /// Top-N most-negative-tone events of a theme, for chain evidence.
    fn evidence(&self, theme: &str, n: usize) -> Vec<GeoEvent> {
        let mut evs: Vec<&GeoEvent> = self.ring.iter().filter(|e| e.theme == theme).collect();
        evs.sort_by(|a, b| a.tone.partial_cmp(&b.tone).unwrap_or(std::cmp::Ordering::Equal));
        evs.into_iter().take(n).cloned().collect()
    }

    /// Gauge value now, and the 7d trend from stored history (0.0 until the
    /// history spans at least ~6 days). Records the new sample.
    fn gauge_trend(&mut self, force: &'static str, value: f64, now: i64) -> f64 {
        let hist = self.force_hist.entry(force).or_default();
        while hist.front().is_some_and(|(ts, _)| now - ts > 8 * DAY_MS) {
            hist.pop_front();
        }
        let trend = match hist.front() {
            Some((ts, old)) if now - ts >= 6 * DAY_MS => value - old,
            _ => 0.0,
        };
        hist.push_back((now, value));
        trend
    }

    /// Assemble the Five Forces + fired chains + event feed at `now`.
    fn pulse(&mut self, now: i64) -> GeoPulse {
        // --- Five Forces --------------------------------------------------
        let (debt_v, debt_proxy) = debt_money_gauge(
            self.macro_curve
                .as_ref()
                .map(|(r, s)| (r.as_str(), *s)),
        );
        let tone_of = |s: &Self, t: &str| s.tones.get(t).and_then(|e| e.value);

        let internal_tone = tone_of(self, "elections_instability");
        let internal_v = internal_tone.map_or(50.0, tone_to_gauge);

        let ext_tones: Vec<f64> = ["armed_conflict", "sanctions_trade"]
            .iter()
            .filter_map(|t| tone_of(self, t))
            .collect();
        let external_v = if ext_tones.is_empty() {
            50.0
        } else {
            tone_to_gauge(ext_tones.iter().sum::<f64>() / ext_tones.len() as f64)
        };

        let nature_z = self.theme_z("natural_disasters", now);
        let nature_v = nature_z.map_or(50.0, z_to_gauge);
        let tech_z = self.theme_z("tech_exports", now);
        let tech_v = tech_z.map_or(50.0, z_to_gauge);

        let cold = " — cold start, neutral 50";
        let forces = vec![
            ForceGauge {
                force: FORCE_DEBT.into(),
                value: debt_v,
                trend_7d: self.gauge_trend(FORCE_DEBT, debt_v, now),
                proxy: debt_proxy,
            },
            ForceGauge {
                force: FORCE_INTERNAL.into(),
                value: internal_v,
                trend_7d: self.gauge_trend(FORCE_INTERNAL, internal_v, now),
                proxy: format!(
                    "GDELT tone EWMA (elections/instability){}",
                    if internal_tone.is_none() { cold } else { "" }
                ),
            },
            ForceGauge {
                force: FORCE_EXTERNAL.into(),
                value: external_v,
                trend_7d: self.gauge_trend(FORCE_EXTERNAL, external_v, now),
                proxy: format!(
                    "GDELT tone EWMA (conflict + sanctions){}",
                    if ext_tones.is_empty() { cold } else { "" }
                ),
            },
            ForceGauge {
                force: FORCE_NATURE.into(),
                value: nature_v,
                trend_7d: self.gauge_trend(FORCE_NATURE, nature_v, now),
                proxy: format!(
                    "GDELT disaster-article intensity vs 30d baseline{}",
                    if nature_z.is_none() { cold } else { "" }
                ),
            },
            ForceGauge {
                force: FORCE_TECH.into(),
                value: tech_v,
                trend_7d: self.gauge_trend(FORCE_TECH, tech_v, now),
                proxy: format!(
                    "GDELT tech-export-control article intensity vs 30d baseline{}",
                    if tech_z.is_none() { cold } else { "" }
                ),
            },
        ];

        // --- Fired causal chains ------------------------------------------
        let mut chains: Vec<CausalChain> = Vec::new();
        for (theme, _) in THEMES {
            let Some(z) = self.theme_z(theme, now) else {
                continue;
            };
            if z < FIRE_Z {
                continue;
            }
            let evidence = self.evidence(theme, 3);
            for rule in causal_rules::rules().iter().filter(|r| r.theme == *theme) {
                chains.push(CausalChain {
                    rule_id: rule.rule_id.into(),
                    title: rule.title.into(),
                    steps: rule.steps.iter().map(|s| (*s).into()).collect(),
                    assets: rule
                        .assets
                        .iter()
                        .map(|(target, dir, note)| cx_core::events::AssetImpact {
                            target: (*target).into(),
                            direction: *dir,
                            note: (*note).into(),
                        })
                        .collect(),
                    intensity: z,
                    evidence: evidence.clone(),
                });
            }
        }
        chains.sort_by(|a, b| {
            b.intensity
                .partial_cmp(&a.intensity)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        GeoPulse {
            forces,
            chains,
            events: self.ring.iter().rev().take(PULSE_EVENTS).cloned().collect(),
            source: "gdelt 2.0 (15-min updates)".into(),
            ts_ms: now,
        }
    }
}

/// Timestamp-aware tone EWMA: after `dt` the old value keeps weight
/// 0.5^(dt / 7d) — an exact ~7-day half-life regardless of update cadence.
#[derive(Default)]
struct ToneEwma {
    value: Option<f64>,
    last_ts: i64,
}

impl ToneEwma {
    fn update(&mut self, x: f64, ts: i64) {
        if !x.is_finite() {
            return;
        }
        match self.value {
            None => self.value = Some(x),
            Some(v) => {
                let dt = (ts - self.last_ts).max(0) as f64;
                let w = 0.5f64.powf(dt / TONE_HALF_LIFE_MS);
                self.value = Some(v * w + x * (1.0 - w));
            }
        }
        // Never move backward on an out-of-order older timestamp, or the
        // next in-order update would over-decay.
        self.last_ts = self.last_ts.max(ts);
    }
}

/// Debt & money force from the cached macro curve:
/// base by regime (inverted 80 / flat 60 / normal 40 / steep 30, unknown 50)
/// plus a 2s10s depth adjustment of -spread/20 bps clamped to ±10 points
/// (deeper inversion pushes higher, steeper curve pushes lower). Neutral 50
/// with an honest proxy label until a MacroSnapshot has been seen.
fn debt_money_gauge(macro_curve: Option<(&str, Option<f64>)>) -> (f64, String) {
    let Some((regime, spread)) = macro_curve else {
        return (50.0, "neutral 50 (no macro snapshot yet)".into());
    };
    let base = match regime {
        "inverted" => 80.0,
        "flat" => 60.0,
        "normal" => 40.0,
        "steep" => 30.0,
        _ => 50.0,
    };
    let adj = spread
        .filter(|s| s.is_finite())
        .map_or(0.0, |s| (-s / 20.0).clamp(-10.0, 10.0));
    (
        (base + adj).clamp(0.0, 100.0),
        format!("UST curve regime ({regime}) + 2s10s depth (macro bus)"),
    )
}

/// Tone -> gauge: more negative GDELT tone reads as more disorder.
/// 0 tone = 50; each tone point moves the gauge 10; clamped to [0, 100].
fn tone_to_gauge(tone: f64) -> f64 {
    if !tone.is_finite() {
        return 50.0;
    }
    (50.0 - 10.0 * tone).clamp(0.0, 100.0)
}

/// Intensity z-score -> gauge: baseline 50, +15 per sigma, clamped [0, 100].
fn z_to_gauge(z: f64) -> f64 {
    if !z.is_finite() {
        return 50.0;
    }
    (50.0 + 15.0 * z).clamp(0.0, 100.0)
}

/// One poll cycle: query GDELT per theme, dedupe, update gauges, fire rules.
/// None when every fetch failed (degradation is silent but logged).
pub async fn poll(egress: &Egress, state: &mut MeridianState) -> Option<GeoPulse> {
    let mut any_ok = false;
    for (theme, query) in THEMES {
        let url = gdelt_url(query);
        match egress.get_text(&url).await {
            Ok(raw) => {
                any_ok = true;
                let now = now_ms();
                let parsed = parse_artlist(theme, &raw, now);
                let fresh = state.ingest(theme, parsed, now);
                tracing::debug!(theme, fresh, "gdelt theme polled");
            }
            Err(e) => {
                tracing::warn!(theme, error = %e, "gdelt theme fetch failed; continuing");
            }
        }
        tokio::time::sleep(QUERY_GAP).await;
    }
    if !any_ok {
        tracing::warn!("meridian: every gdelt theme fetch failed this cycle");
        return None;
    }
    Some(state.pulse(now_ms()))
}

fn gdelt_url(query: &str) -> String {
    format!(
        "https://api.gdeltproject.org/api/v2/doc/doc?query={}&mode=ArtList&format=json&maxrecords=25&timespan=24h",
        url_encode(query)
    )
}

/// Minimal percent-encoder (RFC 3986 unreserved kept verbatim). Local on
/// purpose: no new crate deps.
fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Title normalization for dedupe: lowercase alphanumerics, single-spaced.
fn normalize_title(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    let mut last_space = true;
    for ch in title.chars() {
        if ch.is_alphanumeric() {
            out.extend(ch.to_lowercase());
            last_space = false;
        } else if !last_space {
            out.push(' ');
            last_space = true;
        }
    }
    out.trim_end().to_string()
}

/// Parse a GDELT ArtList JSON body into events. Malformed bodies or rows
/// degrade to fewer events, never a panic. `tone` is frequently absent from
/// ArtList output; absent tone is recorded as 0.0 (neutral). `seendate`
/// ("YYYYMMDDThhmmssZ") failures fall back to `fallback_ts`.
pub(crate) fn parse_artlist(theme: &str, raw: &str, fallback_ts: i64) -> Vec<GeoEvent> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else {
        tracing::warn!(theme, "gdelt: unparseable artlist body");
        return Vec::new();
    };
    let Some(articles) = v.get("articles").and_then(|a| a.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(articles.len());
    for art in articles {
        let s = |k: &str| art.get(k).and_then(|x| x.as_str()).unwrap_or("").trim().to_string();
        let title = s("title");
        if title.is_empty() {
            continue;
        }
        let tone = art
            .get("tone")
            .and_then(|t| t.as_f64().or_else(|| t.as_str().and_then(|s| s.parse().ok())))
            .filter(|t| t.is_finite())
            .unwrap_or(0.0);
        let ts_ms = chrono::NaiveDateTime::parse_from_str(&s("seendate"), "%Y%m%dT%H%M%SZ")
            .map(|dt| dt.and_utc().timestamp_millis())
            .unwrap_or(fallback_ts);
        let country = s("sourcecountry");
        out.push(GeoEvent {
            title,
            source_domain: s("domain"),
            url: s("url"),
            tone,
            theme: theme.to_string(),
            countries: if country.is_empty() { Vec::new() } else { vec![country] },
            ts_ms,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const ARTLIST_FIXTURE: &str = r#"{
        "articles": [
            {"url": "https://example.com/a", "title": "Sanctions tighten on oil exports",
             "domain": "example.com", "seendate": "20260712T063000Z",
             "sourcecountry": "United States", "tone": -6.2},
            {"url": "https://example.org/b", "title": "Trade war: new tariffs announced!",
             "domain": "example.org", "seendate": "20260712T070000Z",
             "sourcecountry": "Germany"},
            {"url": "https://example.net/c", "title": "  ",
             "domain": "example.net", "seendate": "20260712T070500Z"},
            {"url": "https://example.com/d", "title": "sanctions TIGHTEN on Oil exports.",
             "domain": "example.com", "seendate": "20260712T080000Z",
             "sourcecountry": "France", "tone": "-3.5"}
        ]
    }"#;

    #[test]
    fn artlist_fixture_parses_with_tone_fallbacks() {
        let evs = parse_artlist("sanctions_trade", ARTLIST_FIXTURE, 42);
        // Empty-title row dropped; near-duplicate survives parse (dedupe is
        // the state's job).
        assert_eq!(evs.len(), 3);
        assert_eq!(evs[0].tone, -6.2);
        assert_eq!(evs[1].tone, 0.0); // absent tone -> neutral
        assert_eq!(evs[2].tone, -3.5); // string tone parsed
        assert_eq!(evs[0].countries, vec!["United States".to_string()]);
        assert_eq!(evs[0].theme, "sanctions_trade");
        assert!(evs[0].ts_ms > 1_700_000_000_000);
        assert!(parse_artlist("x", "junk", 1).is_empty());
        assert!(parse_artlist("x", "{}", 1).is_empty());
        assert!(parse_artlist("x", r#"{"articles": "no"}"#, 1).is_empty());
    }

    #[test]
    fn ingest_dedupes_by_normalized_title_across_polls() {
        let mut st = MeridianState::default();
        let evs = parse_artlist("sanctions_trade", ARTLIST_FIXTURE, 42);
        // Rows 0 and 3 normalize identically -> 2 fresh.
        assert_eq!(st.ingest("sanctions_trade", evs.clone(), 1_000), 2);
        assert_eq!(st.ring.len(), 2);
        // Second poll with the same articles: nothing fresh.
        assert_eq!(st.ingest("sanctions_trade", evs, 2_000), 0);
        assert_eq!(st.ring.len(), 2);
    }

    fn geo_event(theme: &str, title: String, ts_ms: i64) -> GeoEvent {
        GeoEvent {
            title,
            source_domain: "x.com".into(),
            url: String::new(),
            tone: 0.0,
            theme: theme.into(),
            countries: Vec::new(),
            ts_ms,
        }
    }

    #[test]
    fn ring_caps_at_200_and_frees_titles_for_display_only() {
        let mut st = MeridianState::default();
        for i in 0..250 {
            let ev = geo_event("armed_conflict", format!("headline number {i}"), i);
            st.ingest("armed_conflict", vec![ev], i);
        }
        assert_eq!(st.ring.len(), RING_CAP);
        assert_eq!(st.ring_seen.len(), RING_CAP);
        // The evicted oldest title re-enters the DISPLAY ring, but it was
        // seen within the counting TTL, so it is not counted fresh again.
        let ev = geo_event("armed_conflict", "headline number 0".into(), 999);
        assert_eq!(st.ingest("armed_conflict", vec![ev], 999), 0);
        assert_eq!(st.ring.len(), RING_CAP);
        assert!(st.ring_seen.contains("headline number 0"));
    }

    #[test]
    fn single_theme_storm_does_not_remint_evicted_quiet_titles_as_fresh() {
        // W1 regression: one theme floods 25 new titles per poll for enough
        // polls to evict a quiet theme's stable titles from the 200-slot
        // display ring; re-ingesting the stable titles must count 0 fresh.
        let mut st = MeridianState::default();
        let stable: Vec<GeoEvent> = (0..5)
            .map(|i| geo_event("natural_disasters", format!("quiet stable headline {i}"), 0))
            .collect();
        assert_eq!(st.ingest("natural_disasters", stable.clone(), 1_000), 5);

        let mut now = 1_000;
        for poll in 0..12 {
            now += 60_000;
            let flood: Vec<GeoEvent> = (0..25)
                .map(|i| {
                    geo_event("armed_conflict", format!("storm headline {poll} {i}"), now)
                })
                .collect();
            assert_eq!(st.ingest("armed_conflict", flood, now), 25);
        }
        // The storm has fully evicted the quiet theme from the display ring.
        assert!(st.ring.iter().all(|e| e.theme == "armed_conflict"));
        assert!(!st.ring_seen.contains("quiet stable headline 0"));

        // Refetch of the same stable titles: 0 fresh (no inflated counts).
        now += 60_000;
        assert_eq!(st.ingest("natural_disasters", stable, now), 0);
        let hist = st.counts.get("natural_disasters").unwrap();
        assert_eq!(hist.back(), Some(&(now, 0)));
    }

    #[test]
    fn counting_dedup_expires_after_ttl_and_respects_cap() {
        let mut st = MeridianState::default();
        let ev = geo_event("sanctions_trade", "old sanctions headline".into(), 0);
        assert_eq!(st.ingest("sanctions_trade", vec![ev.clone()], 1_000), 1);
        // Re-seen inside the TTL: refreshed, not fresh.
        assert_eq!(st.ingest("sanctions_trade", vec![ev.clone()], 2_000), 0);
        // Unseen for longer than the TTL: fresh again.
        assert_eq!(
            st.ingest("sanctions_trade", vec![ev], 2_000 + DEDUP_TTL_MS + 1),
            1
        );

        // Cap: DEDUP_CAP + 100 titles in one poll keeps the map at the cap.
        let flood: Vec<GeoEvent> = (0..DEDUP_CAP + 100)
            .map(|i| geo_event("tech_exports", format!("cap headline {i}"), 0))
            .collect();
        st.ingest("tech_exports", flood, 5_000);
        assert_eq!(st.counted.get("tech_exports").unwrap().len(), DEDUP_CAP);
    }

    #[test]
    fn tone_ewma_has_seven_day_half_life() {
        let mut e = ToneEwma::default();
        e.update(-4.0, 0);
        assert_eq!(e.value, Some(-4.0));
        // After exactly 7 days, old value keeps weight 0.5.
        e.update(0.0, 7 * DAY_MS);
        assert!((e.value.unwrap() + 2.0).abs() < 1e-9);
        // Non-finite input is ignored.
        e.update(f64::NAN, 8 * DAY_MS);
        assert!((e.value.unwrap() + 2.0).abs() < 1e-9);
    }

    #[test]
    fn tone_ewma_ignores_out_of_order_older_timestamps() {
        let mut e = ToneEwma::default();
        e.update(-4.0, 7 * DAY_MS);
        // Out-of-order older update: value unchanged AND last_ts holds.
        e.update(0.0, 3 * DAY_MS);
        assert_eq!(e.value, Some(-4.0));
        assert_eq!(e.last_ts, 7 * DAY_MS);
        // The next in-order update decays exactly one half-life (7d), not
        // the 11d it would see if last_ts had slid backward.
        e.update(0.0, 14 * DAY_MS);
        assert!((e.value.unwrap() + 2.0).abs() < 1e-9);
    }

    fn seed_baseline(st: &mut MeridianState, theme: &'static str, days: i64, per_day: u32, t0: i64) {
        for d in 0..days {
            st.counts
                .entry(theme)
                .or_default()
                .push_back((t0 + d * DAY_MS, per_day));
        }
    }

    #[test]
    fn z_score_fires_on_spike_and_respects_cold_start() {
        let day = DAY_MS;
        let t0 = 100 * day;

        // Cold start: 3 baseline days -> no z at all.
        let mut cold = MeridianState::default();
        seed_baseline(&mut cold, "armed_conflict", 3, 2, t0);
        assert!(cold.theme_z("armed_conflict", t0 + 4 * day).is_none());

        // Quiet 8-day baseline then a spike: fires well above FIRE_Z.
        let mut st = MeridianState::default();
        seed_baseline(&mut st, "armed_conflict", 8, 2, t0);
        let now = t0 + 9 * day;
        st.counts.entry("armed_conflict").or_default().push_back((now, 20));
        let z = st.theme_z("armed_conflict", now).unwrap();
        assert!(z >= FIRE_Z, "z {z}");

        // Same baseline, normal day: does not fire.
        let mut quiet = MeridianState::default();
        seed_baseline(&mut quiet, "armed_conflict", 8, 2, t0);
        quiet.counts.entry("armed_conflict").or_default().push_back((now, 2));
        let z = quiet.theme_z("armed_conflict", now).unwrap();
        assert!(z < FIRE_Z, "z {z}");
    }

    #[test]
    fn pulse_fires_theme_rules_with_evidence_and_honest_cold_labels() {
        let day = DAY_MS;
        let t0 = 100 * day;
        let now = t0 + 9 * day;
        let mut st = MeridianState::default();
        seed_baseline(&mut st, "armed_conflict", 8, 1, t0);
        st.counts.entry("armed_conflict").or_default().push_back((now, 25));
        for i in 0..4 {
            let ev = GeoEvent {
                title: format!("conflict escalates {i}"),
                source_domain: "wire.com".into(),
                url: String::new(),
                tone: -1.0 * f64::from(i), // 0, -1, -2, -3
                theme: "armed_conflict".into(),
                countries: vec!["Ukraine".into()],
                ts_ms: now,
            };
            st.ring.push_back(ev);
        }
        let pulse = st.pulse(now);
        assert_eq!(pulse.source, "gdelt 2.0 (15-min updates)");
        assert_eq!(pulse.forces.len(), 5);
        // Every armed_conflict rule fired, no other theme fired.
        let fired: Vec<&str> = pulse.chains.iter().map(|c| c.rule_id.as_str()).collect();
        assert!(fired.iter().all(|id| id.starts_with("AC-")));
        assert_eq!(
            fired.len(),
            causal_rules::rules().iter().filter(|r| r.theme == "armed_conflict").count()
        );
        let chain = &pulse.chains[0];
        assert!(chain.intensity >= FIRE_Z);
        // Evidence = 3 most negative tones.
        assert_eq!(chain.evidence.len(), 3);
        assert_eq!(chain.evidence[0].tone, -3.0);
        assert!(chain.evidence.iter().all(|e| e.tone <= -1.0));
        // Cold-start honesty: no macro yet -> neutral debt gauge, labeled.
        let debt = pulse.forces.iter().find(|f| f.force == FORCE_DEBT).unwrap();
        assert_eq!(debt.value, 50.0);
        assert!(debt.proxy.contains("no macro snapshot yet"));
        // trend_7d is 0.0 without prior gauge history.
        assert!(pulse.forces.iter().all(|f| f.trend_7d == 0.0));
        assert!(pulse.events.len() <= PULSE_EVENTS);
    }

    #[test]
    fn no_rule_fires_below_threshold_or_before_baseline() {
        let day = DAY_MS;
        let t0 = 100 * day;
        // Below threshold.
        let mut st = MeridianState::default();
        seed_baseline(&mut st, "energy_opec", 8, 3, t0);
        let now = t0 + 9 * day;
        st.counts.entry("energy_opec").or_default().push_back((now, 3));
        assert!(st.pulse(now).chains.is_empty());
        // Spike but only 4 baseline days: cold start blocks firing.
        let mut young = MeridianState::default();
        seed_baseline(&mut young, "energy_opec", 4, 1, t0);
        young.counts.entry("energy_opec").or_default().push_back((now, 50));
        assert!(young.pulse(now).chains.is_empty());
    }

    #[test]
    fn gauge_mappings_stay_in_bounds() {
        for tone in [-100.0, -5.0, 0.0, 5.0, 100.0, f64::NAN] {
            let g = tone_to_gauge(tone);
            assert!((0.0..=100.0).contains(&g), "tone {tone} -> {g}");
        }
        assert_eq!(tone_to_gauge(0.0), 50.0);
        assert_eq!(tone_to_gauge(-5.0), 100.0); // grimmer tone -> higher force
        assert_eq!(tone_to_gauge(-2.0), 70.0);
        for z in [-50.0, -1.0, 0.0, 2.0, 50.0, f64::NAN] {
            let g = z_to_gauge(z);
            assert!((0.0..=100.0).contains(&g), "z {z} -> {g}");
        }
        assert_eq!(z_to_gauge(0.0), 50.0);
        assert_eq!(z_to_gauge(2.0), 80.0);
    }

    #[test]
    fn debt_money_gauge_maps_curve_regimes() {
        assert_eq!(debt_money_gauge(None).0, 50.0);
        let (v, proxy) = debt_money_gauge(Some(("inverted", Some(-60.0))));
        assert!((v - 83.0).abs() < 1e-9, "inverted -60bps -> {v}");
        assert!(proxy.contains("inverted"));
        let (v, _) = debt_money_gauge(Some(("steep", Some(250.0))));
        assert!((v - 20.0).abs() < 1e-9, "steep 250bps -> {v}"); // adj clamped -10
        let (v, _) = debt_money_gauge(Some(("flat", None)));
        assert_eq!(v, 60.0);
        let (v, _) = debt_money_gauge(Some(("normal", Some(f64::NAN))));
        assert_eq!(v, 40.0);
        let (v, _) = debt_money_gauge(Some(("unknown", None)));
        assert_eq!(v, 50.0);
    }

    #[test]
    fn trend_7d_needs_six_days_of_history() {
        let mut st = MeridianState::default();
        assert_eq!(st.gauge_trend(FORCE_NATURE, 50.0, 0), 0.0);
        assert_eq!(st.gauge_trend(FORCE_NATURE, 60.0, 2 * DAY_MS), 0.0);
        // Seven days after the first sample: trend vs the oldest kept.
        let t = st.gauge_trend(FORCE_NATURE, 72.0, 7 * DAY_MS);
        assert!((t - 22.0).abs() < 1e-9);
    }

    #[test]
    fn gdelt_url_is_encoded_and_on_allowlisted_host() {
        for (theme, query) in THEMES {
            let url = gdelt_url(query);
            assert!(url.starts_with("https://api.gdeltproject.org/api/v2/doc/doc?query="));
            assert!(!url.contains(' '), "{theme}: unencoded space");
            assert!(!url.contains('"'), "{theme}: unencoded quote");
            assert!(url.contains("mode=ArtList") && url.contains("timespan=24h"));
        }
        assert_eq!(url_encode("a b\"c"), "a%20b%22c");
    }

    #[test]
    fn normalize_title_collapses_case_and_punctuation() {
        assert_eq!(
            normalize_title("Sanctions TIGHTEN, on Oil—exports!  "),
            "sanctions tighten on oil exports"
        );
        assert_eq!(normalize_title("  !!  "), "");
    }
}

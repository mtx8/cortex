# CORTEX × OMNISCIENT — Geo-Alpha Fusion Architecture & Roadmap

> **Status:** Active build (Conductor-authorized, full autonomy). Date: 2026-06-12.
> **One-line thesis:** Fuse OMNISCIENT's hardened real-time geospatial intelligence into CORTEX's
> 58-agent autonomous execution loop, producing *physical alpha* (oil-tanker / supply-chain / satellite
> signals) that flows straight into trades. Bloomberg can only *resell* alt-data entitlements; it has no
> native geo-fusion-to-execution. **That is the irreplaceable, acquisition-worthy asset.**

This document is the single source of truth for the integration. It is derived from a 16-agent
reconnaissance of both codebases plus OSS/AI-tooling research (see `wf_300a565b-47a`). OMNISCIENT
(`~/Desktop/omniscient-macos`) is **read-only** — we *port patterns*, we never modify it.

---

## 1. Current state (ground truth)

| Layer | Path | Size | State |
|---|---|---|---|
| Python brain | `cortex-py/` | 22,177 LOC / 147 files | **Mature.** FastAPI :8765, SignalBus, 8 squadrons (ALPHA…HOTEL), TradePipeline + AutonomyDial + kill switch, connectors (IBKR/Polygon/Coinbase/SEC), feeds, Claude engine + chat. |
| macOS app | `cortex-app/` | 13,500 LOC / 50 files | **Mature.** SwiftUI, macOS 14+, `@Observable` stores, `AppTab` (9 tabs), `MessageRouter`↔`WebSocketClient`, `CortexDesign` tokens. |
| Rust core | `cortex-rs/` | 498 LOC / 2 files | **Skeletal.** Single PyO3 `cortex_scanner` cdylib (RSI/MACD scan). Not yet a dependency of `cortex-py`. **This is where the moat gets built.** |

Host environment: **macOS 26.5.1 (Tahoe), arm64 (Apple Silicon).** Rust 1.93, uv 0.9, Python 3.13,
Node 25, Swift 6.2. ⇒ **Apple Foundation Models (native on-device LLM) is available.** `maturin` and
`ollama` are not yet installed (verified-install steps in the build plan).

### CORTEX architecture rules (immutable — from `cortex/CLAUDE.md`)
1. Secrets in `~/.cortex/secrets.toml` or env / Keychain. Never hardcoded.
2. All inter-squadron comms via **SignalBus**. Agents never import across squadrons.
3. async + uvloop; IBKR via `rate_limiter.py`; agents inherit `BaseAgent.handle_signal()`.
4. All orders → `TradePipeline` → `PreTradeCheck`. No bypass.
5. **LLMs never in the execution hot path** — strategic cycle only.
6. Kill switch Phase-1 is synchronous in-memory (no network dependency).
7. Pinned packages: httpx, ib_async, coinbase-advanced-py, redis[hiredis], asyncpg, orjson, pydantic v2, aiolimiter, structlog.

---

## 2. Target architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  cortex-app (SwiftUI, macOS 26)                                                │
│   AppTab.geoIntelligence → GeoIntelligenceView (Cesium globe in WKWebView,     │
│   iframe-isolated) + GeoIntelligenceStore.  Foundation Models / Speech / Vision│
│   on-device.  ⌘K mnemonic command palette (DES/GP/OMON/ECO/PORT/GEO).          │
└───────────────▲───────────────────────────────── WS :8765 (type-discriminated)│
                │                                                                │
┌───────────────┴────────────────────────────────────────────────────────────┐ │
│  cortex-py (FastAPI brain)                                                   │ │
│   SignalBus ── squadrons ── TradePipeline ── AutonomyDial ── kill switch     │ │
│   NEW: squadron INDIA (geo alt-data)  ·  feeds/geo_*  ·  intelligence/       │ │
│         providers/{local,claude,gemini} + router  ·  rag (sqlite-vec)        │ │
│   NEW connectors: aisstream(WS), eia, fred, treasury  ·  TimesFM vol module  │ │
└───────────────▲──────────────────────────────────────────────────────────────┘
                │ PyO3 (cortex_scanner cdylib)
┌───────────────┴──────────────────────────────────────────────────────────────┐
│  cortex-rs (Rust core — the moat)                                              │
│   egress  → hardened anti-SSRF chokepoint (ported from omniscient http.rs):    │
│             https-only, exact-host allowlist, redirect containment, 5 MiB cap, │
│             credential-binding, secret-free errors.  Keys never touch JS/Py.   │
│   geo     → haversine, geofences, world chokepoints (Hormuz/Suez/Bab/Bosphorus)│
│   maritime→ AIS tanker categorization + PHYSICAL-ALPHA: floating-storage index,│
│             chokepoint congestion, dark-ship flags, port-loading cadence.      │
│   normalize→ USGS / OpenSky / Digitraffic-AIS parsers → typed GeoSignal.       │
│   scanner → existing RSI/MACD (untouched).                                     │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Why the egress lives in Rust, not Python:** a compromised Python agent (or a prompt-injected LLM
tool call) cannot make arbitrary outbound requests — the Rust chokepoint is the *entire* external
network surface for OSINT/geo, https-only and exact-host-allowlisted. API keys are bound per-host and
never cross feeds. This is the omniscient SSRF-proof model, reused.

---

## 3. Physical-alpha signal definitions (the flagship)

Maritime AIS front-runs official inventory prints (EIA/API) by 1–7 days. CORTEX computes:

| Signal | Definition | Trades into |
|---|---|---|
| **Floating-Storage Index** | Count laden crude tankers (AIS shipType 80–89, draught near loaded) with speed <0.5 kn, stationary >7 d, outside ports/terminals. Rising = bearish crude, bullish VLCC rates. | CL/Brent (short), FRO/STNG/DHT (long) |
| **Chokepoint Congestion** | Geofence Hormuz (~20 mb/d), Suez/SUMED (~4.9), Bab-el-Mandeb (~4.2), Turkish Straits (~3.7). Track 7-day transit count + avg transit speed. Queue spike / speed drop = supply-disruption premium. | CL/Brent (long), XLE |
| **AIS-Dark Event** | Laden tanker whose AIS goes silent N hours in a sanctions corridor = shadow-fleet / re-route / loss-of-supply flag. | CL (long), tanker equities |
| **Port-Loading Cadence** | Port-call deltas at US Gulf export terminals (Corpus Christi, Houston, LOOP) + NOAA water level = export-volume nowcast that leads EIA weekly. | CL, refiners on crack spread |

All auto-actions stay behind the **kill switch + autonomy dial**. Geo signals are *leading
indicators* feeding the strategic cycle, never naked execution triggers.

Companion OSINT (already in omniscient): aircraft (OpenSky), satellites (CelesTrak), earthquakes
(USGS → flag positions near seismic zones / mining/energy assets), launches (SpaceDevs).

---

## 4. Data sources (allowlisted, license-clean spine)

Free / license-clean first; one paid feed only when free gaps hurt.

| Source | Host | Tracks | Auth | Notes |
|---|---|---|---|---|
| AISStream.io | `stream.aisstream.io` (WS) | Live global AIS (tankers) | free key | WS spine; no SLA → treat as signal, not source-of-record |
| Digitraffic | `meri.digitraffic.fi` | Baltic AIS (cross-check) | none | already in omniscient |
| EIA | `api.eia.gov` | Petroleum status, chokepoint volumes | free key | the report AIS front-runs |
| FRED | `api.stlouisfed.org` | Yield curve, econ series | free key | closes Bloomberg FI gap |
| US Treasury | `api.fiscaldata.treasury.gov` | Daily yield curve | none | FI |
| OpenSky | `opensky-network.org` | Aircraft | OAuth2 | low priority for trading |
| CelesTrak | `celestrak.org` | Satellite TLEs | none | |
| USGS | `earthquake.usgs.gov` | Earthquakes | none | asset-proximity risk |
| NOAA CO-OPS | (added when wired) | Port water levels | none | port-loading nowcast |
| GDELT | `api.gdeltproject.org` | Global news | none | already in omniscient |
| VesselFinder | `api.vesselfinder.com` | Satellite positions (dark zones) | **paid** | allowlisted, keyed-only, deferred |

**License traps (enforced):** Global Fishing Watch forbids commercial/trading use — **excluded.**
Free AIS has no SLA — a quality layer (gap detection, MMSI dedup, spoofing heuristics) is mandatory.

---

## 5. Local-LLM & ML stack (private, offline-capable)

Provider order: **local (Ollama/MLX) → Claude → Gemini**, with an `offline_only` hard-lock. Claude stays
strategic-cycle-only (rule #5). No LLM in the hot path, local or cloud.

| Tool | Role | License | Where |
|---|---|---|---|
| **MLX / mlx-lm** | Local research LLM + batch sentiment (fastest on M-series) | MIT | cortex-py |
| **Ollama 0.19+** | OpenAI-compatible local front door (`/v1/chat`, `/v1/embeddings`), MLX backend | MIT | cortex-py |
| **Apple Foundation Models** | On-device structured tasks, guided generation | Apple SDK | cortex-app (Swift) |
| **Apple Speech / Vision** | Voice-command agents; OCR filings → tables | Apple SDK | cortex-app |
| **tiktoken** (Karpathy) | Canonical local tokenizer / token budgeting | MIT | cortex-py |
| **nanoGPT** (Karpathy) | Offline-trained tiny news-sentiment / regime head (PyTorch-MPS) | MIT | offline trainer |
| **micrograd** (Karpathy) | Teaching / eval harness only — never in `cortex/` runtime | MIT | dev only |
| **Oríon** (Mila, Québec AI Institute) | Real hyperparameter search behind `golf/strategy_optimizer.py`; objective = −Sharpe from SimulationEngine | BSD-3 | cortex-py |
| **TimesFM 2.5** (Google) | **Volatility/risk forecaster** (best-in-class realized-vol; NOT a direction signal) | Apache-2.0 | cortex-py |
| **Gemma 3/4** (Google, via Ollama) | Local sentiment + private deep-research | Apache-2.0 | cortex-py |
| **Gemini Flash** (Google) | Optional cheap structured-output fallback | API | cortex-py |
| Embeddings: nomic-embed / bge-m3 / Qwen3-Embedding | RAG over filings/news | Apache-2.0 | cortex-py |
| Vector store: **sqlite-vec** → LanceDB (growth) | Embedded KNN with metadata filtering | Apache-2.0 | cortex-py |

> **Interpretation noted:** the user's "Mila Jovovic open source tools" = **Mila, the Québec AI
> Institute** (mila.quebec, Bengio) → **Oríon**. Milla Jovovich is the actress; this is the corrected
> reading and we proceed with Oríon. `llm.c` / `llama2.c` are excluded (no Apple Metal path).

---

## 6. Bloomberg-killer gap closure

CORTEX already at terminal grade: real-time quotes, charting (TradingView + RSI/MACD), composite
scanner, fundamentals + SEC EDGAR, full Black-Scholes-Merton options (Greeks/IV/skew), L2 + T&S + order
panel, portfolio/risk (VaR/drawdown), tax-loss harvest + wash-sale, **and 58-agent autonomy Bloomberg
has no equivalent of.** Hard gaps to close, in order of credibility-per-effort:

1. **Geo alt-data squadron** (the leapfrog — §3). Flagship.
2. **News → institutional grade:** multi-source low-latency (8-K stream + RSS/Benzinga + social), LLM
   sentiment replacing keyword counting in `delta/news_catalyst.py`.
3. **Economic calendar (ECO)** + **fixed income / yield curve** (FRED + Treasury) + **FX quotes** — absent
   today; low-novelty, high-credibility. Without them it reads "retail app," not "terminal."
4. **⌘K mnemonic command palette** (DES / GP / OMON / ECO / PORT / GEO) — very low effort, demos as a
   Bloomberg replacement.
5. *(Defer)* trader messaging / IB-equivalent — highest Bloomberg moat, lowest ROI for a single-operator
   autonomous platform.

**Acquisition framing (lead the pitch with):** (1) 58-agent autonomous orchestration + kill-switch /
autonomy dial; (2) native geospatial alt-data → execution fusion (the asset a buyer cannot buy);
(3) macOS-native single-process low-cost architecture vs. Bloomberg's $24K/seat bloat.

---

## 7. Security, privacy & supply-chain (enforced)

- **Egress chokepoint in Rust** — https-only, exact-host allowlist, redirect containment, 5 MiB cap,
  per-host credential binding, secret-free error classification. The only OSINT/geo network surface.
- **Secrets** in macOS Keychain / `~/.cortex/secrets.toml` — never in repo, never in the WebView, never
  logged (log host only, never full URL/query).
- **WebView CSP split** — main window denies `unsafe-eval`; Cesium globe isolated in its own document
  (prevents the two-WebGL-context Safari crash *and* contains any renderer compromise).
- **No iCloud** — global HARD RULE #1; nothing touches `~/Library/Mobile Documents/`.
- **Download verification** (`cortex-py/cortex/validation/download_verifier.py` + preflight): checksum/
  signature every fetched dep & model; `cargo deny` + `cargo audit` + `pip-audit`/`uv` + `npm audit`
  clean; `Cargo.lock` committed; no CORS proxies; no hardcoded keys; entitlements validated.
- **Model provenance:** local models pulled only from pinned, hash-verified sources; `offline_only`
  mode hard-disables all cloud egress for privacy-locked sessions.

---

## 8. Phased roadmap (maps to task list)

| Phase | Deliverable | Task | Verify |
|---|---|---|---|
| **P1** | Rust geo-core: egress + geo + maritime + normalize, PyO3-exposed | #3 | `cargo build` + `cargo test` green |
| **P2** | Python: squadron INDIA + geo feeds + connectors (aisstream/eia/fred/treasury) on SignalBus | #4 | pytest; signals on bus; TradePipeline gating |
| **P3** | Local-LLM: provider abstraction + router + RAG (sqlite-vec) + TimesFM vol + Gemma sentiment | #6 | pytest; offline_only honored; fallback chain |
| **P4** | SwiftUI Geo-Intelligence globe (Cesium/WKWebView) + ⌘K palette + Foundation Models | #5 | `swift build`; WS round-trip; iframe isolation |
| **P5** | News institutional-grade + Rust-accelerated scanners + ECO/FI/FX | #7 | pytest; multi-source dedup; latency budget |
| **P6** | Security/privacy hardening + download verifier + preflight gate + adversarial review | #8 | gate green; adversarial workflow signs off |

**Build discipline:** every phase ends with a real verification command and an adversarial review
workflow before it is marked complete. Nothing is claimed "done" without green output.

---

## 9. New signal types & message types (contract)

- **SignalBus** (`orchestrator/signals.py`): `GEO_PHYSICAL_ALPHA = "geo.physical_alpha"`,
  `GEO_FLOATING_STORAGE = "geo.floating_storage"`, `GEO_CHOKEPOINT_CONGESTION = "geo.chokepoint_congestion"`,
  `GEO_DARK_SHIP = "geo.dark_ship"`, `GEO_VESSEL_POSITION = "geo.vessel_position"`,
  `GEO_SEISMIC_PROXIMITY = "geo.seismic_proximity"`, `EGRESS_VALIDATION_FAILED = "geo.egress_failed"`.
- **WS protocol** (`api/protocol.py` `MessageType`): `GEO_POSITION`, `GEO_SIGNAL`, `GEO_HEATMAP`,
  `LLM_PROVIDER_CHANGED`, `LLM_FALLBACK_ACTIVE`.
- **Squadron INDIA** (`squadrons/india/`): `MaritimeAnalyst` (AIS → physical-alpha), `GeoRiskMapper`
  (proximity/heatmap), `AltDataFusion` (correlate geo + news + fundamentals). All inherit `BaseAgent`,
  registered in `main.py:create_app_components()`, gated by ECHO risk + autonomy dial.

> Squadron letter **INDIA** continues the NATO phonetic series after HOTEL — geo alt-data is its own
> squadron so it routes cleanly through the existing bus without cross-squadron imports (rule #2).

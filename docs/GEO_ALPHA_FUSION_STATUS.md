# CORTEX Geo-Alpha Fusion — Build Status, Run Guide & Handoff

> Branch **`feat/geo-alpha-fusion`** (not pushed/merged). Companion to the design doc
> `docs/plans/2026-06-12-cortex-omniscient-fusion-architecture.md`. Last updated 2026-06-14.

## 1. The thesis (what makes this acquisition-worthy)
Native **geospatial alt-data → autonomous-execution fusion**: live oil-tanker / supply-flow
"physical alpha" and macro/fixed-income signals flow through the SignalBus into the 58-agent
trading loop, gated by the kill switch + autonomy dial. Bloomberg only *resells* alt-data
entitlements; it has no native geo-fusion-to-execution loop. That loop is built and adversarially
hardened here.

## 2. Verification matrix (all green)
| Layer | Command | Result |
|---|---|---|
| Rust core | `cd cortex-rs && cargo test` | **22/22** |
| Python brain | `cortex-py/.venv/bin/python -m pytest cortex-py -q` | **737/737** |
| macOS app | `cd cortex-app && swift build` | **Build complete** |
| Security gate | `bash scripts/preflight-security.sh` | **PASS** (gitleaks + cargo-deny + cargo-audit + pip-audit) |

Two adversarial-review cycles found + fixed **14 real defects** (critical Swift NaN/Inf crash,
egress port-validation gap, Hormuz chokepoint misattribution, AISStream cache freeze, ⌘K kill-switch
firing while the palette was open, geo-caution NaN safety, …). 17 commits on the branch.

## 3. What's live (and keyless-by-default)
- **Geo-intelligence (INDIA squadron):** hardened anti-SSRF Rust egress; maritime AIS (Digitraffic,
  keyless Baltic, metadata-enriched → real tanker detection — proven live 5,302 tankers); seismic
  (USGS); physical-alpha signals (floating-storage, chokepoint congestion, seismic-proximity).
- **Geo → execution fusion (ECHO):** `GeoRiskContext` tightens position sizing / flags orders on geo
  caution — **tighten-only**, never grows size, never bypasses the kill switch, NaN-safe.
- **Fixed income (JULIETT):** real daily Treasury **par-yield curve** (2s10s / 3m10s inversion) +
  avg-rate proxy fallback. Live: 2026-06-12 → 2s10s +39bp.
- **FX:** daily ECB reference rates (Frankfurter, keyless, 29 ccy) with quarterly-Treasury fallback.
- **Scanners:** real Rust composite scores from rolling price history (demo fallback < 30 bars).
- **Local-LLM:** Ollama/MLX → Claude → Gemini router with `offline_only`; tiktoken budgeting; LLM
  news sentiment (keyword fallback).
- **macOS app:** oil-tanker globe tab, ⌘⇧P command palette (Bloomberg mnemonics), live rates panel.
- **Security:** download verifier, preflight gate, `deny.toml`, pyo3 0.29 (CVEs cleared), Keychain.

## 4. Run guide
```bash
# 1) Build + install the Rust geo core into the Python env
cd ~/Desktop/cortex/cortex-rs
maturin build --release -i python3.13
uv pip install --python ../cortex-py/.venv --reinstall \
  target/wheels/cortex_scanner-0.2.0-cp313-cp313-macosx_11_0_arm64.whl

# 2) Run the backend (FastAPI :8765)
cd ~/Desktop/cortex/cortex-py && .venv/bin/python -m cortex.main

# 3) Build/run the macOS app
cd ~/Desktop/cortex/cortex-app && swift build   # full app via Xcode (CortexApp.xcodeproj)

# 4) Release gate before any ship
bash ~/Desktop/cortex/scripts/preflight-security.sh
```

## 5. Operator setup — env vars (all `CORTEX_`-prefixed; see cortex-py/cortex/config.py)
Everything above runs **keyless** today. Optional keys unlock more:
| Var | Unlocks | Cost |
|---|---|---|
| `CORTEX_AISSTREAM_API_KEY` | **Global** live tankers (worldwide, not just Baltic) | free signup |
| `CORTEX_FRED_API_KEY` | FRED econ series | free signup |
| `CORTEX_ANTHROPIC_API_KEY` | Claude strategic cycle (else local LLM only) | paid |
| `CORTEX_GEMINI_API_KEY` | Gemini fallback provider | paid/free tier |
| `CORTEX_LLM_OFFLINE_ONLY=true` | Hard-disable ALL cloud LLM egress (privacy lock) | — |

## 6. Pending — needs operator input (not built; will not be faked)
1. **AISStream key** → global tanker coverage (highest leverage; free signup).
2. **Cesium-Ion token** + bundled CesiumJS → photorealistic 3D globe (current globe is a
   self-contained offline canvas renderer).
3. **Economic calendar (ECO)** + **real-time FX bid/ask** → need a chosen data source (most are
   paid / require scraping; reference FX + par curve are already live keyless).
4. **Open a PR / merge** → the branch is review-ready; not pushed (operator's call).

## 7. Security posture (for due diligence)
Single Rust egress chokepoint: https-only, exact-host allowlist (19 hosts, each documented),
port-443-only, redirect-contained, byte-capped, per-host credential binding, secret-free errors.
Keys in Keychain / `~/.cortex/secrets.toml`, never in the repo/WebView/logs. No iCloud access.
Preflight gate blocks secrets / iCloud paths / CORS proxies and runs the full auditor suite.

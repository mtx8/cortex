# CORTEX X

AI-native trading platform by MTX Labs. A ground-up rebuild of CORTEX:
a Rust engine daemon (`cortexd`) run entirely by an AI agent mesh, and a
macOS-native SwiftUI terminal with GPU-backed charting.

```
cortex-x/
  engine/   Rust workspace — the engine (9 crates, see docs/ARCHITECTURE.md)
  app/      CortexX.app — SwiftUI terminal (macOS 14+)
  docs/     architecture, design system, runbook
```

## Quick start

```sh
# 1. Engine (paper trading on live Coinbase market data; falls back to a
#    synthetic feed automatically if the network is unavailable)
cd cortex-x/engine && cargo run --release -p cortexd

# 2. App (separate terminal)
cd cortex-x/app && swift run -c release
# or build a double-clickable bundle:
cd cortex-x/app && ./make-app.sh && open CortexX.app
```

The app connects to `ws://127.0.0.1:9601` and shows: live candles with AI
annotations, the agent thought feed, fused strategy signals, positions/orders,
account vitals, the risk HUD (kill switch, autonomy dial, caution, drawdown
clocks) and the copilot.

## Coverage

- **Crypto** — live Coinbase websocket (BTC/ETH/SOL by default), REST backfill,
  synthetic fallback when offline.
- **Stocks** — CBOE delayed quotes (SPY/AAPL/NVDA by default, keyless) with a
  year of daily + intraday history; the feed honestly advertises itself as
  delayed/degraded.
- **Options** — full chains on demand (`options` mode in the app): every
  expiry, calls/puts around the money, venue IV/greeks with Black-Scholes
  backfill computed against the live 3-month Treasury yield.

## Quant layer (`cx-ta`)

Black-Scholes (price/greeks/IV solve), Kelly sizing, EWMA vol targeting
(wired into live position sizing), Cornish-Fisher VaR + expected shortfall,
Hurst exponent, OU mean-reversion half-life, Sharpe/Sortino/drawdown/profit
factor, and deterministic Monte Carlo (GBM, risk-of-ruin). Every estimator is
validated in tests against closed-form references — the MC engine must
reproduce the Black-Scholes price to <0.5% before the suite passes.

## Local LLM (zero config)

The strategist and copilot auto-detect Ollama (`:11434`) or LM Studio
(`:1234`), pick an installed model, and reason over the full context ledger —
prices, regimes, the quant section, positions, risk posture, macro. Start a
local server at any time; the engine picks it up within a minute. Anthropic
API is the fallback when a key is configured.

## Configuration (optional)

Everything runs with zero configuration (paper account, keyless feeds).
Optional keys in `~/.cortex/secrets.toml`:

```toml
symbols = ["BTC-USD", "ETH-USD", "SOL-USD"]

[ai]
anthropic_api_key = "sk-ant-..."   # enables the LLM strategist + copilot
model = "claude-sonnet-5"
local_llm_url = "http://127.0.0.1:11434"  # optional local-first (Ollama)

[server]
port = 9601
```

Environment overrides: `ANTHROPIC_API_KEY`, `CORTEX_SYMBOLS`, `CORTEX_PORT`,
`CORTEX_FEED` (`coinbase` | `synthetic`).

## Safety model

Paper execution only in this build. Every order — human or machine — passes
one pipeline: fusion signal → autonomy dial → risk engine (kill switch,
position caps, drawdown clocks, tighten-only caution) → paper OMS. See
`docs/ARCHITECTURE.md` for the full invariant list.

(c) 2026 MTX Labs. All rights reserved.
